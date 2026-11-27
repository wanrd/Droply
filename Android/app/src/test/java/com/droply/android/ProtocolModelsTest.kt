package com.droply.android

import com.droply.android.protocol.FrameCodec
import com.droply.android.protocol.FrameType
import com.droply.android.protocol.QRPairingPayload
import com.droply.android.transfer.AndroidFileSaver
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException

class ProtocolModelsTest {

    @Test
    fun qrPayloadRoundtrip() {
        val original = QRPairingPayload(
            v = 1,
            host = "192.168.1.42",
            hosts = listOf("192.168.1.42", "192.168.1.99"),
            port = 45820,
            token = "0123456789abcdef0123456789abcdef",
            name = "MacBook Pro"
        )
        val parsed = QRPairingPayload.parse(original.toJsonString())
        assertEquals(original, parsed)
    }

    @Test(expected = IllegalArgumentException::class)
    fun qrPayloadRejectsInvalidVersion() {
        QRPairingPayload.parse("""{"v":99,"host":"192.168.1.1","port":45820,"token":"0123456789abcdef"}""")
    }

    @Test
    fun qrPayloadRejectsPublicAndUnsafeHostsAndWeakTokens() {
        val badHosts = listOf("8.8.8.8", "127.0.0.1", "169.254.1.1", "100.64.0.1", "evil.example")
        for (badHost in badHosts) {
            assertThrows(IllegalArgumentException::class.java) {
                QRPairingPayload.parse(
                    """{"v":1,"host":"$badHost","port":45820,"token":"0123456789abcdef0123456789abcdef","name":"Mac"}"""
                )
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            QRPairingPayload.parse("""{"v":1,"host":"192.168.1.10","port":45820,"token":"short"}""")
        }
        assertThrows(IllegalArgumentException::class.java) {
            QRPairingPayload.parse("x".repeat(9000))
        }
    }

    @Test
    fun qrPayloadSanitizesDisplayName() {
        val parsed = QRPairingPayload.parse(
            "{\"v\":1,\"host\":\"192.168.1.10\",\"port\":45820,\"token\":\"0123456789abcdef0123456789abcdef\",\"name\":\"Mac\\u202EBook\\nPro\"}"
        )
        assertEquals("MacBookPro", parsed.name)
    }

    @Test
    fun pathSanitizerBlocksTraversalBidiControlAndDepth() {
        val unsafePaths = listOf(
            "../secret.txt",
            "/etc/passwd",
            "folder/../../evil",
            "C:\\Windows\\System32\\cmd.exe",
            "good\u202Etxt.exe",
            "bad\nname.txt",
            List(33) { "d" }.joinToString("/") + "/file.txt",
            "a".repeat(260)
        )
        for (bad in unsafePaths) {
            assertThrows(IOException::class.java) {
                AndroidFileSaver.sanitizeRelativePath(bad)
            }
        }
        assertEquals(listOf("Photos", "2026", "img.jpg"), AndroidFileSaver.sanitizeRelativePath("Photos/2026/img.jpg"))
    }

    @Test
    fun binaryFrameRoundtrip() {
        val payload = "Привет, MacBook!".toByteArray(Charsets.UTF_8)
        val encoded = FrameCodec.encodeFrame(FrameType.FILE_CHUNK, payload)
        val decoded = FrameCodec.readFrame(ByteArrayInputStream(encoded))
        assertEquals(FrameType.FILE_CHUNK, decoded.type)
        assertArrayEquals(payload, decoded.payload)
    }
}
