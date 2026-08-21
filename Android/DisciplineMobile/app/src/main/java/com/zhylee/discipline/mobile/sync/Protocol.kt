package com.zhylee.discipline.mobile.sync

import android.os.Build
import androidx.annotation.RequiresApi
import com.zhylee.discipline.mobile.model.DisciplineSnapshot
import com.zhylee.discipline.mobile.model.SourceSnapshot
import com.zhylee.discipline.mobile.model.TaskState
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.Provider
import java.security.SecureRandom
import java.security.Security
import java.security.Signature
import java.security.spec.NamedParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.time.Instant
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

internal val ProtocolJson = Json {
  ignoreUnknownKeys = false
  explicitNulls = true
  encodeDefaults = true
}

@Serializable
data class PairingOffer(
  val version: Int,
  val type: String,
  val relayUrl: String,
  val pairingId: String,
  val oneTimeToken: String,
  val hostId: String,
  val hostName: String,
  val hostPublicKey: String,
  val kdfSalt: String,
  val relaySigningPublicKey: String,
  val expiresAt: String,
)

@Serializable
data class PairingClaim(
  val version: Int = 1,
  val type: String = "pairing_claim",
  val pairingId: String,
  val oneTimeToken: String,
  val deviceId: String,
  val deviceName: String,
  val devicePublicKey: String,
  val fcmToken: String,
)

@Serializable
data class PairingClaimed(
  val version: Int,
  val type: String,
  val pairingId: String,
  val deviceId: String,
  val deviceName: String,
  val devicePublicKey: String,
  val keyId: String,
  val claimedAt: String,
)

@Serializable
data class WireSourceSnapshot(
  val id: String,
  val label: String,
  val online: Boolean,
  val status: String?,
)

@Serializable
data class StateMessage(
  val version: Int,
  val type: String,
  val sequence: Long,
  val source: String,
  val status: String,
  val sources: List<WireSourceSnapshot>,
  val updatedAt: String,
)

@Serializable
data class EncryptedEnvelope(
  val version: Int,
  val algorithm: String,
  val hostId: String,
  val deviceId: String,
  val keyId: String,
  val sequence: Long,
  val sentAt: String,
  val nonce: String,
  val ciphertext: String,
)

@Serializable
data class TransportEvent(
  val version: Int,
  val type: String,
  val event: String,
  val hostId: String,
  val deviceId: String,
  val sequence: Long,
  val observedAt: String,
  val timeoutSeconds: Int,
  val reason: String,
  val signature: String,
)

@Serializable
data class PairedConfiguration(
  val relayUrl: String,
  val relaySigningPublicKey: String,
  val hostId: String,
  val deviceId: String,
  val deviceName: String,
  val deviceAccessToken: String,
  val stateKey: String,
  val keyId: String,
  val lastSequence: Long = -1,
)

data class DeviceIdentity(
  val deviceId: String,
  val accessToken: String,
  val privateKeyPkcs8: ByteArray,
  val publicKeyRaw: ByteArray,
)

object Base64URL {
  fun encode(value: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(value)
  fun decode(value: String): ByteArray = Base64.getUrlDecoder().decode(value)
}

object PairingCodeParser {
  private val identifier = Regex("^[A-Za-z0-9_-]{1,80}$")
  private val expectedKeys = setOf(
    "v", "relay", "pairing", "token", "host", "name", "host_key", "salt", "relay_key", "expires",
  )

  fun parse(value: String, now: Instant = Instant.now()): PairingOffer {
    val uri = runCatching { URI(value.trim()) }.getOrElse { throw PairingException("Invalid pairing code") }
    if (uri.scheme != "discipline" || uri.host != "pair") throw PairingException("Invalid pairing code")
    val pairs = uri.rawQuery.orEmpty().split('&').filter { it.isNotBlank() }.map { item ->
      val divider = item.indexOf('=')
      if (divider <= 0) throw PairingException("Invalid pairing code")
      URLDecoder.decode(item.substring(0, divider), "UTF-8") to
        URLDecoder.decode(item.substring(divider + 1), "UTF-8")
    }
    if (pairs.map { it.first }.toSet().size != pairs.size) throw PairingException("Duplicate pairing fields")
    val fields = pairs.toMap()
    if (fields.keys != expectedKeys || fields["v"] != "1") throw PairingException("Unsupported pairing code")

    val relay = fields.getValue("relay")
    val relayURI = runCatching { URI(relay) }.getOrNull()
    if (relayURI?.scheme != "https" || relayURI.host.isNullOrBlank()) throw PairingException("Relay must use HTTPS")
    val pairingId = fields.getValue("pairing")
    val hostId = fields.getValue("host")
    if (!identifier.matches(pairingId) || !identifier.matches(hostId)) throw PairingException("Invalid pairing identity")
    val token = fields.getValue("token")
    val hostKey = fields.getValue("host_key")
    val salt = fields.getValue("salt")
    val relayKey = fields.getValue("relay_key")
    if (decodedSize(token) < 32 || decodedSize(hostKey) != 32 || decodedSize(salt) != 32 || decodedSize(relayKey) != 32) {
      throw PairingException("Invalid pairing key material")
    }
    val expiry = runCatching { Instant.parse(fields.getValue("expires")) }.getOrNull()
      ?: throw PairingException("Invalid pairing expiry")
    if (!expiry.isAfter(now)) throw PairingException("Pairing code has expired")

    return PairingOffer(
      version = 1,
      type = "pairing_offer",
      relayUrl = relay,
      pairingId = pairingId,
      oneTimeToken = token,
      hostId = hostId,
      hostName = fields.getValue("name").take(80),
      hostPublicKey = hostKey,
      kdfSalt = salt,
      relaySigningPublicKey = relayKey,
      expiresAt = fields.getValue("expires"),
    )
  }

