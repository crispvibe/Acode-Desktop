package com.codevoke.android.ui.screens

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.InsertDriveFile
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.CameraAlt
import androidx.compose.material.icons.rounded.ChatBubble
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.Memory
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.SmartToy
import androidx.compose.material.icons.rounded.AttachFile
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.codevoke.android.data.RemoteChatAttachment
import com.codevoke.android.data.RemoteChatMessage
import com.codevoke.android.data.RemoteComposer
import com.codevoke.android.data.RemoteFileEntry
import com.codevoke.android.data.RemoteInteractiveRequest
import com.codevoke.android.data.RemoteModel
import com.codevoke.android.data.RemoteProject
import com.codevoke.android.data.RemoteQueuedRequest
import com.codevoke.android.data.RemoteSession
import com.codevoke.android.data.RemoteStreamingText
import com.codevoke.android.ui.components.CodevokeGlassCard
import com.codevoke.android.ui.components.CodevokeIconButton
import com.codevoke.android.ui.components.CodevokeSoftGlass
import com.codevoke.android.ui.components.StatusDot
import com.codevoke.android.ui.theme.CodevokeColor
import com.codevoke.android.ui.theme.CodevokeRadius
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.util.Locale

@Composable
fun ChatScreen(
    connectionStatus: String,
    runtimeStatus: String,
    transportLabel: String,
    topTitle: String,
    messages: List<RemoteChatMessage>,
    streamingTexts: List<RemoteStreamingText>,
    projects: List<RemoteProject>,
    models: List<RemoteModel>,
    sessions: List<RemoteSession>,
    files: List<RemoteFileEntry>,
    lastError: String?,
    fileError: String?,
    isRefreshing: Boolean,
    isLoadingHistory: Boolean,
    isAwaitingFirstModelOutput: Boolean,
    isLoadingFiles: Boolean,
    currentFilePath: String,
    parentFilePath: String?,
    selectedProjectId: String?,
    selectedSessionId: String?,
    selectedModelId: String,
    composer: RemoteComposer,
    attachments: List<RemoteChatAttachment>,
    queuedRequests: List<RemoteQueuedRequest>,
    isUploadingAttachment: Boolean,
    inputText: String,
    openSettings: () -> Unit,
    refresh: () -> Unit,
    selectProject: (RemoteProject) -> Unit,
    selectModel: (RemoteModel) -> Unit,
    selectSession: (RemoteSession) -> Unit,
    newChat: () -> Unit,
    updateInput: (String) -> Unit,
    sendMessage: () -> Unit,
    stopGeneration: () -> Unit,
    uploadAttachment: (String, ByteArray, String, String?) -> Unit,
    removeAttachment: (String) -> Unit,
    setCLI: (String) -> Unit,
    setPermissionMode: (String) -> Unit,
    setReasoningEffort: (String) -> Unit,
    cancelQueued: (String) -> Unit,
    flushQueue: () -> Unit,
    editQueued: (String, String) -> Unit,
    respondPermission: (String, String) -> Unit,
    respondInteractive: (String, List<String>, String?) -> Unit,
    requestSnapshot: () -> Unit,
    insertPath: (String) -> Unit,
    openFile: (RemoteFileEntry) -> Unit,
    openParentDirectory: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var sidebarVisible by remember { mutableStateOf(false) }
    val selectedSession = sessions.firstOrNull { it.id == selectedSessionId }
    val hasActiveRun = selectedSession?.runStatus?.isActiveRunStatus() == true
    val canUseComposer = selectedProjectId != null && connectionStatus == "已连接"
    val cameraLauncher = rememberLauncherForActivityResult(ActivityResultContracts.TakePicturePreview()) { bitmap ->
        bitmap ?: return@rememberLauncherForActivityResult
        scope.launch {
            val prepared = prepareBitmapAttachment(bitmap)
            uploadAttachment(prepared.filename, prepared.data, prepared.kind, prepared.thumbnailData)
        }
    }
    val imagePickerLauncher = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(5)) { uris ->
        uris.forEach { uri ->
            scope.launch {
                prepareUriAttachment(context, uri, imageHint = true)?.let { prepared ->
                    uploadAttachment(prepared.filename, prepared.data, prepared.kind, prepared.thumbnailData)
                }
            }
        }
    }
    val filePickerLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        uris.forEach { uri ->
            scope.launch {
                prepareUriAttachment(context, uri, imageHint = false)?.let { prepared ->
                    uploadAttachment(prepared.filename, prepared.data, prepared.kind, prepared.thumbnailData)
                }
            }
        }
    }
    BackHandler(enabled = true) {
        if (sidebarVisible) {
            sidebarVisible = false
        }
    }

    Box(Modifier.fillMaxSize()) {
        com.codevoke.android.ui.components.WhiteGlassBackground(Modifier.fillMaxSize())
        Column(Modifier.fillMaxSize()) {
            ChatTopChrome(
                title = topTitle,
                status = connectionStatus,
                transportLabel = transportLabel,
                openSettings = openSettings,
                refresh = refresh,
                isRefreshing = isRefreshing,
            )
            ChatStatusStrip(
                connectionStatus = connectionStatus,
                runtimeStatus = runtimeStatus,
                isRefreshing = isRefreshing,
                isLoadingHistory = isLoadingHistory,
                isAwaitingFirstModelOutput = isAwaitingFirstModelOutput,
                lastError = lastError,
            )
            MessageList(
                messages = messages,
                streamingTexts = streamingTexts,
                modifier = Modifier.weight(1f),
                onEditMessage = updateInput,
                respondPermission = respondPermission,
                respondInteractive = respondInteractive,
            )
            QueueStrip(
                queuedRequests = queuedRequests,
                queuedCount = selectedSession?.queuedCount ?: queuedRequests.size,
                cancelQueued = cancelQueued,
                flushQueue = flushQueue,
                editQueued = editQueued,
                requestSnapshot = requestSnapshot,
            )
            InputChrome(
                text = inputText,
                enabled = canUseComposer,
                activeRun = hasActiveRun,
                composer = composer,
                models = models,
                attachments = attachments,
                isUploadingAttachment = isUploadingAttachment,
                onTextChange = updateInput,
                send = sendMessage,
                stop = stopGeneration,
                takePhoto = { cameraLauncher.launch(null) },
                selectImage = {
                    imagePickerLauncher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                },
                selectFile = { filePickerLauncher.launch(arrayOf("*/*")) },
                removeAttachment = removeAttachment,
                setCLI = setCLI,
                setPermissionMode = setPermissionMode,
                setReasoningEffort = setReasoningEffort,
            )
        }

        AnimatedVisibility(
            visible = sidebarVisible,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            var closeDragDistance by remember { mutableStateOf(0f) }
            Box(
                Modifier
                    .fillMaxSize()
                    .systemGestureExclusion()
                    .pointerInput(Unit) {
                        detectHorizontalDragGestures(
                            onDragStart = { closeDragDistance = 0f },
                            onHorizontalDrag = { change, dragAmount ->
                                if (dragAmount < 0f) {
                                    change.consume()
                                    closeDragDistance += -dragAmount
                                }
                            },
                            onDragEnd = {
                                if (closeDragDistance > 56f) sidebarVisible = false
                                closeDragDistance = 0f
                            },
                            onDragCancel = { closeDragDistance = 0f },
                        )
                    }
                    .background(Color.Black.copy(alpha = 0.24f))
                    .clickable { sidebarVisible = false }
            )
        }

        AnimatedVisibility(
            visible = sidebarVisible,
            enter = slideInHorizontally(animationSpec = tween(durationMillis = 320)) { -it },
            exit = slideOutHorizontally(animationSpec = tween(durationMillis = 240)) { -it },
        ) {
            SidebarOverlay(
                projects = projects,
                models = models,
                sessions = sessions,
                files = files,
                fileError = fileError,
                isLoadingFiles = isLoadingFiles,
                selectedProjectId = selectedProjectId,
                selectedSessionId = selectedSessionId,
                selectedModelId = selectedModelId,
                currentFilePath = currentFilePath,
                parentFilePath = parentFilePath,
                selectProject = { selected ->
                    selectProject(selected)
                    sidebarVisible = false
                },
                selectModel = { selected ->
                    selectModel(selected)
                    sidebarVisible = false
                },
                selectSession = { selected ->
                    selectSession(selected)
                    sidebarVisible = false
                },
                newChat = {
                    newChat()
                    sidebarVisible = false
                },
                insertPath = insertPath,
                openFile = openFile,
                openParentDirectory = openParentDirectory,
            )
        }

        Box(
            Modifier
                .width(32.dp)
                .fillMaxHeight()
                .statusBarsPadding()
                .padding(top = 64.dp)
                .align(Alignment.BottomStart)
                .systemGestureExclusion()
                .pointerInput(sidebarVisible) {
                    var openDragDistance = 0f
                    detectHorizontalDragGestures(
                        onDragStart = { openDragDistance = 0f },
                        onHorizontalDrag = { change, dragAmount ->
                            if (!sidebarVisible && dragAmount > 0f) {
                                change.consume()
                                openDragDistance += dragAmount
                                if (openDragDistance > 48f) sidebarVisible = true
                            }
                        },
                        onDragEnd = {
                            if (!sidebarVisible && openDragDistance > 32f) sidebarVisible = true
                            openDragDistance = 0f
                        },
                        onDragCancel = { openDragDistance = 0f },
                    )
                }
                .clickable { sidebarVisible = true }
        )
    }
}

