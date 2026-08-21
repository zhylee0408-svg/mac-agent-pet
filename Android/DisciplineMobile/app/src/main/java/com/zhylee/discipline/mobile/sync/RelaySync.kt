package com.zhylee.discipline.mobile.sync

import android.content.Context
import android.os.Build
import com.google.firebase.FirebaseApp
import com.google.firebase.installations.FirebaseInstallations
import com.google.firebase.messaging.FirebaseMessaging
import com.zhylee.discipline.mobile.DisciplineApplication
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.time.Instant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

@Serializable
private data class PushTokenUpdate(val fcmToken: String)

@Serializable
private data class RelayConfirmation(val updated: Boolean = false, val removed: Boolean = false)

@Serializable
private data class RelayErrorResponse(val error: Body) {
  @Serializable
  data class Body(val code: String, val message: String)
}

class RelayClient {
  fun claim(offer: PairingOffer, claim: PairingClaim, deviceAccessToken: String): PairingClaimed {
    val path = "v1/pairings/${claim.pairingId}/claim"
    val body = ProtocolJson.encodeToString(PairingClaim.serializer(), claim)
    val response = request(offer.relayUrl, path, "POST", deviceAccessToken, body)
    return decode(response)
  }

  fun updatePushToken(configuration: PairedConfiguration, fcmToken: String) {
    val body = ProtocolJson.encodeToString(PushTokenUpdate.serializer(), PushTokenUpdate(fcmToken))
    val response = request(
      configuration.relayUrl,
      "v1/devices/${configuration.deviceId}/push-token",
      "PUT",
      configuration.deviceAccessToken,
      body,
    )
    if (!decode<RelayConfirmation>(response).updated) throw PairingException("Push token was not updated")
  }

  fun unpair(configuration: PairedConfiguration) {
    val response = request(
      configuration.relayUrl,
      "v1/devices/${configuration.deviceId}",
      "DELETE",
      configuration.deviceAccessToken,
      null,
    )
    if (!decode<RelayConfirmation>(response).removed) throw PairingException("Phone was not unpaired")
  }

  private fun request(base: String, path: String, method: String, token: String, body: String?): String {
    val baseURI = URI(base)
    if (baseURI.scheme != "https") throw PairingException("Relay must use HTTPS")
    val connection = URL(base.trimEnd('/') + "/" + path).openConnection() as HttpURLConnection
    try {
      connection.requestMethod = method
      connection.connectTimeout = 15_000
      connection.readTimeout = 15_000
      connection.setRequestProperty("Authorization", "Bearer $token")
      connection.setRequestProperty("Accept", "application/json")
      connection.useCaches = false
      if (body != null) {
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        connection.outputStream.use { it.write(body.encodeToByteArray()) }
      }
      val status = connection.responseCode
      val stream = if (status in 200..299) connection.inputStream else connection.errorStream
      val response = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
      if (status !in 200..299) {
        val message = runCatching { ProtocolJson.decodeFromString<RelayErrorResponse>(response).error.message }
          .getOrDefault("Relay HTTP $status")
        throw PairingException(message)
      }
      return response
    } finally {
      connection.disconnect()
    }
  }

  private inline fun <reified T> decode(value: String): T = runCatching { ProtocolJson.decodeFromString<T>(value) }
    .getOrElse { throw PairingException("Relay returned an invalid response", it) }
}

class FirebaseTokenProvider(private val context: Context) {
  suspend fun token(): String {
    val app = FirebaseApp.getApps(context).firstOrNull() ?: FirebaseApp.initializeApp(context)
    if (app == null) throw PairingException("Firebase is not configured yet")
    suspendCancellableCoroutine<Unit> { continuation ->
      FirebaseMessaging.getInstance().register().addOnCompleteListener { task ->
        if (!continuation.isActive) return@addOnCompleteListener
        if (task.isSuccessful) {
          continuation.resume(Unit)
        } else {
          continuation.resumeWithException(PairingException("Could not register with FCM", task.exception))
        }
      }
    }
    return suspendCancellableCoroutine { continuation ->
      FirebaseInstallations.getInstance().id.addOnCompleteListener { task ->
        if (!continuation.isActive) return@addOnCompleteListener
        if (task.isSuccessful && !task.result.isNullOrBlank()) {
          continuation.resume(task.result)
        } else {
          continuation.resumeWithException(PairingException("Could not obtain the Firebase installation ID", task.exception))
        }
      }
    }
  }
}

