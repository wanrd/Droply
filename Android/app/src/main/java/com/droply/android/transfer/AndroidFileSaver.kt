package com.droply.android.transfer

import android.app.DownloadManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToInt

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

    private val photoExtensions = setOf("jpg", "jpeg", "png", "webp", "heic", "heif", "gif", "bmp")

    fun isPhotoFile(relativePath: String, isText: Boolean): Boolean {
        if (isText) return false
        val ext = relativePath.substringAfterLast('.', "").lowercase(Locale.US)
        return ext in photoExtensions
    }

    fun loadSampledImageBitmap(
        context: Context,
        uri: Uri,
        maxDimension: Int = 1600
    ): ImageBitmap? {
        return runCatching {
            val resolver = context.contentResolver
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val source = ImageDecoder.createSource(resolver, uri)
                ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    val w = info.size.width
                    val h = info.size.height
                    val longest = max(w, h)
                    if (longest > maxDimension && w > 0 && h > 0) {
                        val ratio = maxDimension.toFloat() / longest.toFloat()
                        decoder.setTargetSize(
                            (w * ratio).roundToInt().coerceAtLeast(1),
                            (h * ratio).roundToInt().coerceAtLeast(1)
                        )
                    }
                }.asImageBitmap()
            } else {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                val longest = max(bounds.outWidth, bounds.outHeight)
                var sample = 1
                while (longest / sample > maxDimension * 2) {
                    sample *= 2
                }
                val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sample }
                resolver.openInputStream(uri)?.use { stream ->
                    BitmapFactory.decodeStream(stream, null, decodeOpts)?.asImageBitmap()
                }
            }
        }.getOrNull()
    }

    fun openInFileManager(context: Context, record: SentFileRecord): Boolean {
        val parts = record.relativePath.split('/').filter { it.isNotBlank() }
        val subDirs = if (parts.size > 1) parts.dropLast(1) else emptyList()
        val folderDocId = if (subDirs.isEmpty()) {
            "primary:${Environment.DIRECTORY_DOWNLOADS}/Droply"
        } else {
            "primary:${Environment.DIRECTORY_DOWNLOADS}/Droply/${subDirs.joinToString("/")}"
        }

        val candidateIntents = buildList {
            // 1. Direct DocumentsUI / Files folder view inside Downloads/Droply
            val dirUri = DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents",
                folderDocId
            )
            add(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(dirUri, DocumentsContract.Document.MIME_TYPE_DIR)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            )
            // 2. Fallback to root Droply downloads folder
            if (subDirs.isNotEmpty()) {
                val rootDroplyUri = DocumentsContract.buildDocumentUri(
                    "com.android.externalstorage.documents",
                    "primary:${Environment.DIRECTORY_DOWNLOADS}/Droply"
                )
                add(
                    Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(rootDroplyUri, DocumentsContract.Document.MIME_TYPE_DIR)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                )
            }
            // 3. System Downloads manager / explorer
            add(
                Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            // 4. Direct file URI view
            record.savedUri?.let { fileUri ->
                val ext = record.relativePath.substringAfterLast('.', "").lowercase(Locale.US)
                val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
                    ?: context.contentResolver.getType(fileUri)
                    ?: "*/*"
                add(
                    Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(fileUri, mime)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                )
            }
        }

        for (intent in candidateIntents) {
            val started = runCatching {
                context.startActivity(intent)
                true
            }.getOrDefault(false)
            if (started) return true
        }
        return false
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
