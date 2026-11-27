package com.droply.android.protocol

import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

object DroplyProtocol {
    const val VERSION = 1
    const val DEFAULT_PORT = 45820
    const val CHUNK_SIZE = 256 * 1024 // 256 KB streaming buffer
    const val MAX_FRAME_PAYLOAD_BYTES = 16 * 1024 * 1024 // 16 MB plaintext
    const val MAX_WIRE_FRAME_PAYLOAD_BYTES = MAX_FRAME_PAYLOAD_BYTES + 16 // +16 bytes AES-GCM tag
    const val MAX_CONTROL_FRAME_BYTES = 128 * 1024 // 128 KB JSON control limit
}

enum class FrameType(val code: Byte) {
    HELLO(0x01),
    HELLO_ACK(0x02),
    BATCH_START(0x03),
    FILE_START(0x04),
    FILE_CHUNK(0x05),
    FILE_END(0x06),
    PROGRESS_ACK(0x07),
    FILE_RESULT(0x08),
    BATCH_END(0x09),
    CANCEL(0x0A),
    DISCONNECT(0x0B),
    PING(0x0C),
    PONG(0x0D),
    BATCH_ACCEPT(0x0E),
    AUTH_IDENTITY(0x0F),
    AUTH_RESULT(0x10);

    companion object {
        fun fromCode(code: Byte): FrameType? = entries.firstOrNull { it.code == code }
    }
}

data class QRPairingPayload(
    val v: Int,
    val host: String,
    val hosts: List<String> = listOf(host),
    val port: Int,
    val token: String,
    val name: String
) {
    fun toJsonString(): String = JSONObject().apply {
        put("v", v)
        put("host", host)
        put("hosts", JSONArray(hosts))
        put("port", port)
        put("token", token)
        put("name", name)
    }.toString()

    companion object {
        fun parse(raw: String): QRPairingPayload {
            if (raw.length > 8192) {
                throw IllegalArgumentException("QR-код превышает допустимый размер")
            }
            val obj = JSONObject(raw)
            val v = obj.optInt("v", -1)
            if (v != DroplyProtocol.VERSION) {
                throw IllegalArgumentException("Неподдерживаемая версия QR-кода: $v")
            }
            val host = obj.optString("host").trim()
            val hostsArray = obj.optJSONArray("hosts")
            val parsedHosts = buildList {
                if (host.isNotEmpty() && isPrivateLanIPv4(host)) add(host)
                if (hostsArray != null) {
                    val limit = minOf(hostsArray.length(), 16)
                    for (i in 0 until limit) {
                        val candidate = hostsArray.optString(i).trim()
                        if (candidate.isNotEmpty() && isPrivateLanIPv4(candidate) && !contains(candidate) && size < 8) {
                            add(candidate)
                        }
                    }
                }
            }
            val port = obj.optInt("port", -1)
            val token = obj.optString("token").trim()
            val cleanName = SecureChannel.sanitizeDisplayText(obj.optString("name", "MacBook"))
                .ifBlank { "MacBook" }
            if (parsedHosts.isEmpty() || port !in 1..65535 || token.length !in 16..128) {
                throw IllegalArgumentException("Некорректные данные QR-кода")
            }
            return QRPairingPayload(
                v = v,
                host = parsedHosts.first(),
                hosts = parsedHosts,
                port = port,
                token = token,
                name = cleanName
            )
        }

        private fun isPrivateLanIPv4(ip: String): Boolean {
            val parts = ip.split('.')
            if (parts.size != 4) return false
            val octets = IntArray(4)
            for (i in 0 until 4) {
                val p = parts[i]
                if (p.isEmpty() || (p.length > 1 && p.startsWith("0"))) return false
                val n = p.toIntOrNull() ?: return false
                if (n !in 0..255) return false
                octets[i] = n
            }
            return when {
                octets[0] == 10 -> true
                octets[0] == 172 && octets[1] in 16..31 -> true
                octets[0] == 192 && octets[1] == 168 -> true
                else -> false
            }
        }
    }
}