@Composable
private fun ChatTopChrome(title: String, status: String, transportLabel: String, openSettings: () -> Unit, refresh: () -> Unit, isRefreshing: Boolean) {
    val chromeShape = RoundedCornerShape(bottomStart = CodevokeRadius.Chrome, bottomEnd = CodevokeRadius.Chrome)
    Box(
        Modifier
            .fillMaxWidth()
            .shadow(18.dp, chromeShape, ambientColor = Color.Black.copy(alpha = 0.06f), spotColor = Color.Black.copy(alpha = 0.06f))
            .clip(chromeShape)
            .background(Color.White.copy(alpha = 0.66f))
            .border(1.dp, CodevokeColor.Line, chromeShape)
            .statusBarsPadding()
            .padding(horizontal = 4.dp, vertical = 6.dp)
            .height(56.dp)
    ) {
        Column(
            modifier = Modifier
                .align(Alignment.Center)
                .padding(horizontal = 72.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            Text(title, color = CodevokeColor.Ink, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                StatusDot(online = status == "已连接", modifier = Modifier.size(8.dp))
                val statusText = if (status == "已连接" && transportLabel.isNotBlank()) "$status · $transportLabel" else status
                Text(statusText, color = CodevokeColor.Muted, fontSize = 11.sp, fontWeight = FontWeight.Medium)
            }
        }
        CodevokeIconButton(
            imageVector = Icons.Rounded.Settings,
            contentDescription = "设置",
            size = 44.dp,
            iconSize = 21.dp,
            modifier = Modifier.align(Alignment.CenterStart),
            onClick = openSettings,
        )
        CodevokeIconButton(
            imageVector = Icons.Rounded.Refresh,
            contentDescription = "刷新",
            size = 44.dp,
            iconSize = 21.dp,
            modifier = Modifier.align(Alignment.CenterEnd),
            enabled = !isRefreshing,
            onClick = refresh,
        )
    }
}

@Composable
private fun ChatStatusStrip(
    connectionStatus: String,
    runtimeStatus: String,
    isRefreshing: Boolean,
    isLoadingHistory: Boolean,
    isAwaitingFirstModelOutput: Boolean,
    lastError: String?,
) {
    val (title, subtitle, icon, loading) = when {
        lastError != null -> StatusStripContent("连接遇到问题", lastError, Icons.Rounded.ErrorOutline, false)
        isRefreshing -> StatusStripContent("正在刷新", "同步项目、会话和文件状态。", Icons.Rounded.Refresh, true)
        connectionStatus == "连接中" -> StatusStripContent("正在连接", "正在建立远程聊天通道。", Icons.Rounded.Refresh, true)
        connectionStatus != "已连接" -> StatusStripContent("未连接", "连接远程设备后才能发送消息。", Icons.Rounded.ErrorOutline, false)
        isLoadingHistory -> StatusStripContent("正在加载会话", "同步电脑端历史消息。", Icons.Rounded.Refresh, true)
        isAwaitingFirstModelOutput -> StatusStripContent("等待模型输出", "消息已发送，正在等待电脑端返回首段内容。", Icons.Rounded.Refresh, true)
        runtimeStatus.isNotBlank() && runtimeStatus.lowercase(Locale.ROOT) != "idle" -> StatusStripContent("电脑端状态", runtimeStatus, Icons.Rounded.Refresh, false)
        else -> null
    } ?: return

    CodevokeGlassCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 8.dp),
        corner = 22.dp,
        fill = Color.White.copy(alpha = 0.72f),
        shadowAlpha = 0.035f,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (loading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                    color = CodevokeColor.Ink,
                    trackColor = CodevokeColor.Line,
                )
            } else {
                Icon(icon, contentDescription = null, tint = CodevokeColor.Muted, modifier = Modifier.size(19.dp))
            }
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, color = CodevokeColor.Ink, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text(subtitle, color = CodevokeColor.Muted, fontSize = 12.sp, lineHeight = 17.sp)
            }
        }
    }
}

