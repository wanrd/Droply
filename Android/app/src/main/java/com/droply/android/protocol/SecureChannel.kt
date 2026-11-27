package com.droply.android.protocol

import java.io.IOException
import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object SecureChannel {
    private val C2S_PROOF_CONTEXT = "droply-v2-c2s-proof".toByteArray(StandardCharsets.UTF_8)
    private val S2C_PROOF_CONTEXT = "droply-v2-s2c-proof".toByteArray(StandardCharsets.UTF_8)
    private val C2S_KEY_INFO = "droply-v2-c2s".toByteArray(StandardCharsets.UTF_8)
    private val S2C_KEY_INFO = "droply-v2-s2c".toByteArray(StandardCharsets.UTF_8)
    private val secureRandom = SecureRandom()

    fun randomBytes(count: Int): ByteArray = ByteArray(count).also { secureRandom.nextBytes(it) }

    fun derivePsk(token: String): ByteArray {
        return MessageDigest.getInstance("SHA-256").digest(token.toByteArray(StandardCharsets.UTF_8))
    }

    fun generateEphemeralKeyPair(): KeyPair {
        val kpg = KeyPairGenerator.getInstance("EC")
        kpg.initialize(ECGenParameterSpec("secp256r1"), secureRandom)
        return kpg.generateKeyPair()
    }

    fun publicKeyToX963(publicKey: ECPublicKey): ByteArray {
        val out = ByteArray(65)
        out[0] = 0x04
        System.arraycopy(toUnsigned32(publicKey.w.affineX), 0, out, 1, 32)
        System.arraycopy(toUnsigned32(publicKey.w.affineY), 0, out, 33, 32)
        return out
    }

    fun x963ToPublicKey(x963: ByteArray, params: ECParameterSpec): ECPublicKey {
        if (x963.size != 65 || x963[0] != 0x04.toByte()) {
            throw IOException("Некорректный формат открытого ключа сервера")
        }
        val x = BigInteger(1, x963.copyOfRange(1, 33))
        val y = BigInteger(1, x963.copyOfRange(33, 65))
        val spec = ECPublicKeySpec(ECPoint(x, y), params)
        return KeyFactory.getInstance("EC").generatePublic(spec) as ECPublicKey
    }

    fun computeSharedSecret(privateKey: PrivateKey, peerPublicKey: ECPublicKey): ByteArray {
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(privateKey)
        ka.doPhase(peerPublicKey, true)
        val secret = ka.generateSecret()
        if (secret.size != 32) {
            throw IOException("Некорректная длина общего ключа ECDH")
        }
        return secret
    }

    fun computeClientProof(psk: ByteArray, clientPub: ByteArray, clientNonce: ByteArray): ByteArray {
        val data = ByteArray(C2S_PROOF_CONTEXT.size + clientPub.size + clientNonce.size)
        System.arraycopy(C2S_PROOF_CONTEXT, 0, data, 0, C2S_PROOF_CONTEXT.size)
        System.arraycopy(clientPub, 0, data, C2S_PROOF_CONTEXT.size, clientPub.size)
        System.arraycopy(clientNonce, 0, data, C2S_PROOF_CONTEXT.size + clientPub.size, clientNonce.size)
        return hmacSha256(psk, data)
    }

    fun computeServerProof(
        psk: ByteArray,
        clientPub: ByteArray,
        serverPub: ByteArray,
        clientNonce: ByteArray,
        serverNonce: ByteArray
    ): ByteArray {
        val data = ByteArray(
            S2C_PROOF_CONTEXT.size + clientPub.size + serverPub.size + clientNonce.size + serverNonce.size
        )
        var offset = 0
        System.arraycopy(S2C_PROOF_CONTEXT, 0, data, offset, S2C_PROOF_CONTEXT.size); offset += S2C_PROOF_CONTEXT.size
        System.arraycopy(clientPub, 0, data, offset, clientPub.size); offset += clientPub.size
        System.arraycopy(serverPub, 0, data, offset, serverPub.size); offset += serverPub.size
        System.arraycopy(clientNonce, 0, data, offset, clientNonce.size); offset += clientNonce.size
        System.arraycopy(serverNonce, 0, data, offset, serverNonce.size)
        return hmacSha256(psk, data)
    }

    fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

    fun sanitizeDisplayText(
        raw: String,
        maxLength: Int = 64,
        allowNewlines: Boolean = false
    ): String {
        val source = if (allowNewlines) {
            raw.replace("\r\n", "\n").replace('\r', '\n')
        } else {
            raw
        }
        val sb = StringBuilder()
        var i = 0
        while (i < source.length) {
            val cp = source.codePointAt(i)
            val charCount = Character.charCount(cp)
            val keepNewline = allowNewlines && cp == 0x0A
            val forbidden = !keepNewline && (
                cp < 0x20 || cp == 0x7F ||
                    cp in 0x202A..0x202E ||
                    cp in 0x2066..0x2069 ||
                    cp == 0x200E || cp == 0x200F
                )
            if (!forbidden) {
                sb.appendCodePoint(cp)
            }
            i += charCount
        }
        var clean = sb.toString().trim()
        if (allowNewlines) {
            while (clean.contains("\n\n\n")) {
                clean = clean.replace("\n\n\n", "\n\n")
            }
        }
        return if (clean.length <= maxLength) clean else clean.substring(0, maxLength)
    }

    private fun toUnsigned32(v: BigInteger): ByteArray {
        val raw = v.toByteArray()
        val out = ByteArray(32)
        if (raw.size == 32) return raw
        if (raw.size > 32) {
            System.arraycopy(raw, raw.size - 32, out, 0, 32)
        } else {
            System.arraycopy(raw, 0, out, 32 - raw.size, raw.size)
        }
        return out
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray): ByteArray {
        val prk = hmacSha256(salt, ikm)
        val input = ByteArray(info.size + 1)
        System.arraycopy(info, 0, input, 0, info.size)
        input[info.size] = 0x01
        return hmacSha256(prk, input)
    }

    class SessionCipher(
        sharedSecret: ByteArray,
        psk: ByteArray,
        clientNonce: ByteArray,
        serverNonce: ByteArray,
        isClient: Boolean = true
    ) {
        private val txLock = Any()
        private val rxLock = Any()

        private val txKeySpec: SecretKeySpec
        private val rxKeySpec: SecretKeySpec
        private val txDirection: Byte
        private val rxDirection: Byte
        private var txSequence: Long = 0L
        private var rxSequence: Long = 0L

        init {
            val ikm = ByteArray(sharedSecret.size + psk.size)
            System.arraycopy(sharedSecret, 0, ikm, 0, sharedSecret.size)
            System.arraycopy(psk, 0, ikm, sharedSecret.size, psk.size)

            val salt = ByteArray(clientNonce.size + serverNonce.size)
            System.arraycopy(clientNonce, 0, salt, 0, clientNonce.size)
            System.arraycopy(serverNonce, 0, salt, clientNonce.size, serverNonce.size)

            val c2s = hkdfSha256(ikm, salt, C2S_KEY_INFO)
            val s2c = hkdfSha256(ikm, salt, S2C_KEY_INFO)

            if (isClient) {
                txKeySpec = SecretKeySpec(c2s, "AES")
                rxKeySpec = SecretKeySpec(s2c, "AES")
                txDirection = 0x01
                rxDirection = 0x02
            } else {
                txKeySpec = SecretKeySpec(s2c, "AES")
                rxKeySpec = SecretKeySpec(c2s, "AES")
                txDirection = 0x02
                rxDirection = 0x01
            }
        }

        fun sealFrame(type: FrameType, plaintext: ByteArray, length: Int = plaintext.size): ByteArray {
            if (length < 0 || length + 16 > DroplyProtocol.MAX_WIRE_FRAME_PAYLOAD_BYTES) {
                throw IllegalArgumentException("Недопустимый размер пакета: $length")
            }
            val seq: Long
            synchronized(txLock) {
                if (txSequence == Long.MAX_VALUE) {
                    throw IOException("Исчерпан счётчик шифрования сессии")
                }
                txSequence += 1L
                seq = txSequence
            }

            val nonce = makeNonce(txDirection, seq)
            val header = makeHeader(type, length + 16)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, txKeySpec, GCMParameterSpec(128, nonce))
            cipher.updateAAD(header)
            val sealed = cipher.doFinal(plaintext, 0, length)
            if (sealed.size != length + 16) {
                throw IOException("Ошибка шифрования пакета")
            }
            val packet = ByteArray(5 + sealed.size)
            System.arraycopy(header, 0, packet, 0, 5)
            System.arraycopy(sealed, 0, packet, 5, sealed.size)
            return packet
        }

        fun openPayload(type: FrameType, sealedPayload: ByteArray): ByteArray {
            if (sealedPayload.size < 16) {
                throw IOException("Повреждённый зашифрованный пакет")
            }
            val seq: Long
            synchronized(rxLock) {
                if (rxSequence == Long.MAX_VALUE) {
                    throw IOException("Исчерпан счётчик расшифровки сессии")
                }
                rxSequence += 1L
                seq = rxSequence
            }

            val nonce = makeNonce(rxDirection, seq)
            val header = makeHeader(type, sealedPayload.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, rxKeySpec, GCMParameterSpec(128, nonce))
            cipher.updateAAD(header)
            return try {
                cipher.doFinal(sealedPayload)
            } catch (e: Exception) {
                throw IOException("Нарушена целостность или подлинность пакета", e)
            }
        }

        private fun makeNonce(direction: Byte, sequence: Long): ByteArray {
            val nonce = ByteArray(12)
            nonce[0] = direction
            ByteBuffer.wrap(nonce, 4, 8).order(ByteOrder.BIG_ENDIAN).putLong(sequence)
            return nonce
        }

        private fun makeHeader(type: FrameType, payloadLength: Int): ByteArray {
            val header = ByteArray(5)
            header[0] = type.code
            ByteBuffer.wrap(header, 1, 4).order(ByteOrder.BIG_ENDIAN).putInt(payloadLength)
            return header
        }
    }
}