data class RawFrame(
    val type: FrameType,
    val payload: ByteArray
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is RawFrame) return false
        return type == other.type && payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int = 31 * type.hashCode() + payload.contentHashCode()
}

data class HelloAck(
    val ok: Boolean,
    val serverPub: String?,
    val serverNonce: String?,
    val serverProof: String?,
    val error: String?
)

data class AuthResult(
    val ok: Boolean,
    val deviceName: String,
    val error: String?
)

data class BatchStart(
    val batchId: String,
    val totalFiles: Int,
    val totalBytes: Long,
    val previewName: String?
)

data class BatchAccept(
    val batchId: String,
    val accepted: Boolean,
    val reason: String?
)

data class FileStart(
    val fileIndex: Int,
    val relativePath: String,
    val size: Long,
    val isText: Boolean
)

data class ProgressAck(
    val fileIndex: Int,
    val fileBytesReceived: Long,
    val batchBytesReceived: Long,
    val totalBytes: Long,
    val percent: Double
)

data class FileResult(
    val fileIndex: Int,
    val ok: Boolean,
    val savedPath: String?,
    val error: String?
)

object FrameCodec {
    fun encodeFrame(type: FrameType, payload: ByteArray = ByteArray(0), length: Int = payload.size): ByteArray {
        if (length < 0 || length > DroplyProtocol.MAX_FRAME_PAYLOAD_BYTES) {
            throw IllegalArgumentException("Недопустимый размер пакета: $length")
        }
        val packet = ByteArray(5 + length)
        packet[0] = type.code
        ByteBuffer.wrap(packet, 1, 4).order(ByteOrder.BIG_ENDIAN).putInt(length)
        if (length > 0) {
            System.arraycopy(payload, 0, packet, 5, length)
        }
        return packet
    }

    fun writeFrame(
        output: OutputStream,
        type: FrameType,
        payload: ByteArray = ByteArray(0),
        length: Int = payload.size
    ) {
        if (length < 0 || length > DroplyProtocol.MAX_FRAME_PAYLOAD_BYTES) {
            throw IllegalArgumentException("Недопустимый размер пакета: $length")
        }
        val header = ByteArray(5)
        header[0] = type.code
        ByteBuffer.wrap(header, 1, 4).order(ByteOrder.BIG_ENDIAN).putInt(length)
        synchronized(output) {
            output.write(header)
            if (length > 0) {
                output.write(payload, 0, length)
            }
            output.flush()
        }
    }

    fun writeJsonFrame(output: OutputStream, type: FrameType, json: JSONObject) {
        val bytes = json.toString().toByteArray(Charsets.UTF_8)
        writeFrame(output, type, bytes, bytes.size)
    }

    fun writeEncryptedFrame(
        output: OutputStream,
        cipher: SecureChannel.SessionCipher,
        type: FrameType,
        payload: ByteArray = ByteArray(0),
        length: Int = payload.size
    ) {
        synchronized(output) {
            val packet = cipher.sealFrame(type, payload, length)
            output.write(packet)
            output.flush()
        }
    }

    fun writeEncryptedJsonFrame(
        output: OutputStream,
        cipher: SecureChannel.SessionCipher,
        type: FrameType,
        json: JSONObject
    ) {
        val bytes = json.toString().toByteArray(Charsets.UTF_8)
        writeEncryptedFrame(output, cipher, type, bytes, bytes.size)
    }

    fun readFrame(input: InputStream): RawFrame {
        val dataIn = input as? DataInputStream ?: DataInputStream(input)
        val header = ByteArray(5)
        try {
            dataIn.readFully(header)
        } catch (e: EOFException) {
            throw IOException("Соединение закрыто", e)
        }
        val type = FrameType.fromCode(header[0])
            ?: throw IOException("Неизвестный тип пакета: ${header[0].toInt() and 0xFF}")
        val length = ByteBuffer.wrap(header, 1, 4).order(ByteOrder.BIG_ENDIAN).getInt()
        val maxLen = if (type == FrameType.FILE_CHUNK) {
            DroplyProtocol.MAX_WIRE_FRAME_PAYLOAD_BYTES
        } else {
            DroplyProtocol.MAX_CONTROL_FRAME_BYTES + 16
        }
        if (length < 0 || length > maxLen) {
            throw IOException("Недопустимая длина пакета: $length")
        }
        val payload = ByteArray(length)
        if (length > 0) {
            dataIn.readFully(payload)
        }
        return RawFrame(type = type, payload = payload)
    }