class PairingManager(
  private val context: Context,
  private val pairingStore: SecurePairingStore,
  private val repository: DisciplineStateRepository,
  private val relay: RelayClient = RelayClient(),
  private val tokenProvider: FirebaseTokenProvider = FirebaseTokenProvider(context),
) {
  suspend fun connect(code: String) = withContext(Dispatchers.IO) {
    if (pairingStore.load() != null) throw PairingException("This phone is already paired")
    val offer = PairingCodeParser.parse(code)
    val identity = runCatching { ProtocolCrypto.generateDeviceIdentity() }
      .getOrElse { throw PairingException("X25519 is unavailable on this phone", it) }
    val fcmToken = tokenProvider.token()
    val deviceName = listOf(Build.MANUFACTURER, Build.MODEL)
      .filter { it.isNotBlank() }
      .joinToString(" ")
      .ifBlank { "Android phone" }
      .take(80)
    val claim = PairingClaim(
      pairingId = offer.pairingId,
      oneTimeToken = offer.oneTimeToken,
      deviceId = identity.deviceId,
      deviceName = deviceName,
      devicePublicKey = Base64URL.encode(identity.publicKeyRaw),
      fcmToken = fcmToken,
    )
    val claimed = relay.claim(offer, claim, identity.accessToken)
    if (
      claimed.version != 1 || claimed.type != "pairing_claimed" ||
      claimed.pairingId != offer.pairingId || claimed.deviceId != identity.deviceId ||
      claimed.devicePublicKey != claim.devicePublicKey || claimed.deviceName != deviceName
    ) throw PairingException("Relay pairing result did not match this phone")
    val stateKey = ProtocolCrypto.deriveStateKey(
      identity.privateKeyPkcs8,
      Base64URL.decode(offer.hostPublicKey),
      Base64URL.decode(offer.kdfSalt),
    )
    pairingStore.save(
      PairedConfiguration(
        relayUrl = offer.relayUrl,
        relaySigningPublicKey = offer.relaySigningPublicKey,
        hostId = offer.hostId,
        deviceId = identity.deviceId,
        deviceName = deviceName,
        deviceAccessToken = identity.accessToken,
        stateKey = Base64URL.encode(stateKey),
        keyId = claimed.keyId,
      ),
    )
    repository.onPaired()
    (context.applicationContext as DisciplineApplication).startStatusService()
  }

  suspend fun unpair() = withContext(Dispatchers.IO) {
    val configuration = pairingStore.load() ?: return@withContext
    relay.unpair(configuration)
    repository.onUnpaired()
    (context.applicationContext as DisciplineApplication).stopStatusService()
  }

  suspend fun updatePushToken(token: String) = withContext(Dispatchers.IO) {
    val configuration = pairingStore.load() ?: return@withContext
    relay.updatePushToken(configuration, token)
  }
}

class IncomingMessageProcessor(
  private val pairingStore: SecurePairingStore,
  private val repository: DisciplineStateRepository,
) {
  fun process(kind: String?, payload: String?): Boolean {
    if (kind == null || payload == null) return false
    val configuration = pairingStore.load() ?: return false
    return runCatching {
      when (kind) {
        "state" -> processState(payload, configuration)
        "transport" -> processTransport(payload, configuration)
        else -> false
      }
    }.getOrDefault(false)
  }

  private fun processState(payload: String, configuration: PairedConfiguration): Boolean {
    val envelope = ProtocolJson.decodeFromString<EncryptedEnvelope>(payload)
    if (envelope.sequence <= configuration.lastSequence) return false
    val message = ProtocolCrypto.decryptState(envelope, configuration)
    return repository.acceptState(ProtocolCrypto.toSnapshot(message), envelope.sequence)
  }

  private fun processTransport(payload: String, configuration: PairedConfiguration): Boolean {
    val event = ProtocolJson.decodeFromString<TransportEvent>(payload)
    if (event.sequence <= configuration.lastSequence || !ProtocolCrypto.verifyTransport(event, configuration)) return false
    runCatching { Instant.parse(event.observedAt) }.getOrElse { return false }
    return repository.acceptOffline(event)
  }
}
