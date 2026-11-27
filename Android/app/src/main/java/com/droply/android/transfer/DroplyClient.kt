package com.droply.android.transfer

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import androidx.compose.runtime.Immutable
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.droply.android.R
import com.droply.android.protocol.BatchAccept
import com.droply.android.protocol.BatchStart
import com.droply.android.protocol.DroplyProtocol
import com.droply.android.protocol.FileResult
import com.droply.android.protocol.FileStart
import com.droply.android.protocol.FrameCodec
import com.droply.android.protocol.FrameType
import com.droply.android.protocol.QRPairingPayload
import com.droply.android.protocol.SecureChannel
import com.droply.android.update.AppUpdateChecker
import com.droply.android.update.AppUpdateConfig
import com.droply.android.update.AppUpdateInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.ConnectException
import java.net.InetSocketAddress
import java.net.NoRouteToHostException
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.security.interfaces.ECPublicKey
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min

@Immutable
sealed class ConnectionState {
    data object Disconnected : ConnectionState()
    data object Connecting : ConnectionState()
    data class Connected(val macName: String, val host: String, val port: Int) : ConnectionState()
}

@Immutable
data class TransferProgressUi(
    val fileIndex: Int,
    val totalFiles: Int,
    val currentFileName: String,
    val bytesTransferred: Long,
    val totalBytes: Long,
    val percent: Double,
    val speedBytesPerSecond: Double,
    val isIncoming: Boolean = false
)

@Immutable
data class SentFileRecord(
    val id: String = UUID.randomUUID().toString(),
    val relativePath: String,
    val sizeBytes: Long,
    val isText: Boolean,
    val ok: Boolean,
    val isIncoming: Boolean = false,
    val savedUri: Uri? = null,
    val textContent: String? = null,
    val errorMessage: String? = null
)

@Immutable
data class IncomingBatchRequestUi(
    val batchId: String,
    val senderName: String,
    val totalFiles: Int,
    val totalBytes: Long,
    val previewName: String?
)

private class IncomingReceiveSession(
    val batch: BatchStart,
    var approved: Boolean? = null,
    var cancelled: Boolean = false
) {
    val startMs: Long = System.currentTimeMillis()
    var batchBytesReceived: Long = 0L
    var completedCount: Int = 0
    var lastAckMs: Long = 0L
    var lastAckBytes: Long = 0L
    var currentFile: FileStart? = null
    var currentWriter: IncomingFileWriter? = null
    var currentHasher: MessageDigest? = null
    var currentFileBytes: Long = 0L
    var textBuffer: MutableList<Byte>? = null

    fun cleanupActiveWriter() {
        currentWriter?.abort()
        currentWriter = null
        currentFile = null
        currentHasher = null
        textBuffer = null
    }
}

class DroplyClient {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val connectionMutex = Mutex()
    private val transferMutex = Mutex()

    private val _connectionState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val _isTransferring = MutableStateFlow(false)
    val isTransferring: StateFlow<Boolean> = _isTransferring.asStateFlow()

    private val _progress = MutableStateFlow<TransferProgressUi?>(null)
    val progress: StateFlow<TransferProgressUi?> = _progress.asStateFlow()

    private val _history = MutableStateFlow<List<SentFileRecord>>(emptyList())
    val history: StateFlow<List<SentFileRecord>> = _history.asStateFlow()

    private val _incomingRequest = MutableStateFlow<IncomingBatchRequestUi?>(null)
    val incomingRequest: StateFlow<IncomingBatchRequestUi?> = _incomingRequest.asStateFlow()

    private val _statusMessage = MutableStateFlow<String?>(null)
    val statusMessage: StateFlow<String?> = _statusMessage.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val _deviceName = MutableStateFlow(defaultDeviceName())
    val deviceName: StateFlow<String> = _deviceName.asStateFlow()

    private val _requireIncomingConfirmation = MutableStateFlow(true)
    val requireIncomingConfirmation: StateFlow<Boolean> = _requireIncomingConfirmation.asStateFlow()

    private val _availableUpdate = MutableStateFlow<AppUpdateInfo?>(null)
    val availableUpdate: StateFlow<AppUpdateInfo?> = _availableUpdate.asStateFlow()

    private val _showUpdatePrompt = MutableStateFlow(false)
    val showUpdatePrompt: StateFlow<Boolean> = _showUpdatePrompt.asStateFlow()

    private val _isCheckingForUpdates = MutableStateFlow(false)
    val isCheckingForUpdates: StateFlow<Boolean> = _isCheckingForUpdates.asStateFlow()

    @Volatile
    private var lastUpdateCheckMs: Long = 0L

    @Volatile
    private var lastPromptedUpdateVersion: String? = null

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var serviceObserverStarted = false

    @Volatile
    private var connectedMacName: String = "MacBook"

    @Volatile
    private var socket: Socket? = null

    @Volatile
    private var outputStream: OutputStream? = null

    @Volatile
    private var heartbeatJob: Job? = null

    @Volatile
    private var sessionCipher: SecureChannel.SessionCipher? = null

    @Volatile
    private var lastFrameReceivedMs: Long = 0L

    private val outgoingCancelRequested = AtomicBoolean(false)
    private val outgoingCancelSent = AtomicBoolean(false)

    @Volatile
    private var batchAcceptDeferred: CompletableDeferred<BatchAccept>? = null
    private val pendingFileResults = ConcurrentHashMap<Int, CompletableDeferred<FileResult>>()

    @Volatile
    private var incomingSession: IncomingReceiveSession? = null

    @Volatile
    private var activeBatchStartMs: Long = 0L

    @Volatile
    private var activeBatchTotalFiles: Int = 0

    @Volatile
    private var activeBatchTotalBytes: Long = 0L

    @Volatile
    private var activeCurrentFileName: String = ""

    @Volatile
    private var confirmedBatchBytes: Long = 0L

    @Volatile
    private var confirmedPercent: Double = 0.0

    @Volatile
    private var historyLoaded = false

    fun bindApplicationContext(context: Context) {
        val ctx = context.applicationContext
        appContext = ctx
        loadSettings(ctx)
        if (!serviceObserverStarted) {
            serviceObserverStarted = true
            scope.launch {
                combine(
                    _connectionState,
                    _isTransferring,
                    _incomingRequest
                ) { conn, transferring, incoming ->
                    conn is ConnectionState.Connected || transferring || incoming != null
                }.distinctUntilChanged().collect { shouldRun ->
                    if (shouldRun) {
                        syncBackgroundService()
                    }
                }
            }
        }
        loadHistoryIfNeeded(ctx)
    }