private data class StatusStripContent(
    val title: String,
    val subtitle: String,
    val icon: ImageVector,
    val loading: Boolean,
)

@Composable
private fun MessageList(
    messages: List<RemoteChatMessage>,
    streamingTexts: List<RemoteStreamingText>,
    modifier: Modifier = Modifier,
    onEditMessage: (String) -> Unit,
    respondPermission: (String, String) -> Unit,
    respondInteractive: (String, List<String>, String?) -> Unit,
) {
    val listState = rememberLazyListState()
    val visibleMessages = remember(messages) { messages.filterNot { it.shouldHideMessage() } }
    val streamingByMessageId = remember(streamingTexts) { streamingTexts.associateBy { it.messageId } }
    val streamingSignature = remember(streamingTexts) {
        streamingTexts.joinToString("|") { "${it.messageId}:${it.text.length}:${it.status}" }
    }
    LaunchedEffect(visibleMessages.size, visibleMessages.lastOrNull()?.id, streamingSignature) {
        if (visibleMessages.isNotEmpty()) {
            listState.animateScrollToItem(visibleMessages.lastIndex)
        }
    }
    LazyColumn(
        state = listState,
        modifier = modifier.fillMaxWidth(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        if (visibleMessages.isEmpty()) {
            item {
                CodevokeGlassCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 220.dp),
                    corner = 28.dp,
                    fill = Color.White.copy(alpha = 0.78f),
                    shadowAlpha = 0.05f,
                ) {
                    Column(
                        modifier = Modifier.padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(Icons.Rounded.SmartToy, contentDescription = null, tint = CodevokeColor.Ink, modifier = Modifier.size(26.dp))
                        Text("准备开始远程对话", color = CodevokeColor.Ink, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                        Text(
                            "选择项目后，底部输入框会把消息发送到电脑端 Codevoke。",
                            color = CodevokeColor.Muted,
                            fontSize = 13.sp,
                            lineHeight = 20.sp,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
            }
        } else {
            items(visibleMessages, key = { it.id }) { message ->
                MessageBubble(
                    message = message,
                    streamingText = streamingByMessageId[message.id]?.text,
                    onEditMessage = onEditMessage,
                    respondPermission = respondPermission,
                    respondInteractive = respondInteractive,
                )
            }
        }
    }
}

@Composable
private fun MessageBubble(
    message: RemoteChatMessage,
    streamingText: String?,
    onEditMessage: (String) -> Unit,
    respondPermission: (String, String) -> Unit,
    respondInteractive: (String, List<String>, String?) -> Unit,
) {
    val clipboard = LocalClipboardManager.current
    val displayText = streamingText?.takeIf { it.isNotBlank() } ?: message.text
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = if (message.fromUser) Alignment.End else Alignment.Start,
    ) {
        if (message.kind == "reasoning") {
            Row(
                modifier = Modifier.padding(bottom = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(Icons.Rounded.SmartToy, contentDescription = null, tint = CodevokeColor.Muted.copy(alpha = 0.62f), modifier = Modifier.size(16.dp))
                Text(displayText, color = CodevokeColor.Muted.copy(alpha = 0.74f), fontSize = 15.sp, lineHeight = 25.sp)
            }
            return
        }
        if (message.kind == "permissionRequest") {
            PermissionRequestCard(message = message, respondPermission = respondPermission)
            return
        }
        if (message.kind == "interactiveRequest" || message.interactiveRequest != null || message.interactive != null) {
            InteractiveRequestCard(message = message, respondInteractive = respondInteractive)
            return
        }
        if (message.kind in operationalMessageKinds) {
            OperationalMessageCard(message = message)
            return
        }
        if (message.fromUser) {
            Column(
                modifier = Modifier
                    .clip(RoundedCornerShape(23.dp))
                    .background(Color.Black)
                    .padding(horizontal = 18.dp, vertical = 11.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (displayText.isNotBlank()) {
                    Text(
                        text = displayText,
                        color = Color.White,
                        fontSize = 15.5.sp,
                        lineHeight = 23.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                MessageAttachmentStrip(attachments = message.attachments, dark = true)
            }
            Row(
                modifier = Modifier.padding(top = 7.dp, end = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Icon(
                    Icons.Rounded.ContentCopy,
                        contentDescription = "复制消息",
                        tint = CodevokeColor.Muted.copy(alpha = 0.78f),
                        modifier = Modifier
                            .size(17.dp)
                            .clip(CircleShape)
                        .clickable { clipboard.setText(AnnotatedString(displayText)) },
                )
                Icon(
                    Icons.Rounded.Edit,
                    contentDescription = "编辑消息",
                        tint = CodevokeColor.Muted.copy(alpha = 0.78f),
                        modifier = Modifier
                            .size(17.dp)
                            .clip(CircleShape)
                        .clickable { onEditMessage(displayText) },
                )
            }
        } else {
            val isError = message.kind == "error" || message.status == "error"
            CodevokeSoftGlass(
                modifier = Modifier.fillMaxWidth(0.92f),
                shape = RoundedCornerShape(22.dp),
                fill = if (isError) Color(0xFFFFF2F2).copy(alpha = 0.84f) else Color.White.copy(alpha = 0.42f),
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(7.dp),
                ) {
                    MessageMetaRow(
                        title = when (message.kind) {
                            "error" -> "错误"
                            "system" -> "系统"
                            else -> "助手"
                        },
                        status = message.status,
                    )
                    Text(
                        text = displayText.ifBlank { if (message.isStreaming) "正在生成..." else "" },
                        color = if (isError) Color(0xFFB3261E) else CodevokeColor.Ink,
                        fontSize = 15.5.sp,
                        lineHeight = 24.sp,
                    )
                    MessageAttachmentStrip(attachments = message.attachments, dark = false)
                }
            }
        }
    }
}

private val operationalMessageKinds = setOf("toolCall", "toolResult", "command", "commandOutput", "diff", "result", "rawOutput")

@Composable
private fun PendingAttachmentStrip(
    attachments: List<RemoteChatAttachment>,
    uploading: Boolean,
    removeAttachment: (String) -> Unit,
) {
    if (attachments.isEmpty() && !uploading) return
    CodevokeSoftGlass(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        fill = Color.White.copy(alpha = 0.56f),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 10.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            attachments.forEach { attachment ->
                AttachmentChip(attachment = attachment, removable = true, dark = false, removeAttachment = removeAttachment)
            }
            if (uploading) {
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(Color.White.copy(alpha = 0.62f))
                        .padding(horizontal = 10.dp, vertical = 7.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        strokeWidth = 2.dp,
                        color = CodevokeColor.Ink,
                        trackColor = CodevokeColor.Line,
                    )
                    Text("上传中", color = CodevokeColor.Ink, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun MessageAttachmentStrip(attachments: List<RemoteChatAttachment>, dark: Boolean) {
    if (attachments.isEmpty()) return
    Row(
        modifier = Modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        attachments.forEach { attachment ->
            AttachmentChip(attachment = attachment, removable = false, dark = dark, removeAttachment = {})
        }
    }
}

@Composable
private fun AttachmentChip(
    attachment: RemoteChatAttachment,
    removable: Boolean,
    dark: Boolean,
    removeAttachment: (String) -> Unit,
) {
    val foreground = if (dark) Color.White else CodevokeColor.Ink
    val muted = if (dark) Color.White.copy(alpha = 0.72f) else CodevokeColor.Muted
    Row(
        modifier = Modifier
            .height(36.dp)
            .clip(RoundedCornerShape(999.dp))
            .background(if (dark) Color.White.copy(alpha = 0.16f) else Color.White.copy(alpha = 0.62f))
            .padding(start = 8.dp, end = if (removable) 6.dp else 10.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AttachmentThumbnail(attachment = attachment, dark = dark)
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                attachment.filename.ifBlank { if (attachment.kind == "image") "图片" else "附件" },
                color = foreground,
                fontSize = 11.5.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 132.dp),
            )
            if (attachment.sizeBytes > 0) {
                Text(formatBytes(attachment.sizeBytes), color = muted, fontSize = 10.sp, maxLines = 1)
            }
        }
        if (removable) {
            Icon(
                Icons.Rounded.Close,
                contentDescription = "移除附件",
                tint = CodevokeColor.Muted,
                modifier = Modifier
                    .size(18.dp)
                    .clip(CircleShape)
                    .clickable { removeAttachment(attachment.id) }
                    .padding(2.dp),
            )
        }
    }
}

@Composable
private fun AttachmentThumbnail(attachment: RemoteChatAttachment, dark: Boolean) {
    val thumbnail = remember(attachment.thumbnailData) {
        runCatching {
            val encoded = attachment.thumbnailData ?: return@remember null
            val bytes = Base64.decode(encoded, Base64.DEFAULT)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
        }.getOrNull()
    }
    Box(
        modifier = Modifier
            .size(24.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (dark) Color.White.copy(alpha = 0.18f) else Color.White.copy(alpha = 0.76f)),
        contentAlignment = Alignment.Center,
    ) {
        if (thumbnail != null) {
            androidx.compose.foundation.Image(
                bitmap = thumbnail,
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Icon(
                if (attachment.kind == "image") Icons.Rounded.Image else Icons.AutoMirrored.Rounded.InsertDriveFile,
                contentDescription = null,
                tint = if (dark) Color.White else CodevokeColor.Muted,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun MessageMetaRow(title: String, status: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, color = CodevokeColor.Muted, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold)
        if (status.isNotBlank()) {
            Text("·", color = CodevokeColor.Muted.copy(alpha = 0.5f), fontSize = 11.sp)
            Text(status, color = CodevokeColor.Muted.copy(alpha = 0.78f), fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun PermissionRequestCard(message: RemoteChatMessage, respondPermission: (String, String) -> Unit) {
    val requestId = message.requestID.orEmpty()
    val waiting = message.status.isBlank() || message.status == "waiting"
    CodevokeSoftGlass(
        modifier = Modifier.fillMaxWidth(0.94f),
        shape = RoundedCornerShape(20.dp),
        fill = Color.White.copy(alpha = 0.64f),
    ) {
        Column(
            modifier = Modifier.padding(13.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            MessageMetaRow(title = message.title.ifBlank { "需要权限" }, status = message.status)
            Text(message.text, color = CodevokeColor.Ink, fontSize = 13.5.sp, lineHeight = 20.sp)
            if (waiting && requestId.isNotBlank()) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CompactActionButton("拒绝") { respondPermission(requestId, "deny") }
                    CompactActionButton("允许") { respondPermission(requestId, "allow") }
                    CompactActionButton("本会话允许", dark = true) { respondPermission(requestId, "allowForSession") }
                }
            }
        }
    }
}

@Composable
private fun InteractiveRequestCard(
    message: RemoteChatMessage,
    respondInteractive: (String, List<String>, String?) -> Unit,
) {
    val request = message.interactiveRequest ?: message.interactive ?: RemoteInteractiveRequest(
        id = message.requestID.orEmpty(),
        title = message.title,
        prompt = message.text,
    )
    var selectedOptionId by remember(request.id) { mutableStateOf(request.options.firstOrNull()?.id.orEmpty()) }
    var customText by remember(request.id) { mutableStateOf("") }
    val waiting = request.status == "waiting" || message.status.isBlank() || message.status == "waiting"

    CodevokeSoftGlass(
        modifier = Modifier.fillMaxWidth(0.94f),
        shape = RoundedCornerShape(20.dp),
        fill = Color.White.copy(alpha = 0.64f),
    ) {
        Column(
            modifier = Modifier.padding(13.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            MessageMetaRow(title = request.title.ifBlank { "需要选择" }, status = if (waiting) "waiting" else request.status)
            Text(
                request.prompt.ifBlank { message.text },
                color = CodevokeColor.Ink,
                fontSize = 13.5.sp,
                lineHeight = 20.sp,
            )
            if (waiting) {
                request.options.forEach { option ->
                    OptionChip(
                        text = option.label,
                        subtitle = option.detail,
                        selected = selectedOptionId == option.id,
                        enabled = true,
                        onClick = { selectedOptionId = option.id },
                    )
                }
                if (request.allowCustomInput || request.options.isEmpty()) {
                    TextField(
                        value = customText,
                        onValueChange = { customText = it },
                        placeholder = { Text(request.placeholder.ifBlank { "输入回复" }, color = CodevokeColor.Muted.copy(alpha = 0.44f), fontSize = 13.sp) },
                        colors = TextFieldDefaults.colors(
                            focusedContainerColor = Color.White.copy(alpha = 0.42f),
                            unfocusedContainerColor = Color.White.copy(alpha = 0.42f),
                            disabledContainerColor = Color.Transparent,
                            focusedIndicatorColor = Color.Transparent,
                            unfocusedIndicatorColor = Color.Transparent,
                            disabledIndicatorColor = Color.Transparent,
                        ),
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CompactActionButton("取消") { respondInteractive(request.id, emptyList(), null) }
                    CompactActionButton("提交", dark = true) {
                        val selected = selectedOptionId.takeIf { it.isNotBlank() }?.let { listOf(it) }.orEmpty()
                        respondInteractive(request.id, selected, customText.trim().ifBlank { null })
                    }
                }
            }
        }
    }
}

@Composable
private fun OperationalMessageCard(message: RemoteChatMessage) {
    val label = when (message.kind) {
        "toolCall" -> "工具调用"
        "toolResult" -> "工具结果"
        "command" -> "命令"
        "commandOutput" -> "命令输出"
        "diff" -> "变更"
        "result" -> "结果"
        "rawOutput" -> "原始输出"
        else -> message.kind
    }
    CodevokeSoftGlass(
        modifier = Modifier.fillMaxWidth(0.94f),
        shape = RoundedCornerShape(18.dp),
        fill = Color.White.copy(alpha = 0.58f),
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            MessageMetaRow(title = message.title.ifBlank { label }, status = message.status)
            if (message.subtitle.isNotBlank()) {
                Text(message.subtitle, color = CodevokeColor.Muted, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            Text(
                message.text.ifBlank { label },
                color = CodevokeColor.Ink.copy(alpha = 0.84f),
                fontSize = 12.5.sp,
                lineHeight = 18.sp,
            )
        }
    }
}

@Composable
private fun QueueStrip(
    queuedRequests: List<RemoteQueuedRequest>,
    queuedCount: Int,
    cancelQueued: (String) -> Unit,
    flushQueue: () -> Unit,
    editQueued: (String, String) -> Unit,
    requestSnapshot: () -> Unit,
) {
    if (queuedRequests.isEmpty() && queuedCount <= 0) return
    CodevokeGlassCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 2.dp),
        corner = 22.dp,
        fill = Color.White.copy(alpha = 0.72f),
        shadowAlpha = 0.035f,
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("队列 ${if (queuedRequests.isNotEmpty()) queuedRequests.size else queuedCount}", color = CodevokeColor.Ink, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.weight(1f))
                CompactActionButton("同步") { requestSnapshot() }
                CompactActionButton("清空", dark = true) { flushQueue() }
            }
            if (queuedRequests.isEmpty()) {
                Text("Mac 端报告有等待请求，点同步拉取最新队列详情。", color = CodevokeColor.Muted, fontSize = 12.sp, lineHeight = 18.sp)
            } else {
                queuedRequests.take(3).forEach { request ->
                    QueuedRequestRow(request = request, cancelQueued = cancelQueued, editQueued = editQueued)
                }
            }
        }
    }
}

@Composable
private fun QueuedRequestRow(
    request: RemoteQueuedRequest,
    cancelQueued: (String) -> Unit,
    editQueued: (String, String) -> Unit,
) {
    var editing by remember(request.id) { mutableStateOf(false) }
    var text by remember(request.id, request.text) { mutableStateOf(request.text) }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White.copy(alpha = 0.42f))
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            request.displayText.ifBlank { request.text },
            color = CodevokeColor.Ink,
            fontSize = 12.5.sp,
            lineHeight = 18.sp,
            maxLines = if (editing) Int.MAX_VALUE else 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text("${request.cli} · ${request.permissionMode} · ${request.reasoningEffort}", color = CodevokeColor.Muted, fontSize = 11.sp)
        if (editing) {
            TextField(
                value = text,
                onValueChange = { text = it },
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.White.copy(alpha = 0.5f),
                    unfocusedContainerColor = Color.White.copy(alpha = 0.5f),
                    disabledContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    disabledIndicatorColor = Color.Transparent,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CompactActionButton(if (editing) "保存" else "编辑", dark = editing) {
                if (editing) editQueued(request.id, text)
                editing = !editing
            }
            CompactActionButton("取消") { cancelQueued(request.id) }
        }
    }
}

@Composable
private fun ComposerOptionsBar(
    composer: RemoteComposer,
    models: List<RemoteModel>,
    enabled: Boolean,
    setCLI: (String) -> Unit,
    setPermissionMode: (String) -> Unit,
    setReasoningEffort: (String) -> Unit,
) {
    val cliOptions = (models.map { it.cli }.filter { it.isNotBlank() } + composer.cli)
        .distinct()
        .ifEmpty { listOf("claude") }
    CodevokeSoftGlass(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(22.dp),
        fill = Color.White.copy(alpha = 0.56f),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 9.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OptionRow("CLI", cliOptions.map { it to it }, composer.cli, enabled, setCLI)
            OptionRow("权限", permissionModeOptions, composer.permissionMode, enabled, setPermissionMode)
            OptionRow("推理", reasoningEffortOptions, composer.reasoningEffort, enabled, setReasoningEffort)
        }
    }
}

@Composable
private fun OptionRow(
    title: String,
    options: List<Pair<String, String>>,
    selectedValue: String,
    enabled: Boolean,
    onSelect: (String) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, color = CodevokeColor.Muted, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(34.dp))
        options.forEach { (value, label) ->
            CompactPill(
                text = label,
                selected = value == selectedValue,
                enabled = enabled,
                onClick = { onSelect(value) },
            )
        }
    }
}

@Composable
private fun OptionChip(text: String, subtitle: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(if (selected) Color.Black else Color.White.copy(alpha = 0.42f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(text, color = if (selected) Color.White else CodevokeColor.Ink, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        if (subtitle.isNotBlank()) {
            Text(subtitle, color = if (selected) Color.White.copy(alpha = 0.72f) else CodevokeColor.Muted, fontSize = 11.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun CompactPill(text: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Text(
        text = text,
        color = if (selected) Color.White else CodevokeColor.Ink,
        fontSize = 11.5.sp,
        fontWeight = FontWeight.SemiBold,
        maxLines = 1,
        modifier = Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(if (selected) Color.Black else Color.White.copy(alpha = 0.5f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 9.dp, vertical = 6.dp),
    )
}

@Composable
private fun CompactActionButton(text: String, dark: Boolean = false, onClick: () -> Unit) {
    if (dark) {
        Button(
            onClick = onClick,
            colors = ButtonDefaults.buttonColors(containerColor = Color.Black, contentColor = Color.White),
            shape = RoundedCornerShape(999.dp),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
            modifier = Modifier.height(32.dp),
        ) {
            Text(text, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold)
        }
    } else {
        TextButton(
            onClick = onClick,
            colors = ButtonDefaults.textButtonColors(contentColor = CodevokeColor.Ink),
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 0.dp),
            modifier = Modifier.height(32.dp),
        ) {
            Text(text, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

private val permissionModeOptions = listOf(
    "ask" to "询问",
    "autoEdit" to "自动",
    "fullAccess" to "完全",
)

private val reasoningEffortOptions = listOf(
    "low" to "低",
    "medium" to "中",
    "high" to "高",
    "xhigh" to "极高",
    "max" to "最大",
)

private data class PreparedAttachment(
    val filename: String,
    val data: ByteArray,
    val kind: String,
    val thumbnailData: String?,
)

private suspend fun prepareUriAttachment(context: Context, uri: Uri, imageHint: Boolean): PreparedAttachment? = withContext(Dispatchers.IO) {
    val resolver = context.contentResolver
    val name = displayName(context, uri) ?: "attachment"
    val raw = resolver.openInputStream(uri)?.use { it.readBytes() } ?: return@withContext null
    val isImage = imageHint || isImageFilename(name)
    if (!isImage) {
        return@withContext PreparedAttachment(filename = name, data = raw, kind = "file", thumbnailData = null)
    }
    val uploadBytes = compressedImageBytes(raw, maxEdge = 2_000, quality = 88) ?: raw
    PreparedAttachment(
        filename = normalizedImageFilename(name),
        data = uploadBytes,
        kind = "image",
        thumbnailData = thumbnailBase64(raw),
    )
}

private suspend fun prepareBitmapAttachment(bitmap: Bitmap): PreparedAttachment = withContext(Dispatchers.Default) {
    val data = bitmap.toJpegBytes(quality = 88)
    PreparedAttachment(
        filename = "photo-${System.currentTimeMillis()}.jpg",
        data = data,
        kind = "image",
        thumbnailData = thumbnailBase64(data),
    )
}

private fun displayName(context: Context, uri: Uri): String? {
    val resolver = context.contentResolver
    val fromCursor = runCatching {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) cursor.getString(index) else null
            } else {
                null
            }
        }
    }.getOrNull()
    return fromCursor?.takeIf { it.isNotBlank() } ?: uri.lastPathSegment?.substringAfterLast('/')
}

private fun isImageFilename(filename: String): Boolean {
    val lower = filename.lowercase(Locale.ROOT)
    return lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".png") || lower.endsWith(".webp") || lower.endsWith(".gif")
}

private fun normalizedImageFilename(filename: String): String {
    val trimmed = filename.trim().ifBlank { "image.jpg" }
    return if (trimmed.contains('.')) trimmed else "$trimmed.jpg"
}

private fun compressedImageBytes(data: ByteArray, maxEdge: Int, quality: Int): ByteArray? {
    val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size) ?: return null
    val scaled = bitmap.scaledToMaxEdge(maxEdge)
    return scaled.toJpegBytes(quality)
}

private fun thumbnailBase64(data: ByteArray): String? {
    val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size) ?: return null
    val thumbnail = bitmap.scaledToMaxEdge(360).toJpegBytes(quality = 72)
    return Base64.encodeToString(thumbnail, Base64.NO_WRAP)
}

private fun Bitmap.scaledToMaxEdge(maxEdge: Int): Bitmap {
    val largest = width.coerceAtLeast(height)
    if (largest <= maxEdge) return this
    val scale = maxEdge.toFloat() / largest.toFloat()
    val nextWidth = (width * scale).toInt().coerceAtLeast(1)
    val nextHeight = (height * scale).toInt().coerceAtLeast(1)
    return Bitmap.createScaledBitmap(this, nextWidth, nextHeight, true)
}

private fun Bitmap.toJpegBytes(quality: Int): ByteArray {
    val output = ByteArrayOutputStream()
    compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), output)
    return output.toByteArray()
}

private fun formatBytes(size: Int): String {
    if (size < 1024) return "$size B"
    val kb = size / 1024.0
    if (kb < 1024) return String.format(Locale.ROOT, "%.1f KB", kb)
    return String.format(Locale.ROOT, "%.1f MB", kb / 1024.0)
}

@Composable
private fun InputChrome(
    text: String,
    enabled: Boolean,
    activeRun: Boolean,
    composer: RemoteComposer,
    models: List<RemoteModel>,
    attachments: List<RemoteChatAttachment>,
    isUploadingAttachment: Boolean,
    onTextChange: (String) -> Unit,
    send: () -> Unit,
    stop: () -> Unit,
    takePhoto: () -> Unit,
    selectImage: () -> Unit,
    selectFile: () -> Unit,
    removeAttachment: (String) -> Unit,
    setCLI: (String) -> Unit,
    setPermissionMode: (String) -> Unit,
    setReasoningEffort: (String) -> Unit,
) {
    var attachmentMenuPresented by remember { mutableStateOf(false) }
    val canSend = enabled && !isUploadingAttachment && (text.trim().isNotEmpty() || attachments.isNotEmpty())
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .windowInsetsPadding(WindowInsets.ime.union(WindowInsets.navigationBars))
            .padding(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        ComposerOptionsBar(
            composer = composer,
            models = models,
            enabled = enabled,
            setCLI = setCLI,
            setPermissionMode = setPermissionMode,
            setReasoningEffort = setReasoningEffort,
        )
        PendingAttachmentStrip(
            attachments = attachments,
            uploading = isUploadingAttachment,
            removeAttachment = removeAttachment,
        )
        Box(Modifier.fillMaxWidth()) {
            if (attachmentMenuPresented) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .padding(bottom = 58.dp),
                ) {
                    AttachmentMenu(
                        takePhoto = {
                            attachmentMenuPresented = false
                            takePhoto()
                        },
                        selectImage = {
                            attachmentMenuPresented = false
                            selectImage()
                        },
                        selectFile = {
                            attachmentMenuPresented = false
                            selectFile()
                        },
                    )
                }
            }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            CodevokeIconButton(
                imageVector = Icons.Rounded.AttachFile,
                contentDescription = "附件",
                size = 52.dp,
                iconSize = 19.dp,
                enabled = enabled,
                onClick = { attachmentMenuPresented = !attachmentMenuPresented },
            )
            CodevokeSoftGlass(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 52.dp, max = 150.dp),
                shape = RoundedCornerShape(26.dp),
                fill = CodevokeColor.GlassFill,
            ) {
                TextField(
                    value = text,
                    onValueChange = onTextChange,
                    enabled = enabled,
                    placeholder = {
                        Text(
                            if (enabled) "输入消息..." else "先连接远程设备并选择项目",
                            color = CodevokeColor.Muted.copy(alpha = 0.42f),
                            fontSize = 15.sp,
                        )
                    },
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color.Transparent,
                        unfocusedContainerColor = Color.Transparent,
                        disabledContainerColor = Color.Transparent,
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                        disabledIndicatorColor = Color.Transparent,
                    ),
                    singleLine = false,
                    minLines = 1,
                    maxLines = 5,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            CodevokeIconButton(
                imageVector = if (activeRun) Icons.Rounded.Stop else Icons.Rounded.ArrowUpward,
                contentDescription = if (activeRun) "停止生成" else "发送",
                size = 52.dp,
                iconSize = if (activeRun) 18.dp else 20.dp,
                enabled = activeRun || canSend,
                dark = activeRun || canSend,
                onClick = { if (activeRun) stop() else send() },
            )
        }
        }
    }
}

@Composable
private fun AttachmentMenu(
    takePhoto: () -> Unit,
    selectImage: () -> Unit,
    selectFile: () -> Unit,
) {
    CodevokeSoftGlass(
        shape = RoundedCornerShape(22.dp),
        fill = Color.White.copy(alpha = 0.72f),
    ) {
        Column(
            modifier = Modifier.padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            AttachmentMenuRow("拍照", Icons.Rounded.CameraAlt, takePhoto)
            AttachmentMenuRow("选择图片", Icons.Rounded.Image, selectImage)
            AttachmentMenuRow("选择文件", Icons.AutoMirrored.Rounded.InsertDriveFile, selectFile)
        }
    }
}

@Composable
private fun AttachmentMenuRow(title: String, icon: ImageVector, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .width(132.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White.copy(alpha = 0.42f))
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = CodevokeColor.Ink,
            modifier = Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.76f))
                .padding(6.dp),
        )
        Text(title, color = CodevokeColor.Ink, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun SidebarOverlay(
    projects: List<RemoteProject>,
    models: List<RemoteModel>,
    sessions: List<RemoteSession>,
    files: List<RemoteFileEntry>,
    fileError: String?,
    isLoadingFiles: Boolean,
    selectedProjectId: String?,
    selectedSessionId: String?,
    selectedModelId: String,
    currentFilePath: String,
    parentFilePath: String?,
    selectProject: (RemoteProject) -> Unit,
    selectModel: (RemoteModel) -> Unit,
    selectSession: (RemoteSession) -> Unit,
    newChat: () -> Unit,
    insertPath: (String) -> Unit,
    openFile: (RemoteFileEntry) -> Unit,
    openParentDirectory: () -> Unit,
) {
    val clipboard = LocalClipboardManager.current
    var modelPickerPresented by remember { mutableStateOf(false) }
    val selectedModel = models.firstOrNull { it.id == selectedModelId }

    CodevokeGlassCard(
        modifier = Modifier
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(start = 10.dp, top = 104.dp, bottom = 112.dp)
            .fillMaxWidth(0.72f)
            .widthIn(min = 272.dp, max = 312.dp)
            .fillMaxHeight(),
        corner = CodevokeRadius.Sheet,
        fill = Color.White.copy(alpha = 0.82f),
        shadowAlpha = 0.06f,
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            SidebarSection("项目") {
                if (projects.isEmpty()) {
                    PlaceholderRow("暂无项目", "—", Icons.Rounded.Folder)
                }
                projects.take(5).forEach { project ->
                    ProjectRow(
                        project = project,
                        selected = project.id == selectedProjectId,
                        onClick = { selectProject(project) },
                        copyPath = { clipboard.setText(AnnotatedString(project.path)) },
                    )
                }
            }
            SidebarSection("模型") {
                if (models.isEmpty()) {
                    PlaceholderRow("暂无模型", "—", Icons.Rounded.Memory)
                } else {
                    ModelRow(
                        model = selectedModel ?: models.first(),
                        selected = false,
                        onClick = { modelPickerPresented = !modelPickerPresented },
                    )
                    if (modelPickerPresented) {
                        CodevokeSoftGlass(
                            modifier = Modifier
                                .fillMaxWidth(),
                            shape = RoundedCornerShape(22.dp),
                            fill = Color.White.copy(alpha = 0.72f),
                        ) {
                            Column(
                                modifier = Modifier.padding(8.dp),
                                verticalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                models.forEach { model ->
                                    ModelRow(
                                        model = model,
                                        selected = model.id == selectedModelId,
                                        onClick = {
                                            selectModel(model)
                                            modelPickerPresented = false
                                        },
                                    )
                                }
                            }
                        }
                    }
                }
            }
            SidebarSection("聊天记录", trailing = {
                Icon(
                    Icons.Rounded.Add,
                    contentDescription = null,
                    tint = CodevokeColor.Ink,
                    modifier = Modifier
                        .size(24.dp)
                        .clip(CircleShape)
                        .clickable(onClick = newChat),
                )
            }) {
                if (sessions.isEmpty()) {
                    PlaceholderRow(if (selectedProjectId == null) "选择项目后查看聊天记录" else "暂无聊天", "—", Icons.Rounded.ChatBubble)
                }
                sessions.take(8).forEach { session -> SessionRow(session, selected = session.id == selectedSessionId, onClick = { selectSession(session) }) }
            }
            SidebarSection(if (currentFilePath.isBlank()) "文件" else currentFilePath) {
                when {
                    selectedProjectId == null -> {
                        PlaceholderRow("先选择项目", "选好项目后会显示文件", Icons.Rounded.Folder)
                    }
                    isLoadingFiles -> {
                        LoadingSidebarRow("正在加载文件", "同步当前项目目录。")
                    }
                    files.isEmpty() && fileError != null -> {
                        PlaceholderRow("文件加载失败", fileError, Icons.Rounded.ErrorOutline)
                    }
                    else -> {
                        if (parentFilePath != null) {
                            SidebarRow(Icons.Rounded.Folder, "..", "上一级", selected = false, onClick = openParentDirectory)
                        }
                        if (files.isEmpty()) {
                            PlaceholderRow("空文件夹", "此目录没有可显示的内容", Icons.Rounded.Folder)
                        }
                        files.forEach { file -> FileRow(file, onClick = { if (file.isDirectory) openFile(file) else insertPath(file.relativePath) }) }
                    }
                }
            }
            Spacer(Modifier.height(4.dp))
        }
    }
}

@Composable
private fun PlaceholderRow(title: String, subtitle: String, icon: ImageVector) {
    SidebarRow(icon, title, subtitle, selected = false)
}

@Composable
private fun LoadingSidebarRow(title: String, subtitle: String) {
    SidebarRow(
        icon = Icons.Rounded.Refresh,
        title = title,
        subtitle = subtitle,
        selected = false,
        trailing = {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                strokeWidth = 2.dp,
                color = CodevokeColor.Ink,
                trackColor = CodevokeColor.Line,
            )
        },
    )
}

@Composable
private fun SidebarSection(title: String, trailing: @Composable (() -> Unit)? = null, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(title, color = CodevokeColor.Muted, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Spacer(Modifier.weight(1f))
            trailing?.invoke()
        }
        content()
    }
}

@Composable
private fun ProjectRow(project: RemoteProject, selected: Boolean, onClick: () -> Unit, copyPath: () -> Unit) {
    SidebarRow(
        icon = Icons.Rounded.Folder,
        title = project.name,
        subtitle = project.path,
        selected = selected,
        onClick = onClick,
        trailing = {
            Icon(
                Icons.Rounded.ContentCopy,
                contentDescription = "复制路径",
                tint = if (selected) Color.White.copy(alpha = 0.82f) else CodevokeColor.Muted,
                modifier = Modifier
                    .size(18.dp)
                    .clip(CircleShape)
                    .clickable(onClick = copyPath),
            )
        },
    )
}

@Composable
private fun ModelRow(model: RemoteModel, selected: Boolean, onClick: () -> Unit) {
    SidebarRow(Icons.Rounded.Memory, model.title, model.id, selected = selected, onClick = onClick)
}

@Composable
private fun SessionRow(session: RemoteSession, selected: Boolean, onClick: () -> Unit) {
    SidebarRow(Icons.Rounded.ChatBubble, session.title, session.statusText.ifBlank { session.runStatus.ifBlank { "—" } }, selected = selected, onClick = onClick)
}

@Composable
private fun FileRow(file: RemoteFileEntry, onClick: () -> Unit) {
    SidebarRow(if (file.isDirectory) Icons.Rounded.Folder else Icons.AutoMirrored.Rounded.InsertDriveFile, file.name, if (file.isDirectory) "文件夹" else file.relativePath, selected = false, onClick = onClick)
}

@Composable
private fun SidebarRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    selected: Boolean,
    onClick: (() -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(if (selected) 20.dp else 18.dp))
            .background(if (selected) Color.Black else Color.White.copy(alpha = 0.42f))
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 10.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = if (selected) Color.White else CodevokeColor.Muted, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, color = if (selected) Color.White else CodevokeColor.Ink, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, color = if (selected) Color.White.copy(alpha = 0.65f) else CodevokeColor.Muted, fontSize = 11.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        trailing?.invoke()
    }
}

private fun RemoteChatMessage.shouldHideMessage(): Boolean {
    val cleanedText = if (looksLikeToolInventory(text.trim())) "" else text
    val normalizedText = cleanedText.trim()
    return looksLikeToolInventory(text.trim()) ||
        isProtocolBlob(normalizedText) ||
        shouldHideOperationalMessage(kind = kind, title = title, text = cleanedText)
}

private fun shouldHideOperationalMessage(kind: String, title: String, text: String): Boolean {
    val normalizedKind = kind.lowercase(Locale.ROOT)
    val normalizedTitle = title.trim().lowercase(Locale.ROOT)
    val normalizedText = text.trim().lowercase(Locale.ROOT)
    val operationalKinds = setOf("rawoutput", "toolcall", "toolresult", "diff")
    if (normalizedKind in operationalKinds) {
        val noisePrefixes = listOf(
            "mcpserver/",
            "account/ratelimits",
            "thread/status",
            "thread/tokenusage",
            "remotecontrol/",
            "session/configured",
            "session/connected",
        )
        if (noisePrefixes.any { normalizedTitle.startsWith(it) }) return true
        if ((normalizedTitle.endsWith("/updated") || normalizedTitle.endsWith("/changed")) && normalizedTitle.contains("/")) return true
        val compactTitle = normalizedTitle.compactForNoiseCheck()
        if (compactTitle == "userinput" || compactTitle == "stderr" || compactTitle.contains("usermessage") || compactTitle.contains("reasoning")) return true
        if (normalizedText == "stderr" || normalizedText.contains("\"type\":\"stderr\"") || normalizedText.contains("\"type\": \"stderr\"")) return true
        val compactText = normalizedText.compactForNoiseCheck()
        if (compactText.contains("\"type\":\"usermessage\"") || compactText.contains("\"type\":\"reasoning\"")) return true
        if (normalizedTitle == "changes.diff" && compactText.contains("\"diff\":\"diffgit")) return true
    }
    return normalizedKind == "system" &&
        normalizedTitle == "model" &&
        normalizedText.contains("模型与当前 cli 不匹配")
}

private fun isProtocolBlob(text: String): Boolean {
    if (!text.startsWith("{") || !text.endsWith("}")) return false
    val lower = text.lowercase(Locale.ROOT)
    return lower.contains("\"session_id\"") ||
        lower.contains("\"uuid\"") ||
        lower.contains("\"type\":\"system\"") ||
        lower.contains("\"type\": \"system\"") ||
        lower.contains("\"status\":\"requesting\"") ||
        lower.contains("\"status\": \"requesting\"")
}

private fun looksLikeToolInventory(text: String): Boolean {
    if (text.isBlank()) return false
    val lines = text.lines().map { it.trim().lowercase(Locale.ROOT) }
    val first = lines.firstOrNull { it.isNotBlank() } ?: return false
    val explicitHeader = first == "mac tools:" ||
        first == "tool names:" ||
        first == "mcp servers:" ||
        first == "slash commands:" ||
        Regex("^(mac tools|mcp servers|tool names|slash commands):\\s+\\d+\\s+(connected|available|loaded)$").matches(first)
    if (explicitHeader) return lines.any { it.startsWith("- ") }
    return lines.any { it.startsWith("model:") } &&
        lines.any { it.startsWith("permission:") } &&
        lines.any { it == "tools:" }
}

private fun String.compactForNoiseCheck(): String = replace("_", "")
    .replace("-", "")
    .replace(" ", "")

private fun String.isActiveRunStatus(): Boolean {
    return when (lowercase()) {
        "starting", "streaming", "waitingpermission", "waitinginput", "stopping" -> true
        else -> false
    }
}
