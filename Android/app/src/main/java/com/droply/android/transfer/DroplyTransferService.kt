package com.droply.android.transfer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.droply.android.DroplyApplication
import com.droply.android.MainActivity
import com.droply.android.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Keeps Droply TCP connection and active transfers alive when the app is minimized
 * or the screen is turned off, holding CPU & Wi-Fi locks strictly while transferring.
 */
class DroplyTransferService : Service() {

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var observerJob: Job? = null
    private var progressObserverJob: Job? = null

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private var lastNotificationUpdateMs: Long = 0L
    private var lastPercentInt: Int = -1
    private var lastFileIndex: Int = -1
    private var lastIncomingBatchId: String? = null

    private val client: DroplyClient
        get() = (application as DroplyApplication).client

    private val notificationManager: NotificationManager by lazy {
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning.set(true)
        ensureNotificationChannels()
        startObservingClient()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureNotificationChannels()
        // Always enter foreground synchronously to satisfy Android 8+ / 14+ foreground rules.
        startForegroundCompat(buildStatusNotification())

        when (intent?.action) {
            ACTION_CANCEL_TRANSFER -> client.cancelTransfer()
            ACTION_DISCONNECT -> {
                client.disconnect()
                stopSelfCleanly()
                return START_NOT_STICKY
            }
            ACTION_ACCEPT_INCOMING -> {
                notificationManager.cancel(NOTIFICATION_ID_INCOMING)
                client.respondToIncomingBatch(true)
            }
            ACTION_REJECT_INCOMING -> {
                notificationManager.cancel(NOTIFICATION_ID_INCOMING)
                client.respondToIncomingBatch(false)
            }
        }

        if (!client.shouldKeepServiceRunning()) {
            stopSelfCleanly()
            return START_NOT_STICKY
        }

        updateLocks(activeTransferOrPrompt = client.isTransferring.value || client.incomingRequest.value != null)
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelfCleanly()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // If user swipes the app away from Recents while idle, disconnect & stop cleanly.
        // If a transfer is actively running, keep the service alive until it completes.
        if (!client.isTransferring.value) {
            client.disconnect()
            stopSelfCleanly()
        }
    }

