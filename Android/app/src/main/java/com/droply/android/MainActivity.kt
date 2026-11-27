package com.droply.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color as AndroidColor
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.shape.GenericShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import android.widget.Toast
import androidx.lifecycle.viewmodel.compose.viewModel
import com.droply.android.transfer.AndroidFileSaver
import com.droply.android.transfer.ConnectionState
import com.droply.android.transfer.FileTreeCollector
import com.droply.android.transfer.SentFileRecord
import com.droply.android.transfer.TransferItem
import com.droply.android.ui.DroplyScreen
import com.droply.android.ui.DroplyTheme
import com.droply.android.ui.PendingConfirmationUi
import com.droply.android.ui.QRScannerOverlay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.hypot

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            val appViewModel: DroplyAndroidViewModel = viewModel()
            val client = appViewModel.client

            val systemDark = isSystemInDarkTheme()
            val context = LocalContext.current
            val appCtx = context.applicationContext
            var isDarkTheme by rememberSaveable {
                mutableStateOf(client.getPersistedDarkTheme(appCtx, systemDark))
            }
            var showScanner by rememberSaveable { mutableStateOf(false) }
            var showSettings by rememberSaveable { mutableStateOf(false) }
            var pendingConfirmation by remember { mutableStateOf<PendingConfirmationUi?>(null) }
            var previewPhotoRecord by remember { mutableStateOf<SentFileRecord?>(null) }
            var themeButtonOrigin by remember { mutableStateOf<Offset?>(null) }
            var themeRevealActive by remember { mutableStateOf(false) }
            var themeRevealOrigin by remember { mutableStateOf(Offset.Zero) }
            val themeRevealProgress = remember { Animatable(0f) }

            val view = LocalView.current
            val scope = rememberCoroutineScope()

            val connectionState by client.connectionState.collectAsState()
            val isTransferring by client.isTransferring.collectAsState()
            var requestedNotificationPermission by rememberSaveable { mutableStateOf(false) }

            val notificationPermissionLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission()
            ) { _ -> }

            fun requestNotificationPermissionIfNeeded() {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    !requestedNotificationPermission &&
                    ContextCompat.checkSelfPermission(
                        context,
                        Manifest.permission.POST_NOTIFICATIONS
                    ) != PackageManager.PERMISSION_GRANTED
                ) {
                    requestedNotificationPermission = true
                    notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
            }

            BackHandler(enabled = showScanner) {
                showScanner = false
            }

            BackHandler(enabled = !showScanner && previewPhotoRecord != null) {
                previewPhotoRecord = null
            }

            BackHandler(enabled = !showScanner && previewPhotoRecord == null && showSettings) {
                showSettings = false
            }

            BackHandler(
                enabled = !showScanner &&
                    previewPhotoRecord == null &&
                    !showSettings &&
                    (isTransferring || connectionState is ConnectionState.Connected)
            ) {
                // Move app cleanly to background instead of destroying the Activity.
                moveTaskToBack(true)
            }

            LaunchedEffect(isDarkTheme) {
                enableEdgeToEdge(
                    statusBarStyle = if (isDarkTheme) {
                        SystemBarStyle.dark(AndroidColor.TRANSPARENT)
                    } else {
                        SystemBarStyle.light(AndroidColor.TRANSPARENT, AndroidColor.TRANSPARENT)
                    },
                    navigationBarStyle = if (isDarkTheme) {
                        SystemBarStyle.dark(AndroidColor.TRANSPARENT)
                    } else {
                        SystemBarStyle.light(AndroidColor.TRANSPARENT, AndroidColor.TRANSPARENT)
                    }
                )
                WindowCompat.getInsetsController(window, view).apply {
                    isAppearanceLightStatusBars = !isDarkTheme
                    isAppearanceLightNavigationBars = !isDarkTheme
                }
            }

            LaunchedEffect(Unit) {
                client.bindApplicationContext(appCtx)
                client.checkForUpdates(appCtx, userInitiated = false)
            }

            val lifecycleOwner = LocalLifecycleOwner.current
            DisposableEffect(lifecycleOwner) {
                val observer = LifecycleEventObserver { _, event ->
                    if (event == Lifecycle.Event.ON_RESUME) {
                        client.checkForUpdates(appCtx, userInitiated = false)
                    }
                }
                lifecycleOwner.lifecycle.addObserver(observer)
                onDispose {
                    lifecycleOwner.lifecycle.removeObserver(observer)
                }
            }

            LaunchedEffect(connectionState, isTransferring) {
                if (isTransferring || connectionState is ConnectionState.Connected) {
                    requestNotificationPermissionIfNeeded()
                }
            }

            DisposableEffect(isTransferring) {
                if (isTransferring) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                onDispose {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }

            fun confirmAndSend(items: List<TransferItem>, label: String) {
                if (items.isEmpty()) return
                val totalBytes = items.sumOf { it.sizeBytes.coerceAtLeast(0L) }
                pendingConfirmation = PendingConfirmationUi(
                    message = "Вы уверены, что хотите отправить $label (${items.size} шт., ${FileTreeCollector.formatBytes(totalBytes)}) на MacBook?",
                    isDestructive = false,
                    onConfirm = {
                        requestNotificationPermissionIfNeeded()
                        client.startSendItems(appCtx, items)
                    }
                )
            }

            val cameraPermissionLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.RequestPermission()
            ) { granted ->
                if (granted) {
                    showScanner = true
                }
            }

            val filesPickerLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.OpenMultipleDocuments()
            ) { uris ->
                if (uris.isNotEmpty()) {
                    scope.launch {
                        val items = withContext(Dispatchers.IO) {
                            uris.forEach { uri ->
                                runCatching {
                                    appCtx.contentResolver.takePersistableUriPermission(
                                        uri,
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                                    )
                                }
                            }
                            FileTreeCollector.collectFromFileUris(appCtx, uris)
                        }
                        confirmAndSend(items, "выбранные файлы")
                    }
                }
            }

            val folderPickerLauncher = rememberLauncherForActivityResult(
                ActivityResultContracts.OpenDocumentTree()
            ) { treeUri ->
                if (treeUri != null) {
                    scope.launch {
                        val items = withContext(Dispatchers.IO) {
                            runCatching {
                                appCtx.contentResolver.takePersistableUriPermission(
                                    treeUri,
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                                )
                            }
                            FileTreeCollector.collectFromTreeUri(appCtx, treeUri)
                        }
                        confirmAndSend(items, "папку с файлами")
                    }
                }
            }

            val density = LocalDensity.current

            BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
                val rootWidthPx = with(density) { maxWidth.toPx() }.coerceAtLeast(1f)
                val rootHeightPx = with(density) { maxHeight.toPx() }.coerceAtLeast(1f)

                fun triggerRadialThemeToggle() {
                    if (themeRevealActive) return
                    val nextDark = !isDarkTheme
                    val fallbackOrigin = Offset(rootWidthPx - 96f, rootHeightPx * 0.55f)
                    val origin = themeButtonOrigin ?: fallbackOrigin
                    themeRevealOrigin = origin
                    client.setPersistedDarkTheme(appCtx, nextDark)

                    scope.launch {
                        themeRevealActive = true
                        if (!nextDark) {
                            // Dark -> Light: expand Light theme radially outward from button
                            themeRevealProgress.snapTo(0f)
                            themeRevealProgress.animateTo(
                                targetValue = 1f,
                                animationSpec = tween(
                                    durationMillis = 460,
                                    easing = CubicBezierEasing(0.25f, 0.45f, 0.22f, 1.0f)
                                )
                            )
                        } else {
                            // Light -> Dark: shrink Light theme radially back into button
                            isDarkTheme = true
                            themeRevealProgress.snapTo(1f)
                            themeRevealProgress.animateTo(
                                targetValue = 0f,
                                animationSpec = tween(
                                    durationMillis = 460,
                                    easing = CubicBezierEasing(0.25f, 0.45f, 0.22f, 1.0f)
                                )
                            )
                        }
                        isDarkTheme = nextDark
                        themeRevealActive = false
                    }
                }

                @Composable
                fun DroplyStage(dark: Boolean, trackOrigin: Boolean) {
                    DroplyTheme(darkTheme = dark) {
                        DroplyScreen(
                            isDarkTheme = dark,
                            showSettings = showSettings,
                            onShowSettingsChange = { showSettings = it },
                            previewPhotoRecord = previewPhotoRecord,
                            onPreviewPhoto = { previewPhotoRecord = it },
                            onClosePhotoPreview = { previewPhotoRecord = null },
                            onOpenInFileManager = remember(appCtx) {
                                { record ->
                                    if (!AndroidFileSaver.openInFileManager(appCtx, record)) {
                                        Toast.makeText(
                                            appCtx,
                                            "Файл сохранён в Загрузки/Droply",
                                            Toast.LENGTH_SHORT
                                        ).show()
                                    }
                                }
                            },
                            onToggleTheme = { triggerRadialThemeToggle() },
                            onThemeButtonPositioned = { pos ->
                                if (trackOrigin) {
                                    themeButtonOrigin = pos
                                }
                            },
                            deviceNameFlow = client.deviceName,
                            requireIncomingConfirmationFlow = client.requireIncomingConfirmation,
                            onUpdateDeviceName = remember(client) { { name -> client.setDeviceName(name) } },
                            onUpdateRequireIncomingConfirmation = remember(client) {
                                { require -> client.setRequireIncomingConfirmation(require) }
                            },
                            connectionStateFlow = client.connectionState,
                            isTransferringFlow = client.isTransferring,
                            progressFlow = client.progress,
                            historyFlow = client.history,
                            incomingRequestFlow = client.incomingRequest,
                            statusMessageFlow = client.statusMessage,
                            errorMessageFlow = client.errorMessage,
                            availableUpdateFlow = client.availableUpdate,
                            showUpdatePromptFlow = client.showUpdatePrompt,
                            isCheckingUpdatesFlow = client.isCheckingForUpdates,
                            currentVersionLabel = remember(appCtx) { client.currentAppVersion(appCtx) },
                            onCheckForUpdates = remember(client, appCtx) {
                                { client.checkForUpdates(appCtx, userInitiated = true) }
                            },
                            onOpenUpdatePrompt = remember(client) { { client.presentUpdatePrompt() } },
                            onDismissUpdatePrompt = remember(client) { { client.dismissUpdatePrompt() } },
                            onInstallUpdate = remember(client, appCtx) {
                                { client.openUpdateOnGitHub(appCtx) }
                            },
                            pendingConfirmation = pendingConfirmation,
                            onDismissConfirmation = remember { { pendingConfirmation = null } },
                            onDismissBanner = remember(client) { { client.clearMessages() } },
                            onOpenScanner = remember(context) {
                                {
                                    val hasPerm = ContextCompat.checkSelfPermission(
                                        context,
                                        Manifest.permission.CAMERA
                                    ) == PackageManager.PERMISSION_GRANTED
                                    if (hasPerm) {
                                        showScanner = true
                                    } else {
                                        cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
                                    }
                                }
                            },
                            onPickFiles = remember { { filesPickerLauncher.launch(arrayOf("*/*")) } },
                            onPickFolder = remember { { folderPickerLauncher.launch(null) } },
                            onSendTextNote = { fileName, content ->
                                val note = FileTreeCollector.buildTextNoteItem(fileName, content)
                                confirmAndSend(listOf(note), "текстовый файл «${note.relativePath}»")
                            },
                            onCopyTextRecord = remember(client, appCtx) {
                                { record -> client.copyTextRecord(appCtx, record) }
                            },
                            onRequestDeleteItem = remember(client) {
                                { record ->
                                    val shortName = record.relativePath.substringAfterLast('/')
                                    pendingConfirmation = PendingConfirmationUi(
                                        message = "Вы уверены, что хотите удалить «$shortName» из истории?",
                                        isDestructive = true,
                                        onConfirm = { client.removeHistoryItem(record.id) }
                                    )
                                }
                            },
                            onRespondIncoming = remember(client) {
                                { accepted -> client.respondToIncomingBatch(accepted) }
                            },
                            onRequestCancelTransfer = remember(client) {
                                {
                                    pendingConfirmation = PendingConfirmationUi(
                                        message = "Вы уверены, что хотите отменить текущую передачу файлов?",
                                        isDestructive = true,
                                        onConfirm = { client.cancelTransfer() }
                                    )
                                }
                            },
                            onRequestDisconnect = remember(client) {
                                {
                                    pendingConfirmation = PendingConfirmationUi(
                                        message = "Вы уверены, что хотите отключиться от MacBook?",
                                        isDestructive = true,
                                        onConfirm = { client.disconnect() }
                                    )
                                }
                            },
                            onRequestClearHistory = remember(client) {
                                {
                                    pendingConfirmation = PendingConfirmationUi(
                                        message = "Вы уверены, что хотите очистить всю историю файлов?",
                                        isDestructive = true,
                                        onConfirm = { client.clearHistory() }
                                    )
                                }
                            }
                        )
                    }
                }

                if (!themeRevealActive) {
                    DroplyStage(dark = isDarkTheme, trackOrigin = true)
                } else {
                    // Base: Dark navy theme; Top: Light theme revealed/collapsed circularly at button center
                    DroplyStage(dark = true, trackOrigin = false)

                    val maxRadius = remember(themeRevealOrigin, rootWidthPx, rootHeightPx) {
                        val ox = themeRevealOrigin.x
                        val oy = themeRevealOrigin.y
                        maxOf(
                            hypot(ox, oy),
                            hypot(rootWidthPx - ox, oy),
                            hypot(ox, rootHeightPx - oy),
                            hypot(rootWidthPx - ox, rootHeightPx - oy)
                        ) + 24f
                    }
                    val currentRadius = (themeRevealProgress.value * maxRadius).coerceAtLeast(1f)
                    val revealShape = GenericShape { _, _ ->
                        addOval(
                            Rect(
                                left = themeRevealOrigin.x - currentRadius,
                                top = themeRevealOrigin.y - currentRadius,
                                right = themeRevealOrigin.x + currentRadius,
                                bottom = themeRevealOrigin.y + currentRadius
                            )
                        )
                    }

                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .clip(revealShape)
                    ) {
                        DroplyStage(dark = false, trackOrigin = false)
                    }
                }

                AnimatedVisibility(
                    visible = showScanner,
                    enter = fadeIn(),
                    exit = fadeOut()
                ) {
                    DroplyTheme(darkTheme = isDarkTheme) {
                        QRScannerOverlay(
                            onPayloadScanned = { payload ->
                                showScanner = false
                                client.startConnect(appCtx, payload)
                            },
                            onClose = { showScanner = false }
                        )
                    }
                }
            }
        }
    }
}
