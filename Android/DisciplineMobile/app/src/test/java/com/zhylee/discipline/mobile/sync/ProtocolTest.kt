package com.zhylee.discipline.mobile.sync

import com.zhylee.discipline.mobile.model.TaskState
import java.time.Instant
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {
  private val derivedKey = "Q8UN-Y0Mk4y3dA44I8MLOoRNK0h36ZwfYMkrYsEph8c"
  private val ciphertext = "2wqVezWYBuX4MU1yQ8RTAmoWSDCVBxn48oLsfFnibgUBjSB_V6gMiGy3nML68TG367cxx5MHC42oxZTES-Cxms55OwDn8aoWD-8VP77zHMLvx-z-DbB6FD141SihuuZRhsybXiU10lc8hLnWRMluvr7RjgDhyTkdpEDzJ8pD62dU0a1vmd8gvh03KM527c5tNPrMiswQpYeT2y8pDvFQnjhh-ROayJvcrBqmK91nLbzfM12oC58PnLonvi4aiXfxP4WrWIQ-fKp2PPm0MOb28IUBUlRm4TDeBbO7rZ9vn92RtDPhG__fEE1pxn4NxcpeeWKlB0ZaPlSpIe2uaLrbX2LRFdgdYyUPOtqa"

  @Test
  fun macPairingCodeRoundTripsIntoStrictOffer() {
    val code = "discipline://pair?v=1" +
      "&relay=https%3A%2F%2Frelay.discipline.example" +
      "&pairing=pairing_demo" +
      "&token=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8" +
      "&host=host_demo" +
      "&name=Zhy%27s%20MacBook%20Pro" +
      "&host_key=B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw" +
      "&salt=YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1-f4A" +
      "&relay_key=rcFAEfgtHFbZVqpPnXPYhYNhpgYEhSXg0Ixjjcdd2Mc" +
      "&expires=2099-08-20T14%3A37%3A18%2B08%3A00"
    val offer = PairingCodeParser.parse(code, Instant.parse("2099-08-20T06:32:18Z"))
    assertEquals("https://relay.discipline.example", offer.relayUrl)
    assertEquals("pairing_demo", offer.pairingId)
    assertEquals("Zhy's MacBook Pro", offer.hostName)
  }

  @Test
  fun x25519HkdfMatchesSharedProtocolVector() {
    val privateSeed = Base64URL.decode("ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0-P0A")
    val pkcs8Prefix = hex("302e020100300506032b656e04220420")
    val actual = ProtocolCrypto.deriveStateKey(
      pkcs8Prefix + privateSeed,
      Base64URL.decode("B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw"),
      Base64URL.decode("YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1-f4A"),
    )
    assertArrayEquals(Base64URL.decode(derivedKey), actual)
  }

  @Test
  fun encryptedStateAuthenticatesAndMapsToVisibleSnapshot() {
    val configuration = configuration()
    val envelope = EncryptedEnvelope(
      version = 1,
      algorithm = "X25519-HKDF-SHA256-A256GCM",
      hostId = "host_demo",
      deviceId = "device_demo",
      keyId = "key_demo",
      sequence = 42,
      sentAt = "2026-08-20T14:32:18+08:00",
      nonce = "oKGio6Slpqeoqaqr",
      ciphertext = ciphertext,
    )
    val message = ProtocolCrypto.decryptState(envelope, configuration)
    val snapshot = ProtocolCrypto.toSnapshot(message)
    assertEquals(42, message.sequence)
    assertEquals("codex", snapshot.sourceId)
    assertEquals(TaskState.RUNNING, snapshot.state)
    assertEquals(listOf("Codex", "DSH"), snapshot.sources.map { it.label })

    val tampered = envelope.copy(ciphertext = ciphertext.dropLast(1) + "A")
    assertThrows(PairingException::class.java) { ProtocolCrypto.decryptState(tampered, configuration) }
  }

  @Test
  fun signedOfflineEventMatchesSharedProtocolVector() {
    val event = TransportEvent(
      version = 1,
      type = "transport",
      event = "offline",
      hostId = "host_demo",
      deviceId = "device_demo",
      sequence = 43,
      observedAt = "2026-08-20T14:42:18+08:00",
      timeoutSeconds = 600,
      reason = "heartbeat_timeout",
      signature = "q3NeBlLO3op_NFvvdFnhqZh3hXtlgxg0TG75x5s7JoJEohvmPiO4mCvWyblrL4EHNV4TeOvcbuE-tm-qrSbKDw",
    )
    assertTrue(ProtocolCrypto.verifyTransport(event, configuration()))
    assertFalse(ProtocolCrypto.verifyTransport(event.copy(sequence = 44), configuration()))
  }

  private fun configuration() = PairedConfiguration(
    relayUrl = "https://relay.discipline.example",
    relaySigningPublicKey = "rcFAEfgtHFbZVqpPnXPYhYNhpgYEhSXg0Ixjjcdd2Mc",
    hostId = "host_demo",
    deviceId = "device_demo",
    deviceName = "OnePlus 13T",
    deviceAccessToken = "ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0-P0A",
    stateKey = derivedKey,
    keyId = "key_demo",
  )

  private fun hex(value: String): ByteArray = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