  private fun decodedSize(value: String): Int = runCatching { Base64URL.decode(value).size }.getOrDefault(-1)
}

class PairingException(message: String, cause: Throwable? = null) : Exception(message, cause)

object ProtocolCrypto {
  private val random = SecureRandom()
  private val x25519X509Prefix = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00)
  private val ed25519X509Prefix = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00)

  fun generateDeviceIdentity(): DeviceIdentity {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
      throw PairingException("Discipline encrypted pairing requires Android 13 or newer")
    }
    return generateDeviceIdentityApi33()
  }

  @RequiresApi(Build.VERSION_CODES.TIRAMISU)
  private fun generateDeviceIdentityApi33(): DeviceIdentity {
    val pair = generateX25519KeyPair()
    val encodedPublic = pair.public.encoded
    if (encodedPublic.size < 32) throw PairingException("X25519 public key is unavailable")
    return DeviceIdentity(
      deviceId = "android_" + UUID.randomUUID().toString().lowercase().replace("-", ""),
      accessToken = Base64URL.encode(ByteArray(32).also(random::nextBytes)),
      privateKeyPkcs8 = pair.private.encoded,
      publicKeyRaw = encodedPublic.takeLast(32).toByteArray(),
    )
  }

  fun deriveStateKey(privateKeyPkcs8: ByteArray, hostPublicKeyRaw: ByteArray, salt: ByteArray): ByteArray {
    if (hostPublicKeyRaw.size != 32 || salt.size != 32) throw PairingException("Invalid key agreement material")
    var failure: Throwable? = null
    for (route in x25519Routes()) {
      try {
        val factory = route.keyFactory()
        val privateKey = factory.generatePrivate(PKCS8EncodedKeySpec(privateKeyPkcs8))
        val publicKey = factory.generatePublic(X509EncodedKeySpec(x25519X509Prefix + hostPublicKeyRaw))
        val agreement = route.keyAgreement()
        agreement.init(privateKey)
        agreement.doPhase(publicKey, true)
        return hkdfSha256(agreement.generateSecret(), salt, "discipline-mobile-state-v1".toByteArray(), 32)
      } catch (error: Throwable) {
        failure = error
      }
    }
    throw PairingException("Required X25519 key agreement is unavailable", failure)
  }

  fun decryptState(envelope: EncryptedEnvelope, configuration: PairedConfiguration): StateMessage {
    validateEnvelopeIdentity(envelope, configuration)
    if (envelope.algorithm != "X25519-HKDF-SHA256-A256GCM") throw PairingException("Unsupported envelope algorithm")
    val nonce = runCatching { Base64URL.decode(envelope.nonce) }.getOrElse { throw PairingException("Invalid envelope nonce") }
    val encrypted = runCatching { Base64URL.decode(envelope.ciphertext) }.getOrElse { throw PairingException("Invalid envelope ciphertext") }
    if (nonce.size != 12 || encrypted.size <= 16) throw PairingException("Invalid encrypted envelope")
    val aad = "discipline:v1:${envelope.hostId}:${envelope.deviceId}:${envelope.sequence}:${envelope.keyId}"
      .toByteArray(StandardCharsets.UTF_8)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(
      Cipher.DECRYPT_MODE,
      SecretKeySpec(Base64URL.decode(configuration.stateKey), "AES"),
      GCMParameterSpec(128, nonce),
    )
    cipher.updateAAD(aad)
    val plaintext = runCatching { cipher.doFinal(encrypted) }.getOrElse { throw PairingException("State authentication failed") }
    val message = runCatching { ProtocolJson.decodeFromString<StateMessage>(plaintext.decodeToString()) }
      .getOrElse { throw PairingException("Invalid state payload") }
    validateState(message, envelope.sequence)
    return message
  }

  fun verifyTransport(event: TransportEvent, configuration: PairedConfiguration): Boolean {
    if (
      event.version != 1 || event.type != "transport" || event.event != "offline" ||
      event.hostId != configuration.hostId || event.deviceId != configuration.deviceId ||
      event.timeoutSeconds != 600 || event.reason != "heartbeat_timeout"
    ) return false
    val rawKey = runCatching { Base64URL.decode(configuration.relaySigningPublicKey) }.getOrNull() ?: return false
    if (rawKey.size != 32) return false
    val signatureBytes = runCatching { Base64URL.decode(event.signature) }.getOrNull() ?: return false
    val input = "discipline:v1:transport:${event.hostId}:${event.deviceId}:${event.sequence}:offline:${event.observedAt}:600"
    return runCatching {
      val publicKey = keyFactory("Ed25519").generatePublic(X509EncodedKeySpec(ed25519X509Prefix + rawKey))
      Signature.getInstance("Ed25519").run {
        initVerify(publicKey)
        update(input.toByteArray(StandardCharsets.UTF_8))
        verify(signatureBytes)
      }
    }.getOrDefault(false)
  }

  fun toSnapshot(message: StateMessage): DisciplineSnapshot {
    val sources = message.sources.map { source ->
      val status = source.status?.let(::taskState)
      if (source.online != (status != null)) throw PairingException("Invalid source availability")
      SourceSnapshot(source.id, source.label, source.online, status)
    }
    val effective = taskState(message.status)
    if (message.source == "none") {
      if (effective != TaskState.IDLE) throw PairingException("Neutral source must be idle")
    } else {
      val selected = sources.firstOrNull { it.id == message.source }
        ?: throw PairingException("Selected source is missing")
      if (!selected.online || selected.status != effective) throw PairingException("Selected source does not match status")
    }
    return DisciplineSnapshot(
      transportOnline = true,
      sourceId = message.source.takeUnless { it == "none" },
      state = effective,
      sources = sources,
      updatedAt = runCatching { Instant.parse(message.updatedAt) }.getOrElse { throw PairingException("Invalid update time") },
    )
  }

  private fun validateEnvelopeIdentity(envelope: EncryptedEnvelope, configuration: PairedConfiguration) {
    if (
      envelope.version != 1 || envelope.hostId != configuration.hostId ||
      envelope.deviceId != configuration.deviceId || envelope.keyId != configuration.keyId
    ) throw PairingException("Envelope route does not match this phone")
  }

  private fun validateState(message: StateMessage, envelopeSequence: Long) {
    if (message.version != 1 || message.type != "state" || message.sequence != envelopeSequence) {
      throw PairingException("State sequence mismatch")
    }
    if (message.sources.isEmpty() || message.sources.map { it.id }.toSet().size != message.sources.size) {
      throw PairingException("Invalid source list")
    }
    taskState(message.status)
  }

  private fun taskState(value: String): TaskState = TaskState.entries.firstOrNull { it.wireValue == value }
    ?: throw PairingException("Unknown task state")

  private fun hkdfSha256(secret: ByteArray, salt: ByteArray, info: ByteArray, outputLength: Int): ByteArray {
    val hmac = Mac.getInstance("HmacSHA256")
    hmac.init(SecretKeySpec(salt, "HmacSHA256"))
    val pseudoRandomKey = hmac.doFinal(secret)
    var previous = ByteArray(0)
    val output = ArrayList<Byte>(outputLength)
    var counter = 1
    while (output.size < outputLength) {
      hmac.init(SecretKeySpec(pseudoRandomKey, "HmacSHA256"))
      hmac.update(previous)
      hmac.update(info)
      hmac.update(counter.toByte())
      previous = hmac.doFinal()
      previous.forEach { if (output.size < outputLength) output += it }
      counter += 1
    }
    return output.toByteArray()
  }

  @RequiresApi(Build.VERSION_CODES.TIRAMISU)
  private fun generateX25519KeyPair(): KeyPair {
    var failure: Throwable? = null
    for (route in x25519Routes()) {
      try {
        val generator = route.keyPairGenerator()
        if (route.algorithm == "XDH") {
          generator.initialize(NamedParameterSpec("X25519"), random)
        }
        return generator.generateKeyPair()
      } catch (error: Throwable) {
        failure = error
      }
    }
    throw PairingException("Required X25519 key generation is unavailable", failure)
  }

  private fun x25519Routes(): List<X25519Route> {
    val androidOpenSsl = Security.getProvider("AndroidOpenSSL")
    return buildList {
      if (androidOpenSsl != null) {
        add(X25519Route("X25519", androidOpenSsl))
        add(X25519Route("XDH", androidOpenSsl))
      }
      add(X25519Route("X25519", null))
      add(X25519Route("XDH", null))
    }
  }

  private data class X25519Route(val algorithm: String, val provider: Provider?) {
    fun keyPairGenerator(): KeyPairGenerator = provider?.let {
      KeyPairGenerator.getInstance(algorithm, it)
    } ?: KeyPairGenerator.getInstance(algorithm)

    fun keyFactory(): KeyFactory = provider?.let {
      KeyFactory.getInstance(algorithm, it)
    } ?: KeyFactory.getInstance(algorithm)

    fun keyAgreement(): KeyAgreement = provider?.let {
      KeyAgreement.getInstance(algorithm, it)
    } ?: KeyAgreement.getInstance(algorithm)
  }

  private fun keyFactory(vararg algorithms: String): KeyFactory {
    algorithms.forEach { algorithm -> runCatching { return KeyFactory.getInstance(algorithm) } }
    throw PairingException("Required cryptography is unavailable")
  }
}