    fun shouldKeepServiceRunning(): Boolean {
        return _connectionState.value is ConnectionState.Connected ||
            _isTransferring.value ||
            _incomingRequest.value != null
    }

    private fun syncBackgroundService() {
        val ctx = appContext ?: return
        if (shouldKeepServiceRunning() && !DroplyTransferService.isRunning.get()) {
            DroplyTransferService.start(ctx)
        }
    }

    fun startConnect(context: Context, payload: QRPairingPayload) {
        bindApplicationContext(context)
        scope.launch {
            connect(context.applicationContext, payload)
        }
    }

    fun startSendItems(context: Context, items: List<TransferItem>) {
        if (items.isEmpty()) return
        bindApplicationContext(context)
        scope.launch {
            sendItems(context.applicationContext, items)
        }
    }

    fun loadHistoryIfNeeded(context: Context) {
        val ctx = context.applicationContext
        appContext = ctx
        if (historyLoaded) return
        historyLoaded = true
        scope.launch {
            val file = File(ctx.filesDir, "droply_history.json")
            val legacyFile = File(ctx.filesDir, "wifidrop_history.json")
            val sourceFile = if (file.exists()) file else legacyFile
            if (!sourceFile.exists()) return@launch
            val loaded = runCatching {
                val arr = JSONArray(sourceFile.readText(Charsets.UTF_8))
                buildList {
                    for (i in 0 until arr.length()) {
                        val o = arr.getJSONObject(i)
                        add(
                            SentFileRecord(
                                id = o.optString("id", UUID.randomUUID().toString()),
                                relativePath = o.optString("relativePath"),
                                sizeBytes = o.optLong("sizeBytes", 0L),
                                isText = o.optBoolean("isText", false),
                                ok = o.optBoolean("ok", true),
                                isIncoming = o.optBoolean("isIncoming", false),
                                savedUri = o.optString("savedUri").takeIf { it.isNotBlank() }?.let { Uri.parse(it) },
                                textContent = o.optString("textContent").takeIf { o.has("textContent") && !o.isNull("textContent") },
                                errorMessage = o.optString("errorMessage").takeIf { o.has("errorMessage") && !o.isNull("errorMessage") }
                            )
                        )
                    }
                }
            }.getOrNull() ?: return@launch
            if (_history.value.isEmpty() && loaded.isNotEmpty()) {
                _history.value = loaded
            }
        }
    }

    private fun saveHistoryAsync() {
        val ctx = appContext ?: return
        val snapshot = _history.value
        scope.launch {
            runCatching {
                val arr = JSONArray()
                for (item in snapshot) {
                    arr.put(
                        JSONObject().apply {
                            put("id", item.id)
                            put("relativePath", item.relativePath)
                            put("sizeBytes", item.sizeBytes)
                            put("isText", item.isText)
                            put("ok", item.ok)
                            put("isIncoming", item.isIncoming)
                            if (item.savedUri != null) put("savedUri", item.savedUri.toString())
                            if (item.textContent != null) put("textContent", item.textContent)
                            if (item.errorMessage != null) put("errorMessage", item.errorMessage)
                        }
                    )
                }
                File(ctx.filesDir, "droply_history.json").writeText(arr.toString(), Charsets.UTF_8)
            }
        }
    }

    fun clearMessages() {
        _statusMessage.value = null
        _errorMessage.value = null
    }

    fun setDeviceName(name: String) {
        val trimmed = SecureChannel.sanitizeDisplayText(name).ifEmpty { defaultDeviceName() }
        _deviceName.value = trimmed
        appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ?.edit()
            ?.putString(KEY_DEVICE_NAME, trimmed)
            ?.apply()
    }

    fun setRequireIncomingConfirmation(require: Boolean) {
        _requireIncomingConfirmation.value = require
        appContext?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ?.edit()
            ?.putBoolean(KEY_REQUIRE_INCOMING_CONFIRM, require)
            ?.apply()
    }

    fun getPersistedDarkTheme(context: Context, fallbackDark: Boolean): Boolean {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return if (prefs.contains(KEY_DARK_THEME)) {
            prefs.getBoolean(KEY_DARK_THEME, fallbackDark)
        } else {
            fallbackDark
        }
    }

