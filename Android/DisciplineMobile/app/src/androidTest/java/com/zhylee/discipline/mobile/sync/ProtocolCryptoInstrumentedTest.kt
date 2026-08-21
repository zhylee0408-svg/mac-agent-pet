package com.zhylee.discipline.mobile.sync

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.security.SecureRandom
import org.junit.Assert.assertArrayEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProtocolCryptoInstrumentedTest {
  @Test
  fun deviceX25519GenerationAndAgreementRoundTrip() {
    val first = ProtocolCrypto.generateDeviceIdentity()
    val second = ProtocolCrypto.generateDeviceIdentity()
    val salt = ByteArray(32).also(SecureRandom()::nextBytes)

    val firstKey = ProtocolCrypto.deriveStateKey(first.privateKeyPkcs8, second.publicKeyRaw, salt)
    val secondKey = ProtocolCrypto.deriveStateKey(second.privateKeyPkcs8, first.publicKeyRaw, salt)

    assertArrayEquals(firstKey, secondKey)
  }
}
