package com.droply.android.transfer

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.documentfile.provider.DocumentFile
import java.util.Locale
import kotlin.math.min

sealed class TransferItem(
    open val relativePath: String,
    open val sizeBytes: Long,
    open val isText: Boolean
) {
    data class UriItem(
        val uri: Uri,
        override val relativePath: String,
        override val sizeBytes: Long,
        override val isText: Boolean
    ) : TransferItem(relativePath, sizeBytes, isText)

    data class TextNoteItem(
        override val relativePath: String,
        val bytes: ByteArray
    ) : TransferItem(relativePath, bytes.size.toLong(), true) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is TextNoteItem) return false
            return relativePath == other.relativePath && bytes.contentEquals(other.bytes)
        }

        override fun hashCode(): Int = 31 * relativePath.hashCode() + bytes.contentHashCode()
    }
}

object FileTreeCollector {
    fun collectFromFileUris(context: Context, uris: List<Uri>): List<TransferItem.UriItem> {
        val resolver = context.contentResolver
        return uris.mapNotNull { uri ->
            var name = "file_${System.currentTimeMillis()}"
            var size = -1L
            runCatching {
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
                    ?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                            if (nameIdx >= 0) {
                                cursor.getString(nameIdx)?.takeIf { it.isNotBlank() }?.let { name = it }
                            }
                            if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) {
                                size = cursor.getLong(sizeIdx)
                            }
                        }
                    }
            }
            if (size < 0) {
                size = resolveFallbackSize(resolver, uri)
            }
            val mimeType = runCatching { resolver.getType(uri) }.getOrNull()
            val isText = (mimeType?.startsWith("text/") == true) ||
                name.endsWith(".txt", ignoreCase = true) ||
                name.endsWith(".md", ignoreCase = true) ||
                name.endsWith(".json", ignoreCase = true) ||
                name.endsWith(".csv", ignoreCase = true) ||
                name.endsWith(".log", ignoreCase = true)

            TransferItem.UriItem(
                uri = uri,
                relativePath = sanitizeSegment(name),
                sizeBytes = size,
                isText = isText
            )
        }
    }

    fun collectFromTreeUri(context: Context, treeUri: Uri): List<TransferItem.UriItem> {
        val root = DocumentFile.fromTreeUri(context, treeUri) ?: return emptyList()
        val rootName = sanitizeSegment(root.name ?: "Folder")
        val collected = mutableListOf<TransferItem.UriItem>()
        traverseDirectory(context, root, rootName, collected)
        return collected
    }

    private fun traverseDirectory(
        context: Context,
        directory: DocumentFile,
        currentPrefix: String,
        output: MutableList<TransferItem.UriItem>
    ) {
        val children = directory.listFiles()
        for (child in children) {
            val childName = sanitizeSegment(child.name ?: continue)
            val relativePath = "$currentPrefix/$childName"
            if (child.isDirectory) {
                traverseDirectory(context, child, relativePath, output)
            } else if (child.isFile) {
                var size = child.length()
                if (size < 0) {
                    size = resolveFallbackSize(context.contentResolver, child.uri)
                }
                val mimeType = child.type
                val isText = (mimeType?.startsWith("text/") == true) ||
                    childName.endsWith(".txt", ignoreCase = true)
                output.add(
                    TransferItem.UriItem(
                        uri = child.uri,
                        relativePath = relativePath,
                        sizeBytes = size,
                        isText = isText
                    )
                )
            }
        }
    }

    private fun resolveFallbackSize(resolver: ContentResolver, uri: Uri): Long {
        val fdSize = runCatching {
            resolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
        }.getOrDefault(-1L)
        if (fdSize >= 0) return fdSize

        return runCatching {
            resolver.openInputStream(uri)?.use { input ->
                val buf = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val read = input.read(buf)
                    if (read <= 0) break
                    total += read
                }
                total
            } ?: 0L
        }.getOrDefault(0L)
    }

    fun buildTextNoteItem(rawFileName: String, textContent: String): TransferItem.TextNoteItem {
        val trimmed = rawFileName.trim().ifEmpty { "note_${System.currentTimeMillis()}" }
        val normalizedName = if (trimmed.contains('.')) trimmed else "$trimmed.txt"
        val safeName = sanitizeSegment(normalizedName)
        return TransferItem.TextNoteItem(
            relativePath = safeName,
            bytes = textContent.toByteArray(Charsets.UTF_8)
        )
    }

    private fun sanitizeSegment(segment: String): String {
        val cleaned = segment
            .replace("/", "_")
            .replace("\\", "_")
            .replace("\u0000", "")
            .trim()
        return if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") "item" else cleaned
    }

    fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes Б"
        val kb = bytes / 1024.0
        if (kb < 1024) return String.format(Locale.getDefault(), "%.1f КБ", kb)
        val mb = kb / 1024.0
        if (mb < 1024) return String.format(Locale.getDefault(), "%.1f МБ", mb)
        val gb = mb / 1024.0
        if (gb < 1024) return String.format(Locale.getDefault(), "%.2f ГБ", gb)
        val tb = gb / 1024.0
        return String.format(Locale.getDefault(), "%.2f ТБ", tb)
    }

    fun formatSpeed(bytesPerSecond: Double): String {
        if (bytesPerSecond <= 0) return "0 Б/с"
        val clamped = min(bytesPerSecond, Long.MAX_VALUE.toDouble()).toLong()
        return "${formatBytes(clamped)}/с"
    }
}