    override fun onDestroy() {
        isRunning.set(false)
        observerJob?.cancel()
        progressObserverJob?.cancel()
        releaseLocks()
        notificationManager.cancel(NOTIFICATION_ID_INCOMING)
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun startObservingClient() {
        observerJob?.cancel()
        observerJob = serviceScope.launch {
            combine(
                client.connectionState,
                client.isTransferring,
                client.incomingRequest,
                client.statusMessage
            ) { conn, transferring, incoming, status ->
                ServiceSnapshot(conn, transferring, incoming, status)
            }.collectLatest { snap ->
                val needsWakeLock = snap.isTransferring || snap.incoming != null
                updateLocks(activeTransferOrPrompt = needsWakeLock)

                if (snap.incoming != null) {
                    if (lastIncomingBatchId != snap.incoming.batchId) {
                        lastIncomingBatchId = snap.incoming.batchId
                        notificationManager.notify(
                            NOTIFICATION_ID_INCOMING,
                            buildIncomingRequestNotification(snap.incoming)
                        )
                    }
                } else {
                    lastIncomingBatchId = null
                    notificationManager.cancel(NOTIFICATION_ID_INCOMING)
                }

                if (!client.shouldKeepServiceRunning()) {
                    stopSelfCleanly()
                    return@collectLatest
                }

                if (!snap.isTransferring) {
                    lastNotificationUpdateMs = 0L
                    lastPercentInt = -1
                    lastFileIndex = -1
                    notificationManager.notify(NOTIFICATION_ID_STATUS, buildStatusNotification())
                }
            }
        }

        progressObserverJob?.cancel()
        progressObserverJob = serviceScope.launch {
            client.progress.collectLatest { progress ->
                if (progress == null || !client.shouldKeepServiceRunning()) return@collectLatest
                val now = System.currentTimeMillis()
                val pctInt = progress.percent.toInt().coerceIn(0, 100)
                val shouldUpdate = lastNotificationUpdateMs == 0L ||
                    progress.fileIndex != lastFileIndex ||
                    pctInt != lastPercentInt && (now - lastNotificationUpdateMs >= 350L) ||
                    (now - lastNotificationUpdateMs >= 750L)
                if (!shouldUpdate) return@collectLatest

                lastNotificationUpdateMs = now
                lastPercentInt = pctInt
                lastFileIndex = progress.fileIndex
                notificationManager.notify(NOTIFICATION_ID_STATUS, buildProgressNotification(progress))
            }
        }
    }

    private fun updateLocks(activeTransferOrPrompt: Boolean) {
        if (activeTransferOrPrompt) {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
                wakeLock = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Droply:TransferWakeLock")?.apply {
                    setReferenceCounted(false)
                }
            }
            if (wakeLock?.isHeld == false) {
                runCatching { wakeLock?.acquire(MAX_LOCK_TIMEOUT_MS) }
            }

            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                val lockMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm?.createWifiLock(lockMode, "Droply:TransferWifiLock")?.apply {
                    setReferenceCounted(false)
                }
            }
            if (wifiLock?.isHeld == false) {
                runCatching { wifiLock?.acquire() }
            }
        } else {
            releaseLocks()
        }
    }

    private fun releaseLocks() {
        runCatching {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        }
        runCatching {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        }
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID_STATUS,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID_STATUS, notification)
        }
    }

    private fun stopSelfCleanly() {
        releaseLocks()
        notificationManager.cancel(NOTIFICATION_ID_INCOMING)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun ensureNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val statusChannel = NotificationChannel(
            CHANNEL_ID_STATUS,
            "Передача файлов в фоне",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Отображает состояние подключения и прогресс передачи файлов при свернутом приложении"
            setShowBadge(false)
        }
        val incomingChannel = NotificationChannel(
            CHANNEL_ID_INCOMING,
            "Входящие файлы с MacBook",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Запросы на подтверждение приема файлов от MacBook в фоне"
        }
        notificationManager.createNotificationChannel(statusChannel)
        notificationManager.createNotificationChannel(incomingChannel)
    }

    private fun openAppPendingIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            this,
            REQ_OPEN_APP,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun serviceActionPendingIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, DroplyTransferService::class.java).apply {
            this.action = action
        }
        return PendingIntent.getService(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun buildStatusNotification(): Notification {
        val activeProgress = client.progress.value
        if (client.isTransferring.value && activeProgress != null) {
            return buildProgressNotification(activeProgress)
        }

        val conn = client.connectionState.value
        val title = when (conn) {
            is ConnectionState.Connected -> "Подключено к ${conn.macName}"
            is ConnectionState.Connecting -> "Подключение по Wi-Fi..."
            is ConnectionState.Disconnected -> "Droply"
        }
        val statusMsg = client.statusMessage.value
        val text = if (!statusMsg.isNullOrBlank() &&
            (statusMsg.startsWith("Отправлено") || statusMsg.startsWith("Получено"))
        ) {
            statusMsg
        } else {
            "Передача и связь активны при свернутом приложении"
        }

        return NotificationCompat.Builder(this, CHANNEL_ID_STATUS)
            .setSmallIcon(R.drawable.ic_stat_droply)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openAppPendingIntent())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .addAction(
                0,
                "Отключиться",
                serviceActionPendingIntent(ACTION_DISCONNECT, REQ_DISCONNECT)
            )
            .build()
    }

    private fun buildProgressNotification(progress: TransferProgressUi): Notification {
        val direction = if (progress.isIncoming) "Получение с MacBook" else "Отправка на MacBook"
        val pctString = String.format(Locale.getDefault(), "%.0f%%", progress.percent)
        val detail = "${progress.currentFileName} • " +
            "${FileTreeCollector.formatBytes(progress.bytesTransferred)} / " +
            "${FileTreeCollector.formatBytes(progress.totalBytes)} • " +
            FileTreeCollector.formatSpeed(progress.speedBytesPerSecond)

        return NotificationCompat.Builder(this, CHANNEL_ID_STATUS)
            .setSmallIcon(R.drawable.ic_stat_droply)
            .setContentTitle("$direction • $pctString")
            .setContentText(detail)
            .setSubText("Файл ${progress.fileIndex + 1} из ${maxOf(progress.totalFiles, 1)}")
            .setContentIntent(openAppPendingIntent())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setProgress(1000, (progress.percent * 10.0).toInt().coerceIn(0, 1000), progress.totalBytes <= 0L)
            .addAction(
                0,
                "Отменить",
                serviceActionPendingIntent(ACTION_CANCEL_TRANSFER, REQ_CANCEL)
            )
            .build()
    }

    private fun buildIncomingRequestNotification(request: IncomingBatchRequestUi): Notification {
        val desc = if (request.totalFiles == 1 && !request.previewName.isNullOrBlank()) {
            val shortName = request.previewName.substringAfterLast('/')
            "«$shortName» (${FileTreeCollector.formatBytes(request.totalBytes)})"
        } else {
            "${request.totalFiles} шт. (${FileTreeCollector.formatBytes(request.totalBytes)})"
        }

        return NotificationCompat.Builder(this, CHANNEL_ID_INCOMING)
            .setSmallIcon(R.drawable.ic_stat_droply)
            .setContentTitle("Файлы от ${request.senderName}")
            .setContentText("Принять $desc?")
            .setContentIntent(openAppPendingIntent())
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(false)
            .setOngoing(true)
            .addAction(
                0,
                "Принять",
                serviceActionPendingIntent(ACTION_ACCEPT_INCOMING, REQ_ACCEPT)
            )
            .addAction(
                0,
                "Отклонить",
                serviceActionPendingIntent(ACTION_REJECT_INCOMING, REQ_REJECT)
            )
            .build()
    }

    private data class ServiceSnapshot(
        val connectionState: ConnectionState,
        val isTransferring: Boolean,
        val incoming: IncomingBatchRequestUi?,
        val statusMessage: String?
    )

    companion object {
        private const val CHANNEL_ID_STATUS = "droply_transfer"
        private const val CHANNEL_ID_INCOMING = "droply_incoming"
        private const val NOTIFICATION_ID_STATUS = 1001
        private const val NOTIFICATION_ID_INCOMING = 1002

        private const val REQ_OPEN_APP = 100
        private const val REQ_CANCEL = 101
        private const val REQ_DISCONNECT = 102
        private const val REQ_ACCEPT = 103
        private const val REQ_REJECT = 104

        private const val MAX_LOCK_TIMEOUT_MS = 4 * 60 * 60 * 1000L

        const val ACTION_SYNC = "com.droply.android.action.SYNC"
        const val ACTION_CANCEL_TRANSFER = "com.droply.android.action.CANCEL_TRANSFER"
        const val ACTION_DISCONNECT = "com.droply.android.action.DISCONNECT"
        const val ACTION_ACCEPT_INCOMING = "com.droply.android.action.ACCEPT_INCOMING"
        const val ACTION_REJECT_INCOMING = "com.droply.android.action.REJECT_INCOMING"

        val isRunning = AtomicBoolean(false)

        fun start(context: Context) {
            val intent = Intent(context, DroplyTransferService::class.java).apply {
                action = ACTION_SYNC
            }
            runCatching {
                ContextCompat.startForegroundService(context, intent)
            }
        }
    }
}
