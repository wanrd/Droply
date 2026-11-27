package com.droply.android

import com.droply.android.protocol.FrameCodec
import com.droply.android.protocol.FrameType
import com.droply.android.protocol.SecureChannel
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.security.interfaces.ECPublicKey

class SecureChannelTest {

    @Test
    fun ecdhAndSessionCipherRoundtripAndTamperProtection() {
        val clientKp = SecureChannel.generateEphemeralKeyPair()
        val serverKp = SecureChannel.generateEphemeralKeyPair()
        val clientPub = SecureChannel.publicKeyToX963(clientKp.public as ECPublicKey)
        val serverPub = SecureChannel.publicKeyToX963(serverKp.public as ECPublicKey)
        assertEquals(65, clientPub.size)
        assertEquals(65, serverPub.size)

        val psk = SecureChannel.derivePsk("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        val cNonce = SecureChannel.randomBytes(32)
        val sNonce = SecureChannel.randomBytes(32)

        val clientProof = SecureChannel.computeClientProof(psk, clientPub, cNonce)
        assertTrue(SecureChannel.constantTimeEquals(clientProof, SecureChannel.computeClientProof(psk, clientPub, cNonce)))
        assertFalse(SecureChannel.constantTimeEquals(clientProof, SecureChannel.computeClientProof(SecureChannel.derivePsk("wrong"), clientPub, cNonce)))

        val serverProof = SecureChannel.computeServerProof(psk, clientPub, serverPub, cNonce, sNonce)
        assertTrue(SecureChannel.constantTimeEquals(serverProof, SecureChannel.computeServerProof(psk, clientPub, serverPub, cNonce, sNonce)))

        val params = (clientKp.public as ECPublicKey).params
        val clientSecret = SecureChannel.computeSharedSecret(clientKp.private, SecureChannel.x963ToPublicKey(serverPub, params))
        val serverSecret = SecureChannel.computeSharedSecret(serverKp.private, SecureChannel.x963ToPublicKey(clientPub, params))
        assertArrayEquals(clientSecret, serverSecret)

        val clientCipher = SecureChannel.SessionCipher(clientSecret, psk, cNonce, sNonce, isClient = true)
        val serverCipher = SecureChannel.SessionCipher(serverSecret, psk, cNonce, sNonce, isClient = false)

        val wire = ByteArrayOutputStream()
        val secretMsg = "Top secret payload".toByteArray(Charsets.UTF_8)
        FrameCodec.writeEncryptedFrame(wire, clientCipher, FrameType.FILE_CHUNK, secretMsg)
        val packet = wire.toByteArray()

        // Valid decryption on peer
        val decrypted = FrameCodec.readDecryptedFrame(ByteArrayInputStream(packet), serverCipher)
        assertEquals(FrameType.FILE_CHUNK, decrypted.type)
        assertArrayEquals(secretMsg, decrypted.payload)

        // Replay of the exact same encrypted packet must fail because rxSequence advances monotonically
        assertThrows(IOException::class.java) {
            FrameCodec.readDecryptedFrame(ByteArrayInputStream(packet), serverCipher)
        }

        // 1-bit tamper in ciphertext/tag must fail authentication on a synchronized cipher pair
        val clientCipher2 = SecureChannel.SessionCipher(clientSecret, psk, cNonce, sNonce, isClient = true)
        val serverCipher2 = SecureChannel.SessionCipher(serverSecret, psk, cNonce, sNonce, isClient = false)
        val freshWire = ByteArrayOutputStream()
        FrameCodec.writeEncryptedFrame(freshWire, clientCipher2, FrameType.PING, ByteArray(0))
        val tampered = freshWire.toByteArray()
        tampered[tampered.lastIndex] = (tampered[tampered.lastIndex].toInt() xor 0x01).toByte()
        assertThrows(IOException::class.java) {
            FrameCodec.readDecryptedFrame(ByteArrayInputStream(tampered), serverCipher2)
        }
    }

    @Test
    fun sanitizeDisplayTextStripsControlAndBidiChars() {
        val raw = "Phone\u202E\u200F\n\t\u0007 Name"
        assertEquals("Phone Name", SecureChannel.sanitizeDisplayText(raw))
        assertEquals("abc", SecureChannel.sanitizeDisplayText("abcdef", maxLength = 3))
    }
}