    fun setPersistedDarkTheme(context: Context, dark: Boolean) {
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_DARK_THEME, dark)
            .apply()
    }

    private fun loadSettings(ctx: Context) {
        val prefs = ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val savedName = prefs.getString(KEY_DEVICE_NAME, null)
            ?.let { SecureChannel.sanitizeDisplayText(it) }
        if (!savedName.isNullOrEmpty()) {
            _deviceName.value = savedName
        }
        _requireIncomingConfirmation.value = prefs.getBoolean(KEY_REQUIRE_INCOMING_CONFIRM, true)
    }

    private fun defaultDeviceName(): String {
        val manufacturer = (Build.MANUFACTURER ?: "").trim()
        val model = (Build.MODEL ?: "").trim()
        val raw = "${manufacturer.replaceFirstChar { it.uppercase() }} $model".trim()
        return SecureChannel.sanitizeDisplayText(raw).ifEmpty { "Android" }
    }

    companion object {
        private const val PREFS_NAME = "droply_prefs"
        private const val KEY_DEVICE_NAME = "device_name"
        private const val KEY_REQUIRE_INCOMING_CONFIRM = "require_incoming_confirmation"
        private const val KEY_DARK_THEME = "is_dark_theme"
        private const val MAX_BATCH_FILES = 50_000
        private const val MAX_BATCH_BYTES = 100L * 1024L * 1024L * 1024L
        private const val DISK_FREE_MARGIN_BYTES = 256L * 1024L * 1024L
    }

    fun removeHistoryItem(id: String) {
        _history.value = _history.value.filterNot { it.id == id }
        saveHistoryAsync()
    }

    fun clearHistory() {
        _history.value = emptyList()
        saveHistoryAsync()
    }

    fun copyTextRecord(context: Context, record: SentFileRecord) {
        scope.launch {
            val text = record.textContent
                ?: record.savedUri?.let { AndroidFileSaver.readTextFromUri(context, it) }
            if (text == null) {
                _errorMessage.value = "Не удалось прочитать текст из файла"
                return@launch
            }
            withContext(Dispatchers.Main) {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                cm?.setPrimaryClip(ClipData.newPlainText("Droply", text))
                _errorMessage.value = null
                _statusMessage.value = "Текст скопирован в буфер обмена"
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun findWifiNetwork(context: Context): Network? {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return null
        val active = cm.activeNetwork
        if (active != null) {
            val caps = cm.getNetworkCapabilities(active)
            if (caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            ) {
                return active
            }
        }
        return cm.allNetworks.firstOrNull { network ->
            val caps = cm.getNetworkCapabilities(network)
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
    }

    suspend fun connect(context: Context, payload: QRPairingPayload) = withContext(Dispatchers.IO) {
        appContext = context.applicationContext
        connectionMutex.withLock {
            disconnectInternal(notifyPeer = false)
            _errorMessage.value = null
            _statusMessage.value = null
            _connectionState.value = ConnectionState.Connecting

            try {
                val wifiNetwork = findWifiNetwork(context)
                var connectedSocket: Socket? = null
                var connectedHost = payload.host
                var lastError: Exception? = null

                for (candidateHost in payload.hosts) {
                    val factories: List<() -> Socket> = if (wifiNetwork != null) {
                        listOf(
                            { wifiNetwork.socketFactory.createSocket() },
                            { Socket() }
                        )
                    } else {
                        listOf { Socket() }
                    }

                    for (factory in factories) {
                        val attempt = runCatching {
                            val sock = factory()
                            sock.tcpNoDelay = true
                            sock.keepAlive = true
                            sock.sendBufferSize = DroplyProtocol.CHUNK_SIZE * 2
                            sock.connect(InetSocketAddress(candidateHost, payload.port), 5500)
                            sock
                        }
                        if (attempt.isSuccess) {
                            connectedSocket = attempt.getOrNull()
                            connectedHost = candidateHost
                            break
                        } else {
                            lastError = attempt.exceptionOrNull() as? Exception
                        }
                    }
                    if (connectedSocket != null) break
                }

                val newSocket = connectedSocket ?: throw (lastError ?: IOException("Не удалось подключиться"))
                newSocket.soTimeout = 10000

                val out = newSocket.getOutputStream()
                val input = DataInputStream(newSocket.getInputStream())

                val deviceName = SecureChannel.sanitizeDisplayText(_deviceName.value.ifBlank { defaultDeviceName() })
                    .ifBlank { "Android" }
                val ephemeralPair = SecureChannel.generateEphemeralKeyPair()
                val ecPublic = ephemeralPair.public as ECPublicKey
                val clientPubBytes = SecureChannel.publicKeyToX963(ecPublic)
                val clientNonceBytes = SecureChannel.randomBytes(32)
                val psk = SecureChannel.derivePsk(payload.token)
                val clientProofBytes = SecureChannel.computeClientProof(psk, clientPubBytes, clientNonceBytes)

                val encoder = Base64.getEncoder()
                val decoder = Base64.getDecoder()

                val helloJson = JSONObject().apply {
                    put("clientPub", encoder.encodeToString(clientPubBytes))
                    put("clientNonce", encoder.encodeToString(clientNonceBytes))
                    put("clientProof", encoder.encodeToString(clientProofBytes))
                }
                _statusMessage.value = "Установка защищённого соединения..."
                FrameCodec.writeJsonFrame(out, FrameType.HELLO, helloJson)

                val ackFrame = FrameCodec.readFrame(input)
                if (ackFrame.type != FrameType.HELLO_ACK) {
                    throw IOException("Неожиданный ответ от MacBook")
                }
                val ack = FrameCodec.parseHelloAck(ackFrame.payload)
                if (!ack.ok) {
                    throw IOException(ack.error ?: "MacBook отклонил подключение")
                }

                val serverPubBytes = ack.serverPub?.let { runCatching { decoder.decode(it) }.getOrNull() }
                    ?.takeIf { it.size == 65 }
                    ?: throw IOException("Некорректный открытый ключ MacBook")
                val serverNonceBytes = ack.serverNonce?.let { runCatching { decoder.decode(it) }.getOrNull() }
                    ?.takeIf { it.size == 32 }
                    ?: throw IOException("Некорректный nonce MacBook")
                val serverProofBytes = ack.serverProof?.let { runCatching { decoder.decode(it) }.getOrNull() }
                    ?.takeIf { it.size == 32 }
                    ?: throw IOException("Отсутствует подтверждение подлинности MacBook")

                val expectedServerProof = SecureChannel.computeServerProof(
                    psk = psk,
                    clientPub = clientPubBytes,
                    serverPub = serverPubBytes,
                    clientNonce = clientNonceBytes,
                    serverNonce = serverNonceBytes
                )
                if (!SecureChannel.constantTimeEquals(serverProofBytes, expectedServerProof)) {
                    throw IOException("Ошибка проверки подлинности MacBook")
                }

                val serverPublicKey = SecureChannel.x963ToPublicKey(serverPubBytes, ecPublic.params)
                val sharedSecret = SecureChannel.computeSharedSecret(ephemeralPair.private, serverPublicKey)
                val cipher = SecureChannel.SessionCipher(
                    sharedSecret = sharedSecret,
                    psk = psk,
                    clientNonce = clientNonceBytes,
                    serverNonce = serverNonceBytes,
                    isClient = true
                )

                newSocket.soTimeout = 70000
                _statusMessage.value = "Подтвердите подключение на MacBook..."
                FrameCodec.writeEncryptedJsonFrame(
                    out,
                    cipher,
                    FrameType.AUTH_IDENTITY,
                    JSONObject().apply { put("deviceName", deviceName) }
                )

                val authResultFrame = FrameCodec.readDecryptedFrame(input, cipher)
                if (authResultFrame.type != FrameType.AUTH_RESULT) {
                    throw IOException("Неожиданный ответ подтверждения от MacBook")
                }
                val authResult = FrameCodec.parseAuthResult(authResultFrame.payload)
                if (!authResult.ok) {
                    throw IOException(authResult.error ?: "Подключение отклонено на MacBook")
                }

                newSocket.soTimeout = 0
                socket = newSocket
                outputStream = out
                sessionCipher = cipher
                connectedMacName = authResult.deviceName
                lastFrameReceivedMs = System.currentTimeMillis()
                _connectionState.value = ConnectionState.Connected(
                    macName = authResult.deviceName,
                    host = connectedHost,
                    port = payload.port
                )
                syncBackgroundService()
                _statusMessage.value = "Подключено к ${authResult.deviceName} (AES-256-GCM)"

                scope.launch {
                    runReaderLoop(input, newSocket, cipher)
                }
                startHeartbeat(newSocket)
            } catch (e: Exception) {
                disconnectInternal(notifyPeer = false)
                _errorMessage.value = formatConnectError(e, payload.host)
            }
        }
    }

    private fun sendEncryptedJson(type: FrameType, json: JSONObject): Boolean {
        val out = outputStream ?: return false
        val cipher = sessionCipher ?: return false
        return runCatching {
            FrameCodec.writeEncryptedJsonFrame(out, cipher, type, json)
        }.isSuccess
    }

    private fun hasSufficientStorageSpace(ctx: Context, requiredBytes: Long): Boolean {
        if (requiredBytes <= 0L) return true
        return runCatching {
            val probeDir = ctx.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: ctx.filesDir
            val available = StatFs(probeDir.path).availableBytes
            val needed = if (requiredBytes > Long.MAX_VALUE - DISK_FREE_MARGIN_BYTES) {
                Long.MAX_VALUE
            } else {
                requiredBytes + DISK_FREE_MARGIN_BYTES
            }
            available >= needed
        }.getOrDefault(true)
    }

    private fun startHeartbeat(expectedSocket: Socket) {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (isActive && socket === expectedSocket && !expectedSocket.isClosed) {
                delay(5000)
                if (socket !== expectedSocket || expectedSocket.isClosed) break
                if (_isTransferring.value || _incomingRequest.value != null) {
                    lastFrameReceivedMs = System.currentTimeMillis()
                    continue
                }
                val pingOk = sendEncryptedJson(FrameType.PING, JSONObject())
                if (!pingOk) {
                    if (socket === expectedSocket) {
                        disconnectInternal(notifyPeer = false)
                        _statusMessage.value = "Соединение с MacBook потеряно"
                    }
                    break
                }
                delay(4000)
                if (!_isTransferring.value &&
                    _incomingRequest.value == null &&
                    socket === expectedSocket &&
                    System.currentTimeMillis() - lastFrameReceivedMs > 15000
                ) {
                    disconnectInternal(notifyPeer = false)
                    _statusMessage.value = "MacBook не отвечает по Wi-Fi"
                    break
                }
            }
        }
    }

    private fun formatConnectError(e: Exception, host: String): String {
        val isRouteOrTimeout = e is NoRouteToHostException ||
            e is ConnectException ||
            e is SocketTimeoutException ||
            e.message?.contains("EHOSTUNREACH", ignoreCase = true) == true
        return if (isRouteOrTimeout) {
            "Нет маршрута к MacBook ($host). Проверьте:\n" +
                "1. Отключите VPN на MacBook и телефоне\n" +
                "2. Оба устройства в одной Wi-Fi сети (не гостевой и без «Изоляции клиентов» в роутере)\n" +
                "3. На MacBook разрешите Droply доступ к локальной сети"
        } else {
            e.message ?: "Не удалось подключиться по Wi-Fi"
        }
    }

    fun respondToIncomingBatch(accepted: Boolean) {
        scope.launch {
            val session = incomingSession ?: return@launch
            if (session.approved != null) return@launch
            session.approved = accepted
            _incomingRequest.value = null

            val reason = if (accepted) null else "Получение отклонено на смартфоне"
            sendEncryptedJson(
                FrameType.BATCH_ACCEPT,
                JSONObject().apply {
                    put("batchId", session.batch.batchId)
                    put("accepted", accepted)
                    if (reason != null) put("reason", reason)
                }
            )

            if (accepted) {
                _errorMessage.value = null
                _statusMessage.value = null
                _isTransferring.value = true
                syncBackgroundService()
                _progress.value = TransferProgressUi(
                    fileIndex = 0,
                    totalFiles = session.batch.totalFiles,
                    currentFileName = "Получение...",
                    bytesTransferred = 0L,
                    totalBytes = session.batch.totalBytes,
                    percent = 0.0,
                    speedBytesPerSecond = 0.0,
                    isIncoming = true
                )
            } else {
                session.cancelled = true
                session.cleanupActiveWriter()
                incomingSession = null
                _statusMessage.value = "Получение файлов отклонено"
            }
        }
    }

    private fun runReaderLoop(
        input: DataInputStream,
        expectedSocket: Socket,
        cipher: SecureChannel.SessionCipher
    ) {
        try {
            while (!expectedSocket.isClosed) {
                val frame = FrameCodec.readDecryptedFrame(input, cipher)
                lastFrameReceivedMs = System.currentTimeMillis()
                when (frame.type) {
                    FrameType.PING -> {
                        sendEncryptedJson(FrameType.PONG, JSONObject())
                    }

                    FrameType.PONG -> Unit

                    FrameType.BATCH_ACCEPT -> {
                        val accept = FrameCodec.parseBatchAccept(frame.payload)
                        batchAcceptDeferred?.complete(accept)
                    }

                    FrameType.PROGRESS_ACK -> {
                        val ack = FrameCodec.parseProgressAck(frame.payload)
                        confirmedBatchBytes = max(confirmedBatchBytes, ack.batchBytesReceived)
                        confirmedPercent = max(confirmedPercent, ack.percent.coerceIn(0.0, 100.0))
                        val elapsedSec = ((System.currentTimeMillis() - activeBatchStartMs).coerceAtLeast(1L)) / 1000.0
                        val speed = confirmedBatchBytes / elapsedSec
                        _progress.value = TransferProgressUi(
                            fileIndex = ack.fileIndex,
                            totalFiles = activeBatchTotalFiles,
                            currentFileName = activeCurrentFileName,
                            bytesTransferred = confirmedBatchBytes,
                            totalBytes = ack.totalBytes,
                            percent = confirmedPercent,
                            speedBytesPerSecond = speed,
                            isIncoming = false
                        )
                    }

                    FrameType.FILE_RESULT -> {
                        val res = FrameCodec.parseFileResult(frame.payload)
                        pendingFileResults.remove(res.fileIndex)?.complete(res)
                    }

                    FrameType.BATCH_START -> {
                        val batch = FrameCodec.parseBatchStart(frame.payload)
                        if (batch.totalFiles !in 1..MAX_BATCH_FILES || batch.totalBytes !in 0L..MAX_BATCH_BYTES) {
                            sendEncryptedJson(
                                FrameType.BATCH_ACCEPT,
                                JSONObject().apply {
                                    put("batchId", batch.batchId)
                                    put("accepted", false)
                                    put("reason", "Некорректные параметры передачи")
                                }
                            )
                            _errorMessage.value = "Отклонена передача с некорректным размером или количеством файлов"
                            continue
                        }

                        val hasSpace = appContext?.let { hasSufficientStorageSpace(it, batch.totalBytes) } ?: true
                        if (!hasSpace) {
                            sendEncryptedJson(
                                FrameType.BATCH_ACCEPT,
                                JSONObject().apply {
                                    put("batchId", batch.batchId)
                                    put("accepted", false)
                                    put("reason", "Недостаточно места на смартфоне")
                                }
                            )
                            _errorMessage.value = "Недостаточно свободного места для приёма файлов"
                            continue
                        }

                        incomingSession?.cleanupActiveWriter()
                        val session = IncomingReceiveSession(batch = batch)
                        incomingSession = session
                        val safePreview = batch.previewName
                            ?.let { SecureChannel.sanitizeDisplayText(it, maxLength = 120) }
                            ?.takeIf { it.isNotEmpty() }

                        if (_requireIncomingConfirmation.value) {
                            _incomingRequest.value = IncomingBatchRequestUi(
                                batchId = batch.batchId,
                                senderName = connectedMacName,
                                totalFiles = batch.totalFiles,
                                totalBytes = batch.totalBytes,
                                previewName = safePreview
                            )
                        } else {
                            session.approved = true
                            _incomingRequest.value = null
                            sendEncryptedJson(
                                FrameType.BATCH_ACCEPT,
                                JSONObject().apply {
                                    put("batchId", batch.batchId)
                                    put("accepted", true)
                                }
                            )
                            _errorMessage.value = null
                            _statusMessage.value = null
                            _isTransferring.value = true
                            syncBackgroundService()
                            _progress.value = TransferProgressUi(
                                fileIndex = 0,
                                totalFiles = batch.totalFiles,
                                currentFileName = "Получение...",
                                bytesTransferred = 0L,
                                totalBytes = batch.totalBytes,
                                percent = 0.0,
                                speedBytesPerSecond = 0.0,
                                isIncoming = true
                            )
                        }
                    }

                    FrameType.FILE_START -> {
                        val session = incomingSession ?: continue
                        if (session.cancelled || session.approved != true) continue
                        val ctx = appContext ?: continue

                        session.cleanupActiveWriter()
                        val fileStart = FrameCodec.parseFileStart(frame.payload)
                        if (session.completedCount >= session.batch.totalFiles ||
                            fileStart.size < 0L ||
                            session.batchBytesReceived > session.batch.totalBytes ||
                            fileStart.size > (session.batch.totalBytes - session.batchBytesReceived)
                        ) {
                            session.cancelled = true
                            val errMsg = "Превышен заявленный размер или количество файлов"
                            sendFileResult(fileStart.fileIndex, ok = false, savedPath = null, error = errMsg)
                            _errorMessage.value = errMsg
                            continue
                        }

                        val writer = try {
                            AndroidFileSaver.openWriter(ctx, fileStart.relativePath)
                        } catch (e: IOException) {
                            session.cancelled = true
                            val errMsg = e.message ?: "Небезопасный путь сохранения файла"
                            sendFileResult(fileStart.fileIndex, ok = false, savedPath = null, error = errMsg)
                            _errorMessage.value = errMsg
                            continue
                        }

                        session.currentFile = fileStart
                        session.currentWriter = writer
                        session.currentHasher = MessageDigest.getInstance("SHA-256")
                        session.currentFileBytes = 0L
                        session.textBuffer = if (fileStart.isText && fileStart.size <= 512 * 1024) {
                            ArrayList(fileStart.size.toInt().coerceAtLeast(0))
                        } else {
                            null
                        }
                        emitIncomingProgress(session, forceAck = true)
                    }

                    FrameType.FILE_CHUNK -> {
                        val session = incomingSession ?: continue
                        if (session.cancelled || session.approved != true) continue
                        val fileStart = session.currentFile ?: continue
                        val writer = session.currentWriter ?: continue
                        val chunkLen = frame.payload.size.toLong()
                        if (chunkLen > 0L) {
                            if (session.currentFileBytes > fileStart.size ||
                                chunkLen > (fileStart.size - session.currentFileBytes) ||
                                session.batchBytesReceived > session.batch.totalBytes ||
                                chunkLen > (session.batch.totalBytes - session.batchBytesReceived)
                            ) {
                                writer.abort()
                                session.cancelled = true
                                session.currentWriter = null
                                session.currentFile = null
                                val errMsg = "Превышен заявленный размер файла ${fileStart.relativePath}"
                                sendFileResult(fileStart.fileIndex, ok = false, savedPath = null, error = errMsg)
                                _errorMessage.value = errMsg
                                continue
                            }

                            writer.outputStream.write(frame.payload)
                            session.currentHasher?.update(frame.payload)
                            session.textBuffer?.let { buf ->
                                if (buf.size + frame.payload.size <= 512 * 1024) {
                                    for (b in frame.payload) buf.add(b)
                                } else {
                                    session.textBuffer = null
                                }
                            }
                            session.currentFileBytes += chunkLen
                            session.batchBytesReceived += chunkLen
                        }
                        emitIncomingProgress(session, forceAck = false)
                    }

                    FrameType.FILE_END -> {
                        val session = incomingSession ?: continue
                        if (session.cancelled || session.approved != true) continue
                        val fileStart = session.currentFile ?: continue
                        val writer = session.currentWriter ?: continue
                        val expectedSha = JSONObject(String(frame.payload, Charsets.UTF_8))
                            .optString("sha256", "")
                            .trim()
                            .lowercase()
                        val computedSha = session.currentHasher?.digest()?.joinToString("") { "%02x".format(it) }.orEmpty()

                        if (session.currentFileBytes != fileStart.size ||
                            expectedSha.length != 64 ||
                            computedSha != expectedSha
                        ) {
                            writer.abort()
                            session.currentWriter = null
                            session.currentFile = null
                            sendFileResult(fileStart.fileIndex, ok = false, savedPath = null, error = "Ошибка целостности ${fileStart.relativePath}")
                        } else {
                            val saved = writer.commit()
                            session.completedCount += 1
                            emitIncomingProgress(session, forceAck = true)
                            sendFileResult(fileStart.fileIndex, ok = true, savedPath = saved.displayPath, error = null)

                            val textContent = session.textBuffer?.toByteArray()?.let { String(it, Charsets.UTF_8) }
                            _history.value = listOf(
                                SentFileRecord(
                                    relativePath = fileStart.relativePath,
                                    sizeBytes = session.currentFileBytes,
                                    isText = fileStart.isText,
                                    ok = true,
                                    isIncoming = true,
                                    savedUri = saved.contentUri,
                                    textContent = textContent
                                )
                            ) + _history.value
                            saveHistoryAsync()

                            session.currentWriter = null
                            session.currentFile = null
                            session.textBuffer = null
                        }
                    }

                    FrameType.BATCH_END -> {
                        val session = incomingSession
                        incomingSession = null
                        if (session != null && !session.cancelled && session.approved == true) {
                            session.cleanupActiveWriter()
                            _isTransferring.value = false
                            _progress.value = null
                            _statusMessage.value = "Получено файлов с MacBook: ${session.completedCount}"
                        }
                    }

                    FrameType.CANCEL -> {
                        val obj = runCatching { JSONObject(String(frame.payload, Charsets.UTF_8)) }.getOrNull()
                        val target = obj?.optString("target", "any") ?: "any"
                        val msg = obj?.optString("reason")
                            ?.let { SecureChannel.sanitizeDisplayText(it, maxLength = 120) }
                            ?.takeIf { it.isNotEmpty() }
                            ?: "Передача отменена"

                        if (target == "outgoing" || target == "any") {
                            outgoingCancelRequested.set(true)
                            outgoingCancelSent.set(true)
                            batchAcceptDeferred?.complete(BatchAccept("", accepted = false, reason = msg))
                            failAllPendingResults(msg)
                        }
                        if (target == "incoming" || target == "any") {
                            incomingSession?.let {
                                it.cancelled = true
                                it.cleanupActiveWriter()
                                incomingSession = null
                            }
                            _incomingRequest.value = null
                        }

                        _isTransferring.value = false
                        _progress.value = null
                        _statusMessage.value = msg
                    }

                    FrameType.DISCONNECT -> {
                        if (socket === expectedSocket) {
                            failAllPendingResults("MacBook завершил сессию")
                            disconnectInternal(notifyPeer = false)
                            _statusMessage.value = "MacBook завершил сессию"
                        }
                        return
                    }

                    else -> throw IOException("Недопустимый пакет после авторизации")
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (socket === expectedSocket) {
                failAllPendingResults("Соединение разорвано")
                disconnectInternal(notifyPeer = false)
                _statusMessage.value = if (e is IOException) "Соединение с MacBook разорвано" else "Некорректный пакет от MacBook"
            }
        }
    }

    private fun emitIncomingProgress(session: IncomingReceiveSession, forceAck: Boolean) {
        val fileStart = session.currentFile ?: return
        val now = System.currentTimeMillis()
        val delta = session.batchBytesReceived - session.lastAckBytes
        if (!forceAck && delta < 512 * 1024 && (now - session.lastAckMs) < 80) return
        session.lastAckMs = now
        session.lastAckBytes = session.batchBytesReceived

        val elapsedSec = ((now - session.startMs).coerceAtLeast(1L)) / 1000.0
        val speed = session.batchBytesReceived / elapsedSec
        val pct = if (session.batch.totalBytes == 0L) {
            if (session.batch.totalFiles > 0) session.completedCount * 100.0 / session.batch.totalFiles else 100.0
        } else {
            min(100.0, session.batchBytesReceived * 100.0 / session.batch.totalBytes)
        }

        _progress.value = TransferProgressUi(
            fileIndex = fileStart.fileIndex,
            totalFiles = session.batch.totalFiles,
            currentFileName = fileStart.relativePath.substringAfterLast('/'),
            bytesTransferred = session.batchBytesReceived,
            totalBytes = session.batch.totalBytes,
            percent = pct,
            speedBytesPerSecond = speed,
            isIncoming = true
        )

        sendEncryptedJson(
            FrameType.PROGRESS_ACK,
            JSONObject().apply {
                put("fileIndex", fileStart.fileIndex)
                put("fileBytesReceived", session.currentFileBytes)
                put("batchBytesReceived", session.batchBytesReceived)
                put("totalBytes", session.batch.totalBytes)
                put("percent", pct)
            }
        )
    }

    private fun sendFileResult(fileIndex: Int, ok: Boolean, savedPath: String?, error: String?) {
        sendEncryptedJson(
            FrameType.FILE_RESULT,
            JSONObject().apply {
                put("fileIndex", fileIndex)
                put("ok", ok)
                if (savedPath != null) put("savedPath", savedPath)
                if (error != null) put("error", error)
            }
        )
    }

    fun cancelTransfer(reason: String = "Передача отменена пользователем") {
        if (!_isTransferring.value) return
        val incoming = incomingSession
        if (incoming != null) {
            incoming.cancelled = true
            incoming.cleanupActiveWriter()
            incomingSession = null
            _isTransferring.value = false
            _progress.value = null
            _statusMessage.value = reason
            scope.launch {
                sendEncryptedJson(
                    FrameType.CANCEL,
                    JSONObject().apply {
                        put("reason", reason)
                        put("target", "outgoing")
                    }
                )
            }
            return
        }

        outgoingCancelRequested.set(true)
        batchAcceptDeferred?.complete(BatchAccept("", accepted = false, reason = reason))
        scope.launch {
            sendOutgoingCancelOnce(reason)
        }
    }

    private fun sendOutgoingCancelOnce(reason: String) {
        if (!outgoingCancelSent.compareAndSet(false, true)) return
        sendEncryptedJson(
            FrameType.CANCEL,
            JSONObject().apply {
                put("reason", reason)
                put("target", "incoming")
            }
        )
    }

    fun disconnect() {
        scope.launch {
            connectionMutex.withLock {
                disconnectInternal(notifyPeer = true)
                _statusMessage.value = "Отключено от MacBook"
            }
        }
    }

    fun shutdown() {
        disconnectInternal(notifyPeer = true)
        scope.cancel()
    }

    private fun disconnectInternal(notifyPeer: Boolean) {
        heartbeatJob?.cancel()
        heartbeatJob = null
        outgoingCancelRequested.set(true)
        batchAcceptDeferred?.complete(BatchAccept("", accepted = false, reason = "Соединение закрыто"))
        batchAcceptDeferred = null
        failAllPendingResults("Соединение закрыто")

        incomingSession?.cleanupActiveWriter()
        incomingSession = null
        _incomingRequest.value = null

        val out = outputStream
        val cipher = sessionCipher
        val sock = socket
        outputStream = null
        sessionCipher = null
        socket = null
        if (notifyPeer && out != null && cipher != null) {
            runCatching {
                FrameCodec.writeEncryptedJsonFrame(out, cipher, FrameType.DISCONNECT, JSONObject())
            }
        }
        runCatching { sock?.close() }
        _isTransferring.value = false
        _progress.value = null
        _connectionState.value = ConnectionState.Disconnected
    }

    suspend fun sendItems(context: Context, items: List<TransferItem>) = withContext(Dispatchers.IO) {
        if (items.isEmpty()) return@withContext
        if (!transferMutex.tryLock()) {
            _errorMessage.value = "Дождитесь завершения текущей передачи"
            return@withContext
        }

        try {
            val out = outputStream
            val cipher = sessionCipher
            if (out == null || cipher == null || socket?.isClosed != false) {
                _errorMessage.value = "Сначала отсканируйте QR-код на MacBook"
                return@withContext
            }

            outgoingCancelRequested.set(false)
            outgoingCancelSent.set(false)
            pendingFileResults.clear()
            confirmedBatchBytes = 0L
            confirmedPercent = 0.0
            _errorMessage.value = null
            _statusMessage.value = "Ожидание подтверждения на MacBook..."

            val totalBytes = items.sumOf { it.sizeBytes.coerceAtLeast(0L) }
            val batchId = UUID.randomUUID().toString()
            activeBatchStartMs = System.currentTimeMillis()
            activeBatchTotalFiles = items.size
            activeBatchTotalBytes = totalBytes
            activeCurrentFileName = items.first().relativePath.substringAfterLast('/')

            val acceptWaiter = CompletableDeferred<BatchAccept>()
            batchAcceptDeferred = acceptWaiter

            val previewName = if (items.size == 1) items[0].relativePath else null
            FrameCodec.writeEncryptedJsonFrame(
                out,
                cipher,
                FrameType.BATCH_START,
                JSONObject().apply {
                    put("batchId", batchId)
                    put("totalFiles", items.size)
                    put("totalBytes", totalBytes)
                    if (previewName != null) put("previewName", previewName)
                }
            )

            val acceptResponse = acceptWaiter.await()
            batchAcceptDeferred = null

            if (!acceptResponse.accepted) {
                _statusMessage.value = acceptResponse.reason ?: "MacBook отклонил получение"
                return@withContext
            }

            _statusMessage.value = null
            _isTransferring.value = true
            syncBackgroundService()
            _progress.value = TransferProgressUi(
                fileIndex = 0,
                totalFiles = items.size,
                currentFileName = activeCurrentFileName,
                bytesTransferred = 0L,
                totalBytes = totalBytes,
                percent = 0.0,
                speedBytesPerSecond = 0.0,
                isIncoming = false
            )

            var sentBatchBytes = 0L
            var completedCount = 0
            val buffer = ByteArray(DroplyProtocol.CHUNK_SIZE)
            var lastUiUpdateMs = 0L

            for ((index, item) in items.withIndex()) {
                if (outgoingCancelRequested.get()) break

                activeCurrentFileName = item.relativePath.substringAfterLast('/')
                val resultDeferred = CompletableDeferred<FileResult>()
                pendingFileResults[index] = resultDeferred

                FrameCodec.writeEncryptedJsonFrame(
                    out,
                    cipher,
                    FrameType.FILE_START,
                    JSONObject().apply {
                        put("fileIndex", index)
                        put("relativePath", item.relativePath)
                        put("size", item.sizeBytes)
                        put("isText", item.isText)
                    }
                )

                val digest = MessageDigest.getInstance("SHA-256")
                openItemStream(context, item).use { stream ->
                    while (!outgoingCancelRequested.get()) {
                        val read = stream.read(buffer)
                        if (read <= 0) break
                        digest.update(buffer, 0, read)
                        FrameCodec.writeEncryptedFrame(out, cipher, FrameType.FILE_CHUNK, buffer, read)
                        sentBatchBytes += read

                        val now = System.currentTimeMillis()
                        if (now - lastUiUpdateMs >= 80 && confirmedPercent == 0.0) {
                            lastUiUpdateMs = now
                            val elapsedSec = ((now - activeBatchStartMs).coerceAtLeast(1L)) / 1000.0
                            val pct = if (totalBytes == 0L) 0.0 else min(99.9, sentBatchBytes * 100.0 / totalBytes)
                            _progress.value = TransferProgressUi(
                                fileIndex = index,
                                totalFiles = items.size,
                                currentFileName = activeCurrentFileName,
                                bytesTransferred = max(confirmedBatchBytes, sentBatchBytes),
                                totalBytes = totalBytes,
                                percent = pct,
                                speedBytesPerSecond = sentBatchBytes / elapsedSec,
                                isIncoming = false
                            )
                        }
                    }
                }

                if (outgoingCancelRequested.get()) {
                    pendingFileResults.remove(index)
                    break
                }

                val shaHex = digest.digest().joinToString("") { "%02x".format(it) }
                FrameCodec.writeEncryptedJsonFrame(
                    out,
                    cipher,
                    FrameType.FILE_END,
                    JSONObject().apply { put("sha256", shaHex) }
                )

                val fileResult = resultDeferred.await()
                if (!outgoingCancelRequested.get()) {
                    val textBody = (item as? TransferItem.TextNoteItem)?.let {
                        if (it.bytes.size <= 512 * 1024) String(it.bytes, Charsets.UTF_8) else null
                    }
                    _history.value = listOf(
                        SentFileRecord(
                            relativePath = item.relativePath,
                            sizeBytes = item.sizeBytes,
                            isText = item.isText,
                            ok = fileResult.ok,
                            isIncoming = false,
                            savedUri = (item as? TransferItem.UriItem)?.uri,
                            textContent = textBody,
                            errorMessage = fileResult.error
                        )
                    ) + _history.value
                    saveHistoryAsync()

                    if (fileResult.ok) {
                        completedCount += 1
                    } else {
                        _errorMessage.value = fileResult.error ?: "Ошибка проверки файла ${item.relativePath}"
                    }
                }
            }

            if (outgoingCancelRequested.get()) {
                sendOutgoingCancelOnce("Передача отменена")
                if (_statusMessage.value.isNullOrBlank()) {
                    _statusMessage.value = "Передача отменена"
                }
            } else {
                FrameCodec.writeEncryptedJsonFrame(
                    out,
                    cipher,
                    FrameType.BATCH_END,
                    JSONObject().apply { put("batchId", batchId) }
                )
                _statusMessage.value = "Отправлено на MacBook: $completedCount из ${items.size}"
            }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            if (!outgoingCancelRequested.get()) {
                val msg = e.message ?: "Ошибка передачи по Wi-Fi"
                sendOutgoingCancelOnce(msg)
                _errorMessage.value = msg
            }
        } finally {
            batchAcceptDeferred = null
            _isTransferring.value = false
            _progress.value = null
            pendingFileResults.clear()
            transferMutex.unlock()
        }
    }

    private fun openItemStream(context: Context, item: TransferItem): InputStream {
        return when (item) {
            is TransferItem.UriItem -> context.contentResolver.openInputStream(item.uri)
                ?: throw IOException("Не удалось открыть файл ${item.relativePath}")
            is TransferItem.TextNoteItem -> ByteArrayInputStream(item.bytes)
        }
    }

    private fun failAllPendingResults(reason: String) {
        pendingFileResults.forEach { (idx, deferred) ->
            deferred.complete(FileResult(fileIndex = idx, ok = false, savedPath = null, error = reason))
        }
        pendingFileResults.clear()
    }

    fun currentAppVersion(context: Context): String {
        return AppUpdateChecker.displayVersionLabel(AppUpdateChecker.currentAppVersion(context))
    }

    fun checkForUpdates(context: Context, userInitiated: Boolean = false) {
        val ctx = context.applicationContext
        if (!AppUpdateChecker.isConfigured()) {
            if (userInitiated) {
                _errorMessage.value = null
                _statusMessage.value = "Ссылка на GitHub ещё не настроена (версия ${currentAppVersion(ctx)})"
            }
            return
        }

        val now = System.currentTimeMillis()
        if (!userInitiated && (now - lastUpdateCheckMs) < 30L * 60L * 1000L) {
            return
        }
        if (_isCheckingForUpdates.value) return
        _isCheckingForUpdates.value = true

        scope.launch {
            val outcome = runCatching {
                AppUpdateChecker.checkForUpdatesOutcome(
                    repositoryUrl = AppUpdateConfig.GITHUB_REPOSITORY_URL,
                    currentVersion = AppUpdateChecker.currentAppVersion(ctx)
                )
            }.getOrDefault(com.droply.android.update.UpdateCheckOutcome.NetworkFailed)

            _isCheckingForUpdates.value = false
            when (outcome) {
                is com.droply.android.update.UpdateCheckOutcome.Available -> {
                    lastUpdateCheckMs = System.currentTimeMillis()
                    val info = outcome.info
                    _availableUpdate.value = info
                    val signature = info.promptSignature
                    if (userInitiated || lastPromptedUpdateVersion != signature) {
                        lastPromptedUpdateVersion = signature
                        _showUpdatePrompt.value = true
                        postUpdateSystemNotification(ctx, info)
                    }
                }
                com.droply.android.update.UpdateCheckOutcome.UpToDate -> {
                    lastUpdateCheckMs = System.currentTimeMillis()
                    _availableUpdate.value = null
                    if (userInitiated) {
                        _errorMessage.value = null
                        _statusMessage.value = "У вас установлена актуальная версия (${currentAppVersion(ctx)})"
                    }
                }
                com.droply.android.update.UpdateCheckOutcome.NotConfigured -> {
                    if (userInitiated) {
                        _errorMessage.value = null
                        _statusMessage.value = "Ссылка на GitHub ещё не настроена (версия ${currentAppVersion(ctx)})"
                    }
                }
                com.droply.android.update.UpdateCheckOutcome.NetworkFailed -> {
                    if (userInitiated) {
                        _errorMessage.value = "Не удалось связаться с GitHub для проверки обновлений"
                    }
                }
            }
        }
    }

    fun presentUpdatePrompt() {
        if (_availableUpdate.value != null) {
            _showUpdatePrompt.value = true
        }
    }

    fun dismissUpdatePrompt() {
        _showUpdatePrompt.value = false
    }

    fun openUpdateOnGitHub(context: Context) {
        val info = _availableUpdate.value ?: return
        val intent = AppUpdateChecker.buildOpenGitHubIntent(info.releaseUrl)
        if (intent == null) {
            _errorMessage.value = "Недопустимая ссылка на обновление"
            return
        }
        val launched = runCatching { context.startActivity(intent) }.isSuccess
        if (!launched) {
            _errorMessage.value = "Не удалось открыть браузер для перехода на GitHub"
        }
        _showUpdatePrompt.value = false
    }

    private fun postUpdateSystemNotification(ctx: Context, info: AppUpdateInfo) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val githubIntent = AppUpdateChecker.buildOpenGitHubIntent(info.releaseUrl) ?: return
        val pendingIntent = PendingIntent.getActivity(
            ctx,
            4091,
            githubIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        runCatching {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    "droply_updates",
                    "Обновления приложения",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Уведомления о выходе новой версии Droply на GitHub"
                }
                nm.createNotificationChannel(channel)
            }

            val notifTitle = info.title ?: "Доступна новая версия Droply (${info.latestVersion})"
            val notifBody = info.releaseNotes
                ?: "Версия ${info.latestVersion} — нажмите «Установить», чтобы перейти на GitHub."
            val notification = NotificationCompat.Builder(ctx, "droply_updates")
                .setSmallIcon(R.drawable.ic_stat_droply)
                .setContentTitle(notifTitle)
                .setContentText(notifBody)
                .setStyle(NotificationCompat.BigTextStyle().bigText(notifBody))
                .setContentIntent(pendingIntent)
                .addAction(0, "Установить", pendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build()

            nm.notify(4091, notification)
        }
    }
}
