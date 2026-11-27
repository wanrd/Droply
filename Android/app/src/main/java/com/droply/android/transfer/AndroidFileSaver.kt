package com.droply.android.transfer

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream

interface IncomingFileWriter {
    val outputStream: OutputStream
    fun commit(): SavedFileInfo
    fun abort()
}

data class SavedFileInfo(
    val displayPath: String,
    val contentUri: Uri?
)

object AndroidFileSaver {
    private const val MAX_PATH_DEPTH = 32
    private const val MAX_SEGMENT_BYTES = 255

    fun sanitizeRelativePath(relativePath: String): List<String> {
        if (relativePath.isEmpty() || containsForbiddenCharacters(relativePath)) {
            throw IOException("Недопустимый путь к файлу")
        }
        val normalized = relativePath.replace('\\', '/')
        if (normalized.startsWith("/")) {
            throw IOException("Абсолютный путь запрещён")
        }
        val parts = normalized.split('/')
        if (parts.size > MAX_PATH_DEPTH) {
            throw IOException("Слишком глубокий путь к файлу")
        }
        val clean = mutableListOf<String>()
        for (part in parts) {
            if (part.isEmpty() || part == "." || part == "..") {
                throw IOException("Небезопасный сегмент пути: $part")
            }
            if (part.toByteArray(Charsets.UTF_8).size > MAX_SEGMENT_BYTES) {
                throw IOException("Слишком длинное имя файла")
            }
            if (clean.isEmpty() && part.length >= 2 && part[1] == ':') {
                throw IOException("Недопустимый префикс пути")
            }
            clean.add(part)
        }
        if (clean.isEmpty()) throw IOException("Пустой путь к файлу")
        return clean
    }

    private fun containsForbiddenCharacters(value: String): Boolean {
        var i = 0
        while (i < value.length) {
            val cp = value.codePointAt(i)
            val charCount = Character.charCount(cp)
            if (cp < 0x20 || cp == 0x7F || cp in 0x202A..0x202E || cp in 0x2066..0x2069 || cp == 0x200E || cp == 0x200F) {
                return true
            }
            i += charCount
        }
        return false
    }

    fun openWriter(context: Context, relativePath: String): IncomingFileWriter {
        val parts = sanitizeRelativePath(relativePath)
        val fileName = parts.last()
        val subFolders = parts.dropLast(1)

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val subPath = if (subFolders.isEmpty()) {
                "${Environment.DIRECTORY_DOWNLOADS}/Droply"
            } else {
                "${Environment.DIRECTORY_DOWNLOADS}/Droply/${subFolders.joinToString("/")}"
            }
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.RELATIVE_PATH, subPath)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("Не удалось создать файл в Загрузках")
            val stream = runCatching { resolver.openOutputStream(uri) }.getOrNull()
                ?: run {
                    resolver.delete(uri, null, null)
                    throw IOException("Не удалось открыть поток записи для $fileName")
                }

            object : IncomingFileWriter {
                override val outputStream: OutputStream = stream

                override fun commit(): SavedFileInfo {
                    runCatching { stream.flush() }
                    stream.close()
                    val doneValues = ContentValues().apply {
                        put(MediaStore.Downloads.IS_PENDING, 0)
                    }
                    resolver.update(uri, doneValues, null, null)
                    return SavedFileInfo(
                        displayPath = "Downloads/Droply/${parts.joinToString("/")}",
                        contentUri = uri
                    )
                }

                override fun abort() {
                    runCatching { stream.close() }
                    runCatching { resolver.delete(uri, null, null) }
                }
            }
        } else {
            val baseDir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: context.filesDir
            val droplyRoot = File(baseDir, "Droply")
            if (!droplyRoot.exists() && !droplyRoot.mkdirs()) {
                throw IOException("Не удалось создать папку Droply")
            }
            var targetDir = droplyRoot
            for (folder in subFolders) {
                targetDir = File(targetDir, folder)
            }
            if (!targetDir.exists() && !targetDir.mkdirs()) {
                throw IOException("Не удалось создать папку ${targetDir.name}")
            }
            val canonicalRoot = droplyRoot.canonicalPath
            val canonicalTarget = targetDir.canonicalPath
            if (canonicalTarget != canonicalRoot && !canonicalTarget.startsWith("$canonicalRoot${File.separator}")) {
                throw IOException("Небезопасный путь сохранения")
            }
            val tempFile = File(targetDir, ".${System.nanoTime()}.droply.part")
            val finalFile = resolveUniqueFile(targetDir, fileName)
            val stream = FileOutputStream(tempFile)

            object : IncomingFileWriter {
                override val outputStream: OutputStream = stream

                override fun commit(): SavedFileInfo {
                    runCatching { stream.flush() }
                    stream.close()
                    if (!tempFile.renameTo(finalFile)) {
                        tempFile.copyTo(finalFile, overwrite = true)
                        tempFile.delete()
                    }
                    return SavedFileInfo(
                        displayPath = finalFile.absolutePath,
                        contentUri = Uri.fromFile(finalFile)
                    )
                }

                override fun abort() {
                    runCatching { stream.close() }
                    runCatching { tempFile.delete() }
                }
            }
        }
    }

    fun readTextFromUri(context: Context, uri: Uri, maxBytes: Int = 5 * 1024 * 1024): String? {
        return runCatching {
            context.contentResolver.openInputStream(uri)?.use { input ->
                val data = input.readNBytes(maxBytes)
                String(data, Charsets.UTF_8)
            }
        }.getOrNull()
    }

    private fun resolveUniqueFile(dir: File, name: String): File {
        val candidate = File(dir, name)
        if (!candidate.exists()) return candidate
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var counter = 1
        while (true) {
            val next = File(dir, "$base ($counter)$ext")
            if (!next.exists()) return next
            counter++
        }
    }
}