    fun readDecryptedFrame(input: InputStream, cipher: SecureChannel.SessionCipher): RawFrame {
        val raw = readFrame(input)
        val decrypted = cipher.openPayload(raw.type, raw.payload)
        return RawFrame(type = raw.type, payload = decrypted)
    }

    fun parseHelloAck(payload: ByteArray): HelloAck {
        val obj = JSONObject(String(payload, Charsets.UTF_8))
        return HelloAck(
            ok = obj.optBoolean("ok", false),
            serverPub = obj.optString("serverPub").takeIf { it.isNotEmpty() && it != "null" },
            serverNonce = obj.optString("serverNonce").takeIf { it.isNotEmpty() && it != "null" },
            serverProof = obj.optString("serverProof").takeIf { it.isNotEmpty() && it != "null" },
            error = obj.optString("error").takeIf { it.isNotEmpty() && it != "null" }
        )
    }

    fun parseAuthResult(payload: ByteArray): AuthResult {
        val obj = JSONObject(String(payload, Charsets.UTF_8))
        return AuthResult(
            ok = obj.optBoolean("ok", false),
            deviceName = SecureChannel.sanitizeDisplayText(obj.optString("deviceName", "MacBook")).ifBlank { "MacBook" },
            error = obj.optString("error").takeIf { it.isNotEmpty() && it != "null" }
        )
    }

    fun parseBatchStart(payload: ByteArray): BatchStart {
        val obj = JSONObject(String(payload, Charsets.UTF_8))
        return BatchStart(
            batchId = obj.optString("batchId"),
            totalFiles = obj.optInt("totalFiles", 0),
            totalBytes = obj.optLong("totalBytes", 0L),
            previewName = obj.optString("previewName").takeIf { it.isNotEmpty() && it != "null" }
        )
    }

    fun parseBatchAccept(payload: ByteArray): BatchAccept {
        val obj = JSONObject(String(payload, Charsets.UTF_8))
        return BatchAccept(
            batchId = obj.optString("batchId"),
            accepted = obj.optBoolean("accepted", false),
            reason = obj.optString("reason").takeIf { it.isNotEmpty() && it != "null" }
        )
    }

    fun parseFileStart(payload: ByteArray): FileStart {
        val obj = JSONObject(String(payload, Charsets.UTF_8))
        return FileStart(
            fileIndex = obj.optInt("fileIndex", 0),
            relativePath = obj.optString("relativePath"),
            size = obj.optLong("size", 0L),
            isText = obj.optBoolean("isText", false)
        )
    }

    fun parseProgressAck(payload: ByteArray): ProgressAck {
        val obj = JSONObject(String(payload, Charsets.UTF_8))
        return ProgressAck(
            fileIndex = obj.optInt("fileIndex", 0),
            fileBytesReceived = obj.optLong("fileBytesReceived", 0L),
            batchBytesReceived = obj.optLong("batchBytesReceived", 0L),
            totalBytes = obj.optLong("totalBytes", 0L),
            percent = obj.optDouble("percent", 0.0)
        )
    }

    fun parseFileResult(payload: ByteArray): FileResult {
        val obj = JSONObject(String(payload, Charsets.UTF_8))
        return FileResult(
            fileIndex = obj.optInt("fileIndex", 0),
            ok = obj.optBoolean("ok", false),
            savedPath = obj.optString("savedPath").takeIf { it.isNotEmpty() && it != "null" },
            error = obj.optString("error").takeIf { it.isNotEmpty() && it != "null" }
        )
    }
}
