package com.droply.android.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.droply.android.transfer.ConnectionState
import com.droply.android.transfer.FileTreeCollector
import com.droply.android.transfer.IncomingBatchRequestUi
import com.droply.android.transfer.SentFileRecord
import com.droply.android.transfer.TransferProgressUi
import com.droply.android.update.AppUpdateInfo
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import java.util.Locale

enum class HistoryFilter(val label: String) {
    ALL("Все"),
    SENT("Отправка"),
    RECEIVED("Получение")
}

@Immutable
data class PendingConfirmationUi(
    val message: String,
    val isDestructive: Boolean = false,
    val onConfirm: () -> Unit,
    val onCancel: () -> Unit = {}
)

@Composable
private fun rememberPressScale(interactionSource: MutableInteractionSource, pressedScale: Float = 0.92f): Float {
    val rawPressed by interactionSource.collectIsPressedAsState()
    var visualPressed by remember { mutableStateOf(false) }
    var pressedAtMs by remember { mutableStateOf(0L) }

    LaunchedEffect(rawPressed) {
        if (rawPressed) {
            pressedAtMs = System.currentTimeMillis()
            visualPressed = true
        } else if (visualPressed) {
            val elapsed = System.currentTimeMillis() - pressedAtMs
            val remaining = (80L - elapsed).coerceAtLeast(0L)
            if (remaining > 0L) delay(remaining)
            visualPressed = false
        }
    }

    val scale by animateFloatAsState(
        targetValue = if (visualPressed) pressedScale else 1f,
        animationSpec = if (visualPressed) {
            spring(dampingRatio = 0.78f, stiffness = Spring.StiffnessHigh)
        } else {
            spring(dampingRatio = 0.56f, stiffness = Spring.StiffnessMediumLow)
        },
        label = "pressScale"
    )
    return scale
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DroplyScreen(
    isDarkTheme: Boolean,
    onToggleTheme: () -> Unit,
    deviceNameFlow: StateFlow<String>,
    requireIncomingConfirmationFlow: StateFlow<Boolean>,
    onUpdateDeviceName: (String) -> Unit,
    onUpdateRequireIncomingConfirmation: (Boolean) -> Unit,
    connectionStateFlow: StateFlow<ConnectionState>,
    isTransferringFlow: StateFlow<Boolean>,
    progressFlow: StateFlow<TransferProgressUi?>,
    historyFlow: StateFlow<List<SentFileRecord>>,
    incomingRequestFlow: StateFlow<IncomingBatchRequestUi?>,
    statusMessageFlow: StateFlow<String?>,
    errorMessageFlow: StateFlow<String?>,
    availableUpdateFlow: StateFlow<AppUpdateInfo?>,
    showUpdatePromptFlow: StateFlow<Boolean>,
    isCheckingUpdatesFlow: StateFlow<Boolean>,
    currentVersionLabel: String,
    onCheckForUpdates: () -> Unit,
    onOpenUpdatePrompt: () -> Unit,
    onDismissUpdatePrompt: () -> Unit,
    onInstallUpdate: () -> Unit,
    pendingConfirmation: PendingConfirmationUi?,
    onDismissConfirmation: () -> Unit,
    onDismissBanner: () -> Unit,
    onOpenScanner: () -> Unit,
    onPickFiles: () -> Unit,
    onPickFolder: () -> Unit,
    onSendTextNote: (fileName: String, content: String) -> Unit,
    onCopyTextRecord: (SentFileRecord) -> Unit,
    onRequestDeleteItem: (SentFileRecord) -> Unit,
    onRespondIncoming: (accepted: Boolean) -> Unit,
    onRequestCancelTransfer: () -> Unit,
    onRequestDisconnect: () -> Unit,
    onRequestClearHistory: () -> Unit
) {
    val connectionState by connectionStateFlow.collectAsState()
    val history by historyFlow.collectAsState()
    val statusMessage by statusMessageFlow.collectAsState()
    val errorMessage by errorMessageFlow.collectAsState()
    val incomingRequest by incomingRequestFlow.collectAsState()
    val availableUpdate by availableUpdateFlow.collectAsState()
    val showUpdatePrompt by showUpdatePromptFlow.collectAsState()
    val isCheckingUpdates by isCheckingUpdatesFlow.collectAsState()
    val deviceName by deviceNameFlow.collectAsState()
    val requireIncomingConfirmation by requireIncomingConfirmationFlow.collectAsState()
    var showTextComposer by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var historyFilter by remember { mutableStateOf(HistoryFilter.ALL) }

    val filteredHistory = remember(history, historyFilter) {
        when (historyFilter) {
            HistoryFilter.ALL -> history
            HistoryFilter.SENT -> history.filter { !it.isIncoming }
            HistoryFilter.RECEIVED -> history.filter { it.isIncoming }
        }
    }

    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .then(if (showSettings || (showUpdatePrompt && availableUpdate != null)) Modifier.blur(12.dp) else Modifier),
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopHeaderBar(
                isDarkTheme = isDarkTheme,
                availableUpdate = availableUpdate,
                onOpenUpdatePrompt = onOpenUpdatePrompt,
                onOpenSettings = { showSettings = true },
                isConnected = connectionState is ConnectionState.Connected,
                onRequestDisconnect = onRequestDisconnect
            )
        },
        bottomBar = {
            BottomTransferProgressBarHost(
                isTransferringFlow = isTransferringFlow,
                progressFlow = progressFlow,
                onRequestCancel = onRequestCancelTransfer
            )
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item(key = "banner", contentType = "banner") {
                AnimatedVisibility(
                    visible = errorMessage != null || statusMessage != null,
                    enter = expandVertically(spring(dampingRatio = 0.85f, stiffness = Spring.StiffnessMediumLow)) + fadeIn(tween(200)),
                    exit = shrinkVertically(spring(dampingRatio = 0.9f, stiffness = Spring.StiffnessMedium)) + fadeOut(tween(160))
                ) {
                    val isError = errorMessage != null
                    StatusBanner(
                        text = errorMessage ?: statusMessage.orEmpty(),
                        isError = isError,
                        onDismiss = onDismissBanner
                    )
                }
            }

            item(key = "connection_card", contentType = "connection") {
                ConnectionCard(
                    connectionState = connectionState,
                    onScanQR = onOpenScanner
                )
            }

            item(key = "actions_card", contentType = "actions") {
                AnimatedVisibility(
                    visible = connectionState is ConnectionState.Connected,
                    enter = expandVertically(spring(dampingRatio = 0.84f, stiffness = Spring.StiffnessMediumLow)) + fadeIn(tween(240)),
                    exit = shrinkVertically(spring(dampingRatio = 0.9f, stiffness = Spring.StiffnessMedium)) + fadeOut(tween(160))
                ) {
                    TransferActionsHost(
                        isTransferringFlow = isTransferringFlow,
                        onPickFiles = onPickFiles,
                        onPickFolder = onPickFolder,
                        onOpenTextComposer = { showTextComposer = true }
                    )
                }
            }

            item(key = "history_header", contentType = "header") {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 4.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Text(
                                text = "История",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onBackground
                            )
                            AnimatedVisibility(
                                visible = filteredHistory.isNotEmpty(),
                                enter = scaleIn() + fadeIn(),
                                exit = scaleOut() + fadeOut()
                            ) {
                                Surface(
                                    shape = CircleShape,
                                    color = MaterialTheme.colorScheme.surfaceVariant
                                ) {
                                    Text(
                                        text = "${filteredHistory.size}",
                                        style = MaterialTheme.typography.labelSmall,
                                        fontWeight = FontWeight.SemiBold,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                                    )
                                }
                            }
                        }

                        AnimatedVisibility(
                            visible = history.isNotEmpty(),
                            enter = scaleIn() + fadeIn(),
                            exit = scaleOut() + fadeOut()
                        ) {
                            val clearSource = remember { MutableInteractionSource() }
                            val clearScale = rememberPressScale(clearSource, 0.88f)
                            IconButton(
                                onClick = onRequestClearHistory,
                                interactionSource = clearSource,
                                modifier = Modifier
                                    .size(34.dp)
                                    .graphicsLayer {
                                        scaleX = clearScale
                                        scaleY = clearScale
                                    }
                            ) {
                                Icon(
                                    imageVector = MacIcons.Trash,
                                    contentDescription = "Очистить всё",
                                    tint = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.size(19.dp)
                                )
                            }
                        }
                    }

                    HistoryFilterBar(
                        selected = historyFilter,
                        onSelect = { historyFilter = it }
                    )
                }
            }

            if (filteredHistory.isEmpty()) {
                item(key = "empty_history", contentType = "empty") {
                    Surface(
                        shape = RoundedCornerShape(22.dp),
                        color = MaterialTheme.colorScheme.surface,
                        border = BorderStroke(0.8.dp, MaterialTheme.colorScheme.outline),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 24.dp, vertical = 32.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Icon(
                                imageVector = if (historyFilter == HistoryFilter.SENT) {
                                    MacIcons.Paperplane
                                } else {
                                    MacIcons.TrayAndArrowDown
                                },
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f),
                                modifier = Modifier.size(32.dp)
                            )
                            Text(
                                text = when (historyFilter) {
                                    HistoryFilter.SENT -> "Нет отправленных файлов"
                                    HistoryFilter.RECEIVED -> "Нет полученных файлов"
                                    HistoryFilter.ALL -> "История пока пуста"
                                },
                                style = MaterialTheme.typography.bodyLarge,
                                fontWeight = FontWeight.Medium,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            Text(
                                text = "Подключитесь по QR-коду и передавайте файлы, папки или заметки напрямую по Wi-Fi.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.Center
                            )
                        }
                    }
                }
            } else {
                items(
                    items = filteredHistory,
                    key = { it.id },
                    contentType = { "history_row" }
                ) { item ->
                    HistoryItemRow(
                        item = item,
                        onCopyText = { onCopyTextRecord(item) },
                        onDelete = { onRequestDeleteItem(item) },
                        modifier = Modifier.animateItem(
                            fadeInSpec = tween(220),
                            placementSpec = spring(dampingRatio = 0.84f, stiffness = Spring.StiffnessMediumLow),
                            fadeOutSpec = tween(180)
                        )
                    )
                }
            }
        }
    }

    if (showTextComposer) {
        var fileName by remember { mutableStateOf("note_${System.currentTimeMillis() / 1000}.txt") }
        var textBody by remember { mutableStateOf("") }

        ModalBottomSheet(
            onDismissRequest = { showTextComposer = false },
            containerColor = MaterialTheme.colorScheme.surface
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp)
                    .padding(bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text(
                    text = "Отправить текстовый файл",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold
                )
                OutlinedTextField(
                    value = fileName,
                    onValueChange = { fileName = it },
                    label = { Text("Имя файла (.txt)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp)
                )
                OutlinedTextField(
                    value = textBody,
                    onValueChange = { textBody = it },
                    label = { Text("Содержимое текста") },
                    minLines = 5,
                    maxLines = 10,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp)
                )
                val sendNoteSource = remember { MutableInteractionSource() }
                val sendNoteScale = rememberPressScale(sendNoteSource, 0.95f)
                Button(
                    onClick = {
                        showTextComposer = false
                        onSendTextNote(fileName, textBody)
                    },
                    enabled = textBody.isNotEmpty(),
                    interactionSource = sendNoteSource,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(50.dp)
                        .graphicsLayer {
                            scaleX = sendNoteScale
                            scaleY = sendNoteScale
                        },
                    shape = RoundedCornerShape(15.dp)
                ) {
                    Text("Отправить на MacBook", fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }

    if (showSettings) {
        SettingsBottomSheet(
            isDarkTheme = isDarkTheme,
            deviceName = deviceName,
            requireIncomingConfirmation = requireIncomingConfirmation,
            currentVersionLabel = currentVersionLabel,
            availableUpdate = availableUpdate,
            isCheckingUpdates = isCheckingUpdates,
            onCheckForUpdates = onCheckForUpdates,
            onOpenUpdatePrompt = {
                showSettings = false
                onOpenUpdatePrompt()
            },
            onToggleTheme = onToggleTheme,
            onUpdateDeviceName = onUpdateDeviceName,
            onUpdateRequireIncomingConfirmation = onUpdateRequireIncomingConfirmation,
            onDismiss = { showSettings = false }
        )
    }

    incomingRequest?.let { req ->
        val desc = if (req.totalFiles == 1 && !req.previewName.isNullOrBlank()) {
            val fileName = req.previewName.substringAfterLast('/')
            "файл «$fileName» (${FileTreeCollector.formatBytes(req.totalBytes)})"
        } else {
            "файлы (${req.totalFiles} шт., ${FileTreeCollector.formatBytes(req.totalBytes)})"
        }
        ConfirmationDialogCard(
            confirmation = PendingConfirmationUi(
                message = "Получить $desc от устройства ${req.senderName}?",
                isDestructive = false,
                onConfirm = { onRespondIncoming(true) },
                onCancel = { onRespondIncoming(false) }
            ),
            onDismiss = {}
        )
    }

    pendingConfirmation?.let { confirmation ->
        ConfirmationDialogCard(
            confirmation = confirmation,
            onDismiss = onDismissConfirmation
        )
    }

    val activeUpdate = availableUpdate
    if (showUpdatePrompt && activeUpdate != null) {
        UpdateAvailableDialog(
            isDarkTheme = isDarkTheme,
            update = activeUpdate,
            onInstall = onInstallUpdate,
            onDismiss = onDismissUpdatePrompt
        )
    }
}

@Composable
private fun BottomTransferProgressBarHost(
    isTransferringFlow: StateFlow<Boolean>,
    progressFlow: StateFlow<TransferProgressUi?>,
    onRequestCancel: () -> Unit
) {
    val isTransferring by isTransferringFlow.collectAsState()
    val progress by progressFlow.collectAsState()

    AnimatedVisibility(
        visible = isTransferring && progress != null,
        enter = slideInVertically(
            animationSpec = spring(dampingRatio = 0.84f, stiffness = Spring.StiffnessMediumLow),
            initialOffsetY = { it }
        ) + fadeIn(tween(220)),
        exit = slideOutVertically(
            animationSpec = spring(dampingRatio = 0.9f, stiffness = Spring.StiffnessMedium),
            targetOffsetY = { it }
        ) + fadeOut(tween(180))
    ) {
        progress?.let { snap ->
            BottomTransferProgressBar(
                progress = snap,
                onRequestCancel = onRequestCancel
            )
        }
    }
}

@Composable
private fun TransferActionsHost(
    isTransferringFlow: StateFlow<Boolean>,
    onPickFiles: () -> Unit,
    onPickFolder: () -> Unit,
    onOpenTextComposer: () -> Unit
) {
    val isTransferring by isTransferringFlow.collectAsState()
    TransferActionsSection(
        enabled = !isTransferring,
        onPickFiles = onPickFiles,
        onPickFolder = onPickFolder,
        onOpenTextComposer = onOpenTextComposer
    )
}

@Composable
private fun HistoryFilterBar(
    selected: HistoryFilter,
    onSelect: (HistoryFilter) -> Unit
) {
    val entries = HistoryFilter.entries
    val selectedIndex = entries.indexOf(selected).coerceAtLeast(0)
    val animatedIndex by animateFloatAsState(
        targetValue = selectedIndex.toFloat(),
        animationSpec = spring(dampingRatio = 0.82f, stiffness = Spring.StiffnessMedium),
        label = "historyTabSlide"
    )
    val density = LocalDensity.current

    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceVariant,
        border = BorderStroke(0.8.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier
            .fillMaxWidth()
            .height(42.dp)
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxSize()
                .padding(3.5.dp)
        ) {
            val tabWidth = maxWidth / entries.size
            val tabWidthPx = with(density) { tabWidth.toPx() }

            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.surface,
                shadowElevation = 2.dp,
                modifier = Modifier
                    .width(tabWidth)
                    .fillMaxHeight()
                    .graphicsLayer {
                        translationX = animatedIndex * tabWidthPx
                    }
            ) {}

            Row(modifier = Modifier.fillMaxSize()) {
                entries.forEach { filter ->
                    val isSelected = filter == selected
                    val labelColor by animateColorAsState(
                        targetValue = if (isSelected) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                        animationSpec = tween(200),
                        label = "tabLabelColor"
                    )
                    val tabSource = remember { MutableInteractionSource() }
                    val tabScale = rememberPressScale(tabSource, 0.92f)
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight()
                            .graphicsLayer {
                                scaleX = tabScale
                                scaleY = tabScale
                            }
                            .clip(CircleShape)
                            .clickable(
                                interactionSource = tabSource,
                                indication = null
                            ) {
                                onSelect(filter)
                            }
                            .padding(horizontal = 4.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = filter.label,
                            fontSize = 13.sp,
                            fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Medium,
                            color = labelColor,
                            maxLines = 1,
                            softWrap = false
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TopHeaderBar(
    isDarkTheme: Boolean,
    availableUpdate: AppUpdateInfo?,
    onOpenUpdatePrompt: () -> Unit,
    onOpenSettings: () -> Unit,
    isConnected: Boolean,
    onRequestDisconnect: () -> Unit
) {
    Surface(
        color = MaterialTheme.colorScheme.background,
        modifier = Modifier.statusBarsPadding()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(RoundedCornerShape(11.dp))
                        .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.13f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = MacIcons.Wifi,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(19.dp)
                    )
                }
                Text(
                    text = "Droply",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold
                )
            }

            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                AnimatedVisibility(
                    visible = availableUpdate != null,
                    enter = scaleIn(spring(dampingRatio = 0.78f)) + fadeIn(tween(180)),
                    exit = scaleOut() + fadeOut(tween(150))
                ) {
                    FrostedGlassPillButton(
                        isDarkTheme = isDarkTheme,
                        accentTint = MaterialTheme.colorScheme.primary,
                        onClick = onOpenUpdatePrompt,
                        contentPadding = PaddingValues(horizontal = 11.dp, vertical = 8.dp)
                    ) {
                        Icon(
                            imageVector = MacIcons.ArrowDownCircle,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(modifier = Modifier.width(5.dp))
                        Text(
                            text = "Обновить",
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                    }
                }

                AnimatedVisibility(
                    visible = isConnected,
                    enter = scaleIn(spring(dampingRatio = 0.78f)) + fadeIn(tween(180)),
                    exit = scaleOut() + fadeOut(tween(150))
                ) {
                    val disconnectSource = remember { MutableInteractionSource() }
                    val disconnectScale = rememberPressScale(disconnectSource, 0.92f)
                    Surface(
                        onClick = onRequestDisconnect,
                        interactionSource = disconnectSource,
                        shape = RoundedCornerShape(12.dp),
                        color = MaterialTheme.colorScheme.error.copy(alpha = 0.11f),
                        modifier = Modifier.graphicsLayer {
                            scaleX = disconnectScale
                            scaleY = disconnectScale
                        }
                    ) {
                        Box(modifier = Modifier.padding(10.dp)) {
                            Icon(
                                imageVector = MacIcons.XmarkCircle,
                                contentDescription = "Отключиться",
                                tint = MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(19.dp)
                            )
                        }
                    }
                }

                val settingsSource = remember { MutableInteractionSource() }
                val settingsScale = rememberPressScale(settingsSource, 0.92f)
                Surface(
                    onClick = onOpenSettings,
                    interactionSource = settingsSource,
                    shape = RoundedCornerShape(12.dp),
                    color = MaterialTheme.colorScheme.surface,
                    border = BorderStroke(0.8.dp, MaterialTheme.colorScheme.outline),
                    modifier = Modifier.graphicsLayer {
                        scaleX = settingsScale
                        scaleY = settingsScale
                    }
                ) {
                    Box(modifier = Modifier.padding(10.dp)) {
                        Icon(
                            imageVector = MacIcons.Gear,
                            contentDescription = "Настройки",
                            tint = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.size(19.dp)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun rememberGlassFillBrush(isDarkTheme: Boolean, accentTint: Color? = null): Brush {
    return remember(isDarkTheme, accentTint) {
        if (accentTint != null) {
            Brush.verticalGradient(
                listOf(
                    accentTint.copy(alpha = if (isDarkTheme) 0.34f else 0.22f),
                    accentTint.copy(alpha = if (isDarkTheme) 0.16f else 0.10f)
                )
            )
        } else {
            Brush.verticalGradient(
                if (isDarkTheme) {
                    listOf(Color.White.copy(alpha = 0.13f), Color.White.copy(alpha = 0.05f))
                } else {
                    listOf(Color.White.copy(alpha = 0.70f), Color.White.copy(alpha = 0.36f))
                }
            )
        }
    }
}

@Composable
private fun rememberGlassRimBrush(isDarkTheme: Boolean, accentTint: Color? = null): Brush {
    return remember(isDarkTheme, accentTint) {
        if (accentTint != null) {
            Brush.verticalGradient(
                listOf(accentTint.copy(alpha = 0.68f), accentTint.copy(alpha = 0.24f))
            )
        } else {
            Brush.verticalGradient(
                if (isDarkTheme) {
                    listOf(Color.White.copy(alpha = 0.28f), Color.White.copy(alpha = 0.07f))
                } else {
                    listOf(Color.White.copy(alpha = 0.94f), Color(0xFFBBD0EB).copy(alpha = 0.52f))
                }
            )
        }
    }
}

@Composable
private fun FrostedGlassBlock(
    isDarkTheme: Boolean,
    modifier: Modifier = Modifier,
    cornerRadius: Dp = 18.dp,
    baseColor: Color? = null,
    accentTint: Color? = null,
    content: @Composable BoxScope.() -> Unit
) {
    val shape = RoundedCornerShape(cornerRadius)
    val fillBrush = rememberGlassFillBrush(isDarkTheme, accentTint)
    val rimBrush = rememberGlassRimBrush(isDarkTheme, accentTint)

    Box(
        modifier = modifier
            .clip(shape)
            .then(if (baseColor != null) Modifier.background(baseColor) else Modifier)
            .background(fillBrush)
            .border(1.dp, rimBrush, shape),
        content = content
    )
}

@Composable
private fun FrostedGlassPillButton(
    isDarkTheme: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    accentTint: Color? = null,
    contentPadding: PaddingValues = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
    content: @Composable RowScope.() -> Unit
) {
    val source = remember { MutableInteractionSource() }
    val scale = rememberPressScale(source, 0.92f)
    val fillBrush = rememberGlassFillBrush(isDarkTheme, accentTint)
    val rimBrush = rememberGlassRimBrush(isDarkTheme, accentTint)

    Row(
        modifier = modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                alpha = if (enabled) 1f else 0.58f
            }
            .clip(CircleShape)
            .background(fillBrush)
            .border(1.dp, rimBrush, CircleShape)
            .clickable(
                interactionSource = source,
                indication = null,
                enabled = enabled,
                onClick = onClick
            )
            .padding(contentPadding),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
        content = content
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsBottomSheet(
    isDarkTheme: Boolean,
    deviceName: String,
    requireIncomingConfirmation: Boolean,
    currentVersionLabel: String,
    availableUpdate: AppUpdateInfo?,
    isCheckingUpdates: Boolean,
    onCheckForUpdates: () -> Unit,
    onOpenUpdatePrompt: () -> Unit,
    onToggleTheme: () -> Unit,
    onUpdateDeviceName: (String) -> Unit,
    onUpdateRequireIncomingConfirmation: (Boolean) -> Unit,
    onDismiss: () -> Unit
) {
    var nameDraft by remember(deviceName) { mutableStateOf(deviceName) }
    val sheetBase = if (isDarkTheme) {
        Color(0xFF141B29).copy(alpha = 0.80f)
    } else {
        Color(0xFFEAF1FB).copy(alpha = 0.82f)
    }

    ModalBottomSheet(
        onDismissRequest = {
            onUpdateDeviceName(nameDraft)
            onDismiss()
        },
        containerColor = Color.Transparent,
        scrimColor = Color.Black.copy(alpha = if (isDarkTheme) 0.42f else 0.20f),
        dragHandle = null
    ) {
        FrostedGlassBlock(
            isDarkTheme = isDarkTheme,
            cornerRadius = 28.dp,
            baseColor = sheetBase,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp)
                .navigationBarsPadding()
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 18.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterHorizontally)
                        .width(38.dp)
                        .height(4.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.36f))
                )

                Text(
                    text = "Настройки",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )

                // 1. Theme toggle
                FrostedGlassBlock(
                    isDarkTheme = isDarkTheme,
                    cornerRadius = 18.dp,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                text = "Тема оформления",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Medium,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            Text(
                                text = if (isDarkTheme) "Тёмная" else "Светлая",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }

                        FrostedGlassPillButton(
                            isDarkTheme = isDarkTheme,
                            onClick = onToggleTheme
                        ) {
                            AnimatedContent(
                                targetState = isDarkTheme,
                                transitionSpec = {
                                    (scaleIn(spring(dampingRatio = 0.78f)) + fadeIn(tween(200))) togetherWith
                                        (scaleOut(tween(120)) + fadeOut(tween(120)))
                                },
                                label = "settingsThemeIcon"
                            ) { dark ->
                                Icon(
                                    imageVector = if (dark) MacIcons.SunMaxFill else MacIcons.MoonFill,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier.size(16.dp)
                                )
                            }
                            Spacer(modifier = Modifier.width(7.dp))
                            Text(
                                text = if (isDarkTheme) "Светлая" else "Тёмная",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                        }
                    }
                }

                // 2. Device name
                FrostedGlassBlock(
                    isDarkTheme = isDarkTheme,
                    cornerRadius = 18.dp,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(
                            text = "Имя устройства",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        OutlinedTextField(
                            value = nameDraft,
                            onValueChange = { next ->
                                nameDraft = next
                                val trimmed = next.trim()
                                if (trimmed.isNotEmpty()) {
                                    onUpdateDeviceName(trimmed)
                                }
                            },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(12.dp),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedContainerColor = Color.White.copy(alpha = if (isDarkTheme) 0.08f else 0.42f),
                                unfocusedContainerColor = Color.White.copy(alpha = if (isDarkTheme) 0.05f else 0.28f),
                                focusedBorderColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.72f),
                                unfocusedBorderColor = Color.White.copy(alpha = if (isDarkTheme) 0.16f else 0.72f)
                            )
                        )
                    }
                }

                // 3. Confirm before receiving files
                FrostedGlassBlock(
                    isDarkTheme = isDarkTheme,
                    cornerRadius = 18.dp,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(
                            modifier = Modifier
                                .weight(1f)
                                .padding(end = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(2.dp)
                        ) {
                            Text(
                                text = "Подтверждать приём",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Medium,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            Text(
                                text = "Спрашивать перед получением файлов",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Switch(
                            checked = requireIncomingConfirmation,
                            onCheckedChange = onUpdateRequireIncomingConfirmation
                        )
                    }
                }

                // 4. App updates
                FrostedGlassBlock(
                    isDarkTheme = isDarkTheme,
                    cornerRadius = 18.dp,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(
                            modifier = Modifier
                                .weight(1f)
                                .padding(end = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(2.dp)
                        ) {
                            Text(
                                text = "Обновление приложения",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Medium,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            Text(
                                text = availableUpdate?.let { "Доступна версия ${it.latestVersion}" }
                                    ?: "Версия $currentVersionLabel",
                                style = MaterialTheme.typography.labelSmall,
                                color = if (availableUpdate != null) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                }
                            )
                        }

                        FrostedGlassPillButton(
                            isDarkTheme = isDarkTheme,
                            enabled = !isCheckingUpdates,
                            accentTint = if (availableUpdate != null) MaterialTheme.colorScheme.primary else null,
                            onClick = {
                                if (availableUpdate != null) {
                                    onOpenUpdatePrompt()
                                } else {
                                    onCheckForUpdates()
                                }
                            }
                        ) {
                            Text(
                                text = when {
                                    availableUpdate != null -> "Обновить"
                                    isCheckingUpdates -> "Поиск..."
                                    else -> "Проверить"
                                },
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.SemiBold,
                                color = if (availableUpdate != null) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.onSurface
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun UpdateAvailableDialog(
    isDarkTheme: Boolean,
    update: AppUpdateInfo,
    onInstall: () -> Unit,
    onDismiss: () -> Unit
) {
    val cardBase = if (isDarkTheme) {
        Color(0xFF141B29).copy(alpha = 0.86f)
    } else {
        Color(0xFFEFF5FD).copy(alpha = 0.88f)
    }
    Dialog(onDismissRequest = onDismiss) {
        FrostedGlassBlock(
            isDarkTheme = isDarkTheme,
            cornerRadius = 26.dp,
            baseColor = cardBase
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(22.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.14f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = MacIcons.ArrowDownCircle,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(25.dp)
                    )
                }

                Text(
                    text = update.title ?: "Доступна новая версия Droply",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.onSurface
                )

                Text(
                    text = "Нажмите «Установить», чтобы перейти на GitHub и скачать обновление.",
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                FrostedGlassBlock(
                    isDarkTheme = isDarkTheme,
                    cornerRadius = 999.dp,
                    accentTint = MaterialTheme.colorScheme.primary
                ) {
                    Text(
                        text = "${update.currentVersion}  →  ${update.latestVersion}",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 7.dp)
                    )
                }

                if (!update.releaseNotes.isNullOrBlank()) {
                    FrostedGlassBlock(
                        isDarkTheme = isDarkTheme,
                        cornerRadius = 14.dp,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            text = update.releaseNotes,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 8,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(12.dp)
                        )
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    FrostedGlassPillButton(
                        isDarkTheme = isDarkTheme,
                        onClick = onDismiss,
                        modifier = Modifier.weight(1f),
                        contentPadding = PaddingValues(vertical = 11.dp)
                    ) {
                        Text(
                            text = "Позже",
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.Medium,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                    }

                    FrostedGlassPillButton(
                        isDarkTheme = isDarkTheme,
                        accentTint = MaterialTheme.colorScheme.primary,
                        onClick = onInstall,
                        modifier = Modifier.weight(1f),
                        contentPadding = PaddingValues(vertical = 11.dp)
                    ) {
                        Text(
                            text = "Установить",
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ConnectionCard(
    connectionState: ConnectionState,
    onScanQR: () -> Unit
) {
    Surface(
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(0.8.dp, MaterialTheme.colorScheme.outline),
        modifier = Modifier.fillMaxWidth()
    ) {
        AnimatedContent(
            targetState = connectionState,
            transitionSpec = {
                (fadeIn(tween(240)) + scaleIn(initialScale = 0.97f, animationSpec = spring(dampingRatio = 0.85f))) togetherWith
                    (fadeOut(tween(160)) + scaleOut(targetScale = 0.97f))
            },
            label = "connectionCardState"
        ) { state ->
            when (state) {
                is ConnectionState.Connected -> {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 18.dp, vertical = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(40.dp)
                                .clip(RoundedCornerShape(12.dp))
                                .background(Color(0xFF16A34A).copy(alpha = 0.12f)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = MacIcons.Wifi,
                                contentDescription = null,
                                tint = Color(0xFF16A34A),
                                modifier = Modifier.size(20.dp)
                            )
                        }

                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp)
                        ) {
                            Text(
                                text = state.macName,
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                text = "Подключено · ${state.host}:${state.port}",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }

                        val rescanSource = remember { MutableInteractionSource() }
                        val rescanScale = rememberPressScale(rescanSource, 0.93f)
                        Surface(
                            onClick = onScanQR,
                            interactionSource = rescanSource,
                            shape = RoundedCornerShape(12.dp),
                            color = MaterialTheme.colorScheme.surfaceVariant,
                            modifier = Modifier.graphicsLayer {
                                scaleX = rescanScale
                                scaleY = rescanScale
                            }
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 11.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Icon(
                                    imageVector = MacIcons.QrCode,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier.size(16.dp)
                                )
                                Text(
                                    text = "Сменить",
                                    style = MaterialTheme.typography.labelMedium,
                                    fontWeight = FontWeight.SemiBold,
                                    color = MaterialTheme.colorScheme.onSurface
                                )
                            }
                        }
                    }
                }

                is ConnectionState.Connecting, is ConnectionState.Disconnected -> {
                    val isConnecting = state is ConnectionState.Connecting
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 24.dp, vertical = 26.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        QrPortalEmblem(
                            isConnecting = isConnecting,
                            onClick = onScanQR
                        )

                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(5.dp)
                        ) {
                            Text(
                                text = if (isConnecting) "Подключение..." else "Подключить MacBook",
                                style = MaterialTheme.typography.titleMedium,
                                fontSize = 18.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onSurface,
                                textAlign = TextAlign.Center
                            )
                            Text(
                                text = if (isConnecting) {
                                    "Подтвердите сопряжение на экране MacBook"
                                } else {
                                    "Наведите камеру на QR-код в окне MacBook"
                                },
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.Center
                            )
                        }

                        if (isConnecting) {
                            LinearProgressIndicator(
                                modifier = Modifier
                                    .width(148.dp)
                                    .height(4.dp)
                                    .clip(CircleShape),
                                strokeCap = StrokeCap.Round
                            )
                        } else {
                            val scanSource = remember { MutableInteractionSource() }
                            val scanScale = rememberPressScale(scanSource, 0.95f)
                            Button(
                                onClick = onScanQR,
                                interactionSource = scanSource,
                                shape = CircleShape,
                                contentPadding = PaddingValues(horizontal = 26.dp),
                                modifier = Modifier
                                    .widthIn(min = 210.dp)
                                    .height(46.dp)
                                    .graphicsLayer {
                                        scaleX = scanScale
                                        scaleY = scanScale
                                    }
                            ) {
                                Icon(
                                    imageVector = MacIcons.QrCode,
                                    contentDescription = null,
                                    modifier = Modifier.size(18.dp)
                                )
                                Spacer(modifier = Modifier.width(9.dp))
                                Text(
                                    text = "Сканировать QR",
                                    fontWeight = FontWeight.SemiBold
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun QrPortalEmblem(
    isConnecting: Boolean,
    onClick: () -> Unit
) {
    val pulseTransition = rememberInfiniteTransition(label = "qrPortalPulse")
    val pulseScale by pulseTransition.animateFloat(
        initialValue = 0.93f,
        targetValue = 1.07f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2200, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulseScale"
    )
    val pulseAlpha by pulseTransition.animateFloat(
        initialValue = 0.08f,
        targetValue = 0.18f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2200, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulseAlpha"
    )

    val interactionSource = remember { MutableInteractionSource() }
    val pressScale = rememberPressScale(interactionSource, 0.91f)
    val accent = MaterialTheme.colorScheme.primary

    Box(
        modifier = Modifier
            .size(94.dp)
            .graphicsLayer {
                scaleX = pressScale
                scaleY = pressScale
            }
            .clip(RoundedCornerShape(28.dp))
            .clickable(
                enabled = !isConnecting,
                interactionSource = interactionSource,
                indication = null,
                onClick = onClick
            ),
        contentAlignment = Alignment.Center
    ) {
        Box(
            modifier = Modifier
                .size(86.dp)
                .graphicsLayer {
                    scaleX = pulseScale
                    scaleY = pulseScale
                }
                .clip(RoundedCornerShape(26.dp))
                .background(accent.copy(alpha = pulseAlpha))
        )

        Box(
            modifier = Modifier
                .size(72.dp)
                .clip(RoundedCornerShape(22.dp))
                .background(MaterialTheme.colorScheme.surface)
        )

        Canvas(modifier = Modifier.size(76.dp)) {
            val inset = 2.dp.toPx()
            val left = inset
            val top = inset
            val right = size.width - inset
            val bottom = size.height - inset
            val arm = 12.dp.toPx()
            val r = 18.dp.toPx()

            val cornerPath = Path().apply {
                moveTo(left, top + r + arm)
                lineTo(left, top + r)
                quadraticTo(left, top, left + r, top)
                lineTo(left + r + arm, top)

                moveTo(right - r - arm, top)
                lineTo(right - r, top)
                quadraticTo(right, top, right, top + r)
                lineTo(right, top + r + arm)

                moveTo(right, bottom - r - arm)
                lineTo(right, bottom - r)
                quadraticTo(right, bottom, right - r, bottom)
                lineTo(right - r - arm, bottom)

                moveTo(left + r + arm, bottom)
                lineTo(left + r, bottom)
                quadraticTo(left, bottom, left, bottom - r)
                lineTo(left, bottom - r - arm)
            }
            drawPath(
                path = cornerPath,
                color = accent.copy(alpha = 0.65f),
                style = Stroke(
                    width = 2.2.dp.toPx(),
                    cap = StrokeCap.Round,
                    join = StrokeJoin.Round
                )
            )
        }

        Icon(
            imageVector = MacIcons.QrCode,
            contentDescription = "Сканировать QR-код",
            tint = accent,
            modifier = Modifier.size(32.dp)
        )
    }
}

@Composable
private fun TransferActionsSection(
    enabled: Boolean,
    onPickFiles: () -> Unit,
    onPickFolder: () -> Unit,
    onOpenTextComposer: () -> Unit
) {
    val contentAlpha by animateFloatAsState(
        targetValue = if (enabled) 1f else 0.48f,
        animationSpec = tween(220),
        label = "tilesAlpha"
    )
    Column(
        modifier = Modifier.graphicsLayer { alpha = contentAlpha },
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text(
            text = "Отправить на MacBook",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onBackground
        )
        BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
            val gap = 14.dp
            val tileSize = ((maxWidth - gap * 2) / 3f).coerceIn(84.dp, 96.dp)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(gap, Alignment.CenterHorizontally)
            ) {
                ActionTile(
                    icon = MacIcons.DocBadgePlus,
                    title = "Файлы",
                    enabled = enabled,
                    onClick = onPickFiles,
                    modifier = Modifier.size(tileSize)
                )
                ActionTile(
                    icon = MacIcons.FolderBadgePlus,
                    title = "Папка",
                    enabled = enabled,
                    onClick = onPickFolder,
                    modifier = Modifier.size(tileSize)
                )
                ActionTile(
                    icon = MacIcons.TextBadgePlus,
                    title = "Текст",
                    enabled = enabled,
                    onClick = onOpenTextComposer,
                    modifier = Modifier.size(tileSize)
                )
            }
        }
    }
}

@Composable
private fun ActionTile(
    icon: ImageVector,
    title: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val interactionSource = remember { MutableInteractionSource() }
    val scale = rememberPressScale(interactionSource, 0.93f)

    Surface(
        onClick = onClick,
        enabled = enabled,
        interactionSource = interactionSource,
        shape = RoundedCornerShape(24.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(0.8.dp, MaterialTheme.colorScheme.outline),
        modifier = modifier.graphicsLayer {
            scaleX = scale
            scaleY = scale
        }
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = 15.dp, bottom = 11.dp, start = 8.dp, end = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(20.dp)
                )
            }
            Text(
                text = title,
                color = MaterialTheme.colorScheme.onSurface,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center,
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
private fun BottomTransferProgressBar(
    progress: TransferProgressUi,
    onRequestCancel: () -> Unit
) {
    val animatedFraction by animateFloatAsState(
        targetValue = (progress.percent / 100.0).toFloat().coerceIn(0f, 1f),
        animationSpec = tween(durationMillis = 150),
        label = "progressFill"
    )

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 16.dp, vertical = 10.dp)
    ) {
        Surface(
            shape = RoundedCornerShape(22.dp),
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = 4.dp,
            shadowElevation = 10.dp,
            border = BorderStroke(0.8.dp, MaterialTheme.colorScheme.outline),
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Icon(
                        imageVector = if (progress.isIncoming) {
                            MacIcons.ArrowDownCircleFill
                        } else {
                            MacIcons.ArrowUpCircleFill
                        },
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(21.dp)
                    )

                    Spacer(modifier = Modifier.width(10.dp))

                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = progress.currentFileName,
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = "${if (progress.isIncoming) "Получение" else "Отправка"} · " +
                                "${progress.fileIndex + 1}/${progress.totalFiles} · " +
                                "${FileTreeCollector.formatBytes(progress.bytesTransferred)} / " +
                                "${FileTreeCollector.formatBytes(progress.totalBytes)} · " +
                                FileTreeCollector.formatSpeed(progress.speedBytesPerSecond),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }

                    Spacer(modifier = Modifier.width(8.dp))

                    Text(
                        text = String.format(Locale.getDefault(), "%.0f%%", progress.percent),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = MaterialTheme.colorScheme.primary
                    )

                    Spacer(modifier = Modifier.width(8.dp))

                    val cancelSource = remember { MutableInteractionSource() }
                    val cancelScale = rememberPressScale(cancelSource, 0.93f)
                    Surface(
                        onClick = onRequestCancel,
                        interactionSource = cancelSource,
                        shape = RoundedCornerShape(10.dp),
                        color = MaterialTheme.colorScheme.error.copy(alpha = 0.11f),
                        modifier = Modifier.graphicsLayer {
                            scaleX = cancelScale
                            scaleY = cancelScale
                        }
                    ) {
                        Text(
                            text = "Отменить",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
                        )
                    }
                }

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(6.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .graphicsLayer {
                                scaleX = animatedFraction.coerceAtLeast(0.02f)
                                transformOrigin = TransformOrigin(0f, 0.5f)
                            }
                            .clip(CircleShape)
                            .background(
                                Brush.horizontalGradient(
                                    listOf(
                                        MaterialTheme.colorScheme.primary,
                                        MaterialTheme.colorScheme.primary.copy(alpha = 0.78f)
                                    )
                                )
                            )
                    )
                }
            }
        }
    }
}

@Composable
private fun HistoryItemRow(
    item: SentFileRecord,
    onCopyText: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier
) {
    val directionColor = if (item.isIncoming) Color(0xFF16A34A) else MaterialTheme.colorScheme.primary
    Surface(
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(0.8.dp, MaterialTheme.colorScheme.outline),
        modifier = modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(RoundedCornerShape(11.dp))
                    .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.11f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = when {
                        item.isText -> MacIcons.DocText
                        item.relativePath.contains('/') -> MacIcons.FolderFill
                        else -> MacIcons.DocFill
                    },
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(18.dp)
                )
            }

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp)
            ) {
                Text(
                    text = item.relativePath,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )

                val metaText = buildAnnotatedString {
                    if (item.errorMessage != null) {
                        append(item.errorMessage)
                    } else {
                        withStyle(SpanStyle(color = directionColor, fontWeight = FontWeight.Medium)) {
                            append(if (item.isIncoming) "Получено" else "Отправлено")
                        }
                        append(" · ")
                        append(FileTreeCollector.formatBytes(item.sizeBytes))
                    }
                }
                Text(
                    text = metaText,
                    style = MaterialTheme.typography.labelSmall,
                    color = if (item.ok) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }

            if (item.isText && item.ok) {
                val copySource = remember { MutableInteractionSource() }
                val copyScale = rememberPressScale(copySource, 0.90f)
                Surface(
                    onClick = onCopyText,
                    interactionSource = copySource,
                    shape = RoundedCornerShape(10.dp),
                    color = MaterialTheme.colorScheme.primary.copy(alpha = 0.11f),
                    modifier = Modifier.graphicsLayer {
                        scaleX = copyScale
                        scaleY = copyScale
                    }
                ) {
                    Icon(
                        imageVector = MacIcons.DocOnClipboard,
                        contentDescription = "Копировать текст",
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier
                            .padding(8.dp)
                            .size(16.dp)
                    )
                }
            }

            if (!item.ok) {
                Icon(
                    imageVector = MacIcons.ExclamationTriangleFill,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.error,
                    modifier = Modifier.size(17.dp)
                )
            }

            val deleteSource = remember { MutableInteractionSource() }
            val deleteScale = rememberPressScale(deleteSource, 0.88f)
            IconButton(
                onClick = onDelete,
                interactionSource = deleteSource,
                modifier = Modifier
                    .size(30.dp)
                    .graphicsLayer {
                        scaleX = deleteScale
                        scaleY = deleteScale
                    }
            ) {
                Icon(
                    imageVector = MacIcons.Trash,
                    contentDescription = "Удалить",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(17.dp)
                )
            }
        }
    }
}

@Composable
private fun StatusBanner(
    text: String,
    isError: Boolean,
    onDismiss: () -> Unit
) {
    val tint = if (isError) MaterialTheme.colorScheme.error else Color(0xFF16A34A)
    Surface(
        shape = RoundedCornerShape(15.dp),
        color = tint.copy(alpha = 0.11f),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Icon(
                imageVector = if (isError) MacIcons.ExclamationTriangleFill else MacIcons.CheckmarkCircleFill,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(18.dp)
            )
            Text(
                text = text,
                style = MaterialTheme.typography.bodySmall,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onBackground,
                modifier = Modifier.weight(1f)
            )
            val dismissSource = remember { MutableInteractionSource() }
            val dismissScale = rememberPressScale(dismissSource, 0.88f)
            IconButton(
                onClick = onDismiss,
                interactionSource = dismissSource,
                modifier = Modifier
                    .size(24.dp)
                    .graphicsLayer {
                        scaleX = dismissScale
                        scaleY = dismissScale
                    }
            ) {
                Icon(
                    imageVector = MacIcons.Xmark,
                    contentDescription = "Закрыть",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(15.dp)
                )
            }
        }
    }
}

@Composable
private fun ConfirmationDialogCard(
    confirmation: PendingConfirmationUi,
    onDismiss: () -> Unit
) {
    val badgeColor = if (confirmation.isDestructive) {
        MaterialTheme.colorScheme.error
    } else {
        MaterialTheme.colorScheme.primary
    }
    Dialog(
        onDismissRequest = {
            confirmation.onCancel()
            onDismiss()
        }
    ) {
        Surface(
            shape = RoundedCornerShape(24.dp),
            color = MaterialTheme.colorScheme.surface,
            border = BorderStroke(0.8.dp, MaterialTheme.colorScheme.outline),
            tonalElevation = 8.dp
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .background(badgeColor.copy(alpha = 0.13f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = if (confirmation.isDestructive) {
                            MacIcons.ExclamationTriangleFill
                        } else {
                            MacIcons.QuestionmarkCircleFill
                        },
                        contentDescription = null,
                        tint = badgeColor,
                        modifier = Modifier.size(22.dp)
                    )
                }

                Text(
                    text = confirmation.message,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.onSurface
                )

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    val cancelDialogSource = remember { MutableInteractionSource() }
                    val cancelDialogScale = rememberPressScale(cancelDialogSource, 0.94f)
                    OutlinedButton(
                        onClick = {
                            confirmation.onCancel()
                            onDismiss()
                        },
                        interactionSource = cancelDialogSource,
                        modifier = Modifier
                            .weight(1f)
                            .height(46.dp)
                            .graphicsLayer {
                                scaleX = cancelDialogScale
                                scaleY = cancelDialogScale
                            },
                        shape = RoundedCornerShape(14.dp)
                    ) {
                        Text("Нет", fontWeight = FontWeight.SemiBold)
                    }

                    val confirmDialogSource = remember { MutableInteractionSource() }
                    val confirmDialogScale = rememberPressScale(confirmDialogSource, 0.94f)
                    Button(
                        onClick = {
                            confirmation.onConfirm()
                            onDismiss()
                        },
                        interactionSource = confirmDialogSource,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = if (confirmation.isDestructive) {
                                MaterialTheme.colorScheme.error
                            } else {
                                MaterialTheme.colorScheme.primary
                            }
                        ),
                        modifier = Modifier
                            .weight(1f)
                            .height(46.dp)
                            .graphicsLayer {
                                scaleX = confirmDialogScale
                                scaleY = confirmDialogScale
                            },
                        shape = RoundedCornerShape(14.dp)
                    ) {
                        Text("Да", color = Color.White, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
}
