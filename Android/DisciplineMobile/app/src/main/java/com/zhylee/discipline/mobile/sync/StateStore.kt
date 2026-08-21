package com.zhylee.discipline.mobile.sync

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.core.content.edit
import com.zhylee.discipline.mobile.model.DisciplineSnapshot
import com.zhylee.discipline.mobile.model.NotificationPolicy
import com.zhylee.discipline.mobile.model.PreviewScenario
import com.zhylee.discipline.mobile.model.SourceSnapshot
import com.zhylee.discipline.mobile.model.TaskState
import com.zhylee.discipline.mobile.notification.StatusNotificationManager
import java.security.KeyStore
import java.time.Instant
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable

class SecurePairingStore(context: Context) {
  private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

  @Synchronized
  fun load(): PairedConfiguration? {
    val blob = preferences.getString(CONFIGURATION, null) ?: return null
    return runCatching {
      val bytes = Base64URL.decode(blob)
      require(bytes.size > 12 + 16)
      val cipher = Cipher.getInstance("AES/GCM/NoPadding")
      cipher.init(Cipher.DECRYPT_MODE, encryptionKey(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
      ProtocolJson.decodeFromString<PairedConfiguration>(cipher.doFinal(bytes.copyOfRange(12, bytes.size)).decodeToString())
    }.getOrNull()
  }

  @Synchronized
  fun save(configuration: PairedConfiguration) {
    val plaintext = ProtocolJson.encodeToString(PairedConfiguration.serializer(), configuration).encodeToByteArray()
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, encryptionKey())
    val encrypted = cipher.doFinal(plaintext)
    preferences.edit(commit = true) {
      putString(CONFIGURATION, Base64URL.encode(cipher.iv + encrypted))
    }
  }

  @Synchronized
  fun clear() {
    preferences.edit(commit = true) { remove(CONFIGURATION) }
  }

  private fun encryptionKey(): SecretKey {
    val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
    return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
      init(
        KeyGenParameterSpec.Builder(
          KEY_ALIAS,
          KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
          .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
          .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
          .setKeySize(256)
          .setRandomizedEncryptionRequired(true)
          .setUserAuthenticationRequired(false)
          .build(),
      )
      generateKey()
    }
  }

  companion object {
    private const val PREFERENCES = "discipline_secure_pairing_v1"
    private const val CONFIGURATION = "configuration"
    private const val KEY_ALIAS = "discipline_pairing_storage_v1"
  }
}

@Serializable
private data class StoredSnapshot(
  val transportOnline: Boolean,
  val sourceId: String?,
  val state: String?,
  val sources: List<WireSourceSnapshot>,
  val updatedAt: String,
) {
  fun snapshot(): DisciplineSnapshot = DisciplineSnapshot(
    transportOnline = transportOnline,
    sourceId = sourceId,
    state = state?.let(::taskState),
    sources = sources.map { SourceSnapshot(it.id, it.label, it.online, it.status?.let(::taskState)) },
    updatedAt = Instant.parse(updatedAt),
  )

  companion object {
    fun from(snapshot: DisciplineSnapshot) = StoredSnapshot(
      transportOnline = snapshot.transportOnline,
      sourceId = snapshot.sourceId,
      state = snapshot.state?.wireValue,
      sources = snapshot.sources.map {
        WireSourceSnapshot(it.id, it.label, it.online, it.status?.wireValue)
      },
      updatedAt = snapshot.updatedAt.toString(),
    )

    private fun taskState(value: String): TaskState = TaskState.entries.first { it.wireValue == value }
  }
}

class DisciplineStateRepository(
  context: Context,
  private val pairingStore: SecurePairingStore,
  private val notifications: StatusNotificationManager,
) {
  private val preferences = context.getSharedPreferences("discipline_visible_state_v1", Context.MODE_PRIVATE)
  private val initialSnapshot = loadSnapshot() ?: offlineSnapshot(Instant.now())
  private val mutableSnapshot = MutableStateFlow(initialSnapshot)
  private val mutablePaired = MutableStateFlow(pairingStore.load() != null)

  val snapshot: StateFlow<DisciplineSnapshot> = mutableSnapshot.asStateFlow()
  val paired: StateFlow<Boolean> = mutablePaired.asStateFlow()

  init {
    // An in-place upgrade from the local preview can leave its last notification
    // visible. Until a real pairing exists, no remote state is authoritative.
    if (!mutablePaired.value) notifications.cancel()
  }

  @Synchronized
  fun acceptState(snapshot: DisciplineSnapshot, sequence: Long): Boolean {
    val configuration = pairingStore.load() ?: return false
    if (sequence <= configuration.lastSequence) return false
    pairingStore.save(configuration.copy(lastSequence = sequence))
    publish(snapshot, persist = true)
    return true
  }

  @Synchronized
  fun acceptOffline(event: TransportEvent): Boolean {
    val configuration = pairingStore.load() ?: return false
    if (event.sequence <= configuration.lastSequence) return false
    pairingStore.save(configuration.copy(lastSequence = event.sequence))
    val current = mutableSnapshot.value
    val offline = DisciplineSnapshot(
      transportOnline = false,
      sourceId = null,
      state = null,
      sources = current.sources.map { it.copy(online = false, status = null) },
      updatedAt = Instant.parse(event.observedAt),
    )
    publish(offline, persist = true)
    return true
  }

  fun onPaired() {
    mutablePaired.value = true
    publish(offlineSnapshot(Instant.now()), persist = true)
  }

  fun onUnpaired() {
    pairingStore.clear()
    mutablePaired.value = false
    preferences.edit { remove(SNAPSHOT) }
    mutableSnapshot.value = offlineSnapshot(Instant.now())
    notifications.cancel()
  }

  fun preview(scenario: PreviewScenario) {
    publish(scenario.snapshot(Instant.now()), persist = false)
  }

  fun refreshNotification() {
    if (mutablePaired.value) notifications.show(mutableSnapshot.value, playSound = false)
  }

  private fun publish(snapshot: DisciplineSnapshot, persist: Boolean) {
    val previous = mutableSnapshot.value
    mutableSnapshot.value = snapshot
    if (persist) {
      val value = ProtocolJson.encodeToString(StoredSnapshot.serializer(), StoredSnapshot.from(snapshot))
      preferences.edit { putString(SNAPSHOT, value) }
    }
    notifications.show(snapshot, NotificationPolicy.shouldPlaySound(previous, snapshot))
  }

  private fun loadSnapshot(): DisciplineSnapshot? = preferences.getString(SNAPSHOT, null)?.let { value ->
    runCatching { ProtocolJson.decodeFromString<StoredSnapshot>(value).snapshot() }.getOrNull()
  }

  companion object {
    private const val SNAPSHOT = "snapshot"

    fun offlineSnapshot(now: Instant) = DisciplineSnapshot(
      transportOnline = false,
      sourceId = null,
      state = null,
      sources = listOf(
        SourceSnapshot("codex", "Codex", false, null),
        SourceSnapshot("dsh", "DSH", false, null),
      ),
      updatedAt = now,
    )
  }
}
