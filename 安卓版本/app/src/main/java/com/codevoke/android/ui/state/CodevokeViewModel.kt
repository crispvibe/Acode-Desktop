package com.codevoke.android.ui.state

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import android.content.Context
import com.codevoke.android.data.RemoteCapability
import com.codevoke.android.data.RemoteChatAttachment
import com.codevoke.android.data.RemoteChatClient
import com.codevoke.android.data.RemoteChatConfig
import com.codevoke.android.data.RemoteComposer
import com.codevoke.android.data.RemoteFileEntry
import com.codevoke.android.data.RemoteInteractiveResponse
import com.codevoke.android.data.RemoteLanClient
import com.codevoke.android.data.RemoteModel
import com.codevoke.android.data.RemotePanelSnapshot
import com.codevoke.android.data.RemoteProject
import com.codevoke.android.data.RemoteQueuedRequest
import com.codevoke.android.data.RemoteSession
import com.codevoke.android.data.RemoteStreamingText
import com.codevoke.android.data.LanNetworkSelector
import com.codevoke.android.data.LanSubnetProbe
import com.codevoke.android.data.applyPatch
import com.codevoke.android.data.toJson
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import org.json.JSONObject
import java.util.UUID

data class DeviceUiState(
    val hosts: List<String> = emptyList(),
    val scanning: Boolean = false,
    val connecting: Boolean = false,
    val manualHost: String = "",
    val manualPort: String = "18765",
    val message: String? = null,
    val connectedHost: String? = null,
    val connectedPort: Int = 18765,
)

data class ChatUiState(
    val config: RemoteChatConfig = RemoteChatConfig(),
    val connectionStatus: String = "未连接",
    val lastError: String? = null,
    val projects: List<RemoteProject> = emptyList(),
    val models: List<RemoteModel> = emptyList(),
    val sessions: List<RemoteSession> = emptyList(),
    val selectedProjectId: String? = null,
    val selectedSessionId: String? = null,
    val selectedModelId: String = "",
    val messages: List<com.codevoke.android.data.RemoteChatMessage> = emptyList(),
    val streamingTexts: List<RemoteStreamingText> = emptyList(),
    val files: List<RemoteFileEntry> = emptyList(),
    val fileError: String? = null,
    val currentFilePath: String = "",
    val parentFilePath: String? = null,
    val inputText: String = "",
    val composer: RemoteComposer = RemoteComposer(),
    val attachments: List<RemoteChatAttachment> = emptyList(),
    val queuedRequests: List<RemoteQueuedRequest> = emptyList(),
    val runtimeStatus: String = "",
    val isAwaitingFirstModelOutput: Boolean = false,
    val isLoadingHistory: Boolean = false,
    val tokensUsed: Int = 0,
    val tokensTotal: Int = 0,
    val isRefreshing: Boolean = false,
    val isLoadingFiles: Boolean = false,
    val isUploadingAttachment: Boolean = false,
    val capabilities: List<RemoteCapability> = emptyList(),
) {
    val selectedProject: RemoteProject? get() = projects.firstOrNull { it.id == selectedProjectId } ?: projects.firstOrNull()
    val filteredSessions: List<RemoteSession> get() = selectedProject?.let { project -> sessions.filter { it.projectId == project.id } } ?: sessions
    val selectedModelTitle: String get() = models.firstOrNull { it.id == selectedModelId }?.title ?: selectedModelId.ifBlank { "默认模型" }
    val canSendDraft: Boolean get() = inputText.trim().isNotEmpty() || attachments.isNotEmpty()
}

private data class PendingRemoteCommand(
    val commandId: String,
    val op: String,
    val sessionId: String?,
    val args: JSONObject,
)

class CodevokeViewModel(application: Application) : AndroidViewModel(application) {
    var devices by mutableStateOf(DeviceUiState())
        private set
    var chat by mutableStateOf(ChatUiState())
        private set
    val transportLabel: String
        get() = if (chat.connectionStatus == "已连接") "局域网" else ""

    private val remoteChatClient = RemoteChatClient()
    private var snapshot: RemotePanelSnapshot? = null
    private val pendingCommands = mutableListOf<PendingRemoteCommand>()
    private var pendingProjectFocusJob: Job? = null
    private var pendingSessionFocusJob: Job? = null
    private var pendingAttachmentUploadCount = 0
    private val maxAttachmentBytes = 10 * 1024 * 1024
    private val maxTotalAttachmentBytes = 20 * 1024 * 1024
    private val prefs = application.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    init {
        bindChatClient()
        devices = devices.copy(
            manualHost = prefs.getString(KEY_HOST, "").orEmpty(),
            manualPort = prefs.getInt(KEY_PORT, DEFAULT_PORT).toString(),
        )
    }

    fun savedLanTarget(): Pair<String, Int>? {
        val host = prefs.getString(KEY_HOST, null)?.trim().orEmpty()
        val port = prefs.getInt(KEY_PORT, DEFAULT_PORT)
        return if (host.isBlank() || port !in 1..65535) null else host to port
    }

    fun updateManualHost(value: String) {
        devices = devices.copy(manualHost = value, message = null)
    }

    fun updateManualPort(value: String) {
        devices = devices.copy(manualPort = value, message = null)
    }

    fun scanLanDevices() {
        if (devices.scanning) return
        viewModelScope.launch {
            devices = devices.copy(scanning = true, message = null)
            val preferred = devices.manualHost.trim().takeIf { it.isNotBlank() }
            val port = devices.manualPort.trim().toIntOrNull() ?: DEFAULT_PORT
            val found = LanSubnetProbe.discoverHealthHosts(getApplication(), port = port, preferredHost = preferred)
            devices = devices.copy(
                hosts = found,
                scanning = false,
                message = if (found.isEmpty()) "没有发现设备，请确认电脑端已开启连接服务。" else null,
            )
        }
    }

    fun connectManualHost(onConnected: () -> Unit) {
        val port = devices.manualPort.trim().toIntOrNull() ?: DEFAULT_PORT
        connectLanHost(devices.manualHost, port, onConnected)
    }

    fun connectLanHost(host: String, port: Int, onConnected: () -> Unit) {
        val cleanHost = host.trim()
        if (devices.connecting) return
        if (cleanHost.isBlank() || port !in 1..65535) {
            devices = devices.copy(message = "请输入有效的地址和端口。")
            return
        }
        viewModelScope.launch {
            devices = devices.copy(connecting = true, message = null)
            snapshot = null
            remoteChatClient.disconnect()
            chat = ChatUiState(connectionStatus = "连接中")
            val failure = tryEstablishDirectConnection(RemoteChatConfig(macHost = cleanHost, port = port))
            if (failure == null && isRemoteChatReady()) {
                prefs.edit().putString(KEY_HOST, cleanHost).putInt(KEY_PORT, port).apply()
                devices = devices.copy(connecting = false, connectedHost = cleanHost, connectedPort = port)
                onConnected()
            } else {
                devices = devices.copy(
                    connecting = false,
                    message = userMessage(failure ?: IllegalStateException("局域网连接失败。"), "局域网连接失败。"),
                )
            }
        }
    }

    fun disconnectRemote() {
        remoteChatClient.disconnect()
        snapshot = null
        pendingCommands.clear()
        devices = devices.copy(connectedHost = null)
        chat = ChatUiState()
    }

    fun refreshChat() {
        val config = chat.config
        if (!config.isComplete) {
            chat = chat.copy(connectionStatus = "未连接", lastError = "请先连接远程设备。")
            return
        }
        viewModelScope.launch {
            chat = chat.copy(isRefreshing = true, lastError = null)
            if (config.supportsDirectHttp) {
                val healthOk = runCatching { RemoteLanClient(config, lanBoundClient()).health() }.getOrDefault(false)
                if (!healthOk || chat.connectionStatus != "已连接") connectRemoteChat(config)
                sendRemoteCommand("requestSnapshot", sessionId = chat.selectedSessionId)
            } else {
                sendRemoteCommand("requestSnapshot", sessionId = chat.selectedSessionId)
            }
            waitForSnapshotRevisionAfter(snapshot?.revision ?: 0)
            if (config.supportsDirectHttp) reloadFiles()
            chat = chat.copy(isRefreshing = false)
        }
    }

    fun resumeFromForeground() {
        if (chat.config.isComplete) {
            refreshChat()
        }
    }

    fun selectProject(project: RemoteProject) {
        chat = chat.copy(
            selectedProjectId = project.id,
            selectedSessionId = null,
            inputText = "",
            attachments = emptyList(),
            files = emptyList(),
            fileError = null,
        )
        scheduleProjectFocusTimeout(project.id)
        sendRemoteCommand("focusProject", args = JSONObject().put("projectId", project.id))
        viewModelScope.launch { reloadFiles() }
    }

    fun selectModel(model: RemoteModel) {
        chat = chat.copy(selectedModelId = model.id, composer = chat.composer.copy(modelID = model.id))
        sendRemoteCommand(
            "composerSetModel",
            sessionId = chat.selectedSessionId,
            args = expectedArgs().put("modelID", model.id),
        )
    }

    fun setCLI(cli: String) {
        val next = cli.trim().lowercase()
        if (next.isBlank()) return
        chat = chat.copy(composer = chat.composer.copy(cli = next))
        sendRemoteCommand(
            "composerSetCLI",
            sessionId = chat.selectedSessionId,
            args = expectedArgs().put("cli", next),
        )
    }

    fun setPermissionMode(permissionMode: String) {
        val next = permissionMode.trim()
        if (next.isBlank()) return
        chat = chat.copy(composer = chat.composer.copy(permissionMode = next))
        sendRemoteCommand(
            "composerSetPermissionMode",
            sessionId = chat.selectedSessionId,
            args = expectedArgs().put("permissionMode", next),
        )
    }

    fun setReasoningEffort(reasoningEffort: String) {
        val next = reasoningEffort.trim()
        if (next.isBlank()) return
        chat = chat.copy(composer = chat.composer.copy(reasoningEffort = next))
        sendRemoteCommand(
            "composerSetReasoningEffort",
            sessionId = chat.selectedSessionId,
            args = expectedArgs().put("reasoningEffort", next),
        )
    }

    fun selectSession(session: RemoteSession) {
        chat = chat.copy(
            selectedSessionId = session.id,
            selectedProjectId = session.projectId ?: chat.selectedProjectId,
            inputText = "",
            attachments = emptyList(),
        )
        scheduleSessionFocusTimeout(session.id)
        sendRemoteCommand("focusSession", sessionId = session.id, args = JSONObject().put("sessionId", session.id))
    }

    fun startNewChat() {
        val projectId = chat.selectedProject?.id ?: return
        chat = chat.copy(selectedSessionId = null, inputText = "", attachments = emptyList(), messages = emptyList())
        sendRemoteCommand("focusProject", args = JSONObject().put("projectId", projectId))
        sendRemoteCommand("newDraftSession", args = JSONObject().put("projectId", projectId))
    }

    fun updateInput(value: String) {
        chat = chat.copy(inputText = value)
    }

    fun sendCurrentMessage() {
        val text = chat.inputText.trim()
        val attachments = chat.attachments
        if (text.isBlank() && attachments.isEmpty()) return
        val expected = expectedArgs()
        attachments.forEach { attachment ->
            sendRemoteCommand(
                "composerAttach",
                sessionId = chat.selectedSessionId,
                args = JSONObject(expected.toString()).put("attachment", attachment.toJson()),
            )
        }
        sendRemoteCommand("composerSet", sessionId = chat.selectedSessionId, args = JSONObject(expected.toString()).put("text", text))
        sendRemoteCommand("composerSend", sessionId = chat.selectedSessionId, args = expected)
        val optimistic = com.codevoke.android.data.RemoteChatMessage(kind = "user", text = text, status = "queued", attachments = attachments)
        chat = chat.copy(inputText = "", attachments = emptyList(), messages = chat.messages + optimistic)
    }

    fun uploadAttachment(filename: String, data: ByteArray, kind: String, thumbnailData: String?) {
        val safeName = filename.trim().ifBlank { if (kind == "image") "image.jpg" else "attachment" }
        val attachmentKind = kind.ifBlank { "file" }
        if (data.isEmpty()) {
            chat = chat.copy(lastError = "附件为空，无法上传。")
            return
        }
        if (!chat.config.supportsDirectHttp) {
            chat = chat.copy(lastError = "远程连接暂不支持附件上传，请在同一局域网连接后使用。")
            return
        }
        if (data.size > maxAttachmentBytes) {
            chat = chat.copy(lastError = "单个附件不能超过 10MB。")
            return
        }
        val totalSize = chat.attachments.sumOf { it.sizeBytes } + data.size
        if (totalSize > maxTotalAttachmentBytes) {
            chat = chat.copy(lastError = "本次消息附件总大小不能超过 20MB。")
            return
        }
        val config = chat.config
        val selectedProjectId = chat.selectedProjectId
        val selectedSessionId = chat.selectedSessionId
        viewModelScope.launch {
            beginAttachmentUpload()
            runCatching { RemoteLanClient(config).uploadAttachment(safeName, data) }
                .onSuccess { uploaded ->
                    if (chat.selectedProjectId != selectedProjectId || chat.selectedSessionId != selectedSessionId) {
                        finishAttachmentUpload()
                        return@onSuccess
                    }
                    val attachment = RemoteChatAttachment(
                        kind = attachmentKind,
                        filename = uploaded.filename.ifBlank { safeName },
                        path = uploaded.path,
                        thumbnailData = thumbnailData,
                        sizeBytes = data.size,
                    )
                    chat = chat.copy(
                        attachments = chat.attachments + attachment,
                    )
                    finishAttachmentUpload()
                }
                .onFailure {
                    finishAttachmentUpload()
                    chat = chat.copy(lastError = userMessage(it, "附件上传失败。"))
                }
        }
    }

    fun removeAttachment(attachmentId: String) {
        chat = chat.copy(attachments = chat.attachments.filterNot { it.id == attachmentId })
    }

    fun stopGeneration() {
        sendRemoteCommand("stop", sessionId = chat.selectedSessionId, args = JSONObject().put("startQueuedAfterStop", false))
    }

    fun cancelQueued(requestId: String) {
        val id = requestId.trim()
        if (id.isBlank()) return
        sendRemoteCommand(
            "cancelQueued",
            sessionId = chat.selectedSessionId,
            args = expectedArgs().put("requestId", id),
        )
    }

    fun flushQueue() {
        sendRemoteCommand("flushQueue", sessionId = chat.selectedSessionId, args = expectedArgs())
    }

    fun editQueued(requestId: String, text: String) {
        val id = requestId.trim()
        val nextText = text.trim()
        if (id.isBlank() || nextText.isBlank()) return
        sendRemoteCommand(
            "editQueued",
            sessionId = chat.selectedSessionId,
            args = expectedArgs()
                .put("requestId", id)
                .put("text", nextText),
        )
    }

    fun respondPermission(requestId: String, decision: String) {
        val id = requestId.trim()
        val nextDecision = decision.trim()
        if (id.isBlank() || nextDecision.isBlank()) return
        sendRemoteCommand(
            "respondPermission",
            sessionId = chat.selectedSessionId,
            args = expectedArgs()
                .put("permissionRequestId", id)
                .put("decision", nextDecision),
        )
    }

    fun respondInteractive(response: RemoteInteractiveResponse) {
        if (response.requestID.isBlank()) return
        sendRemoteCommand(
            "respondInteractive",
            sessionId = chat.selectedSessionId,
            args = expectedArgs()
                .put("interactiveRequestId", response.requestID)
                .put("interactiveResponse", response.toJson()),
        )
    }

    fun respondInteractive(
        requestId: String,
        selectedOptionIds: List<String> = emptyList(),
        customText: String? = null,
    ) {
        respondInteractive(
            RemoteInteractiveResponse(
                requestID = requestId,
                selectedOptionIDs = selectedOptionIds,
                customText = customText,
            ),
        )
    }

    fun requestSnapshot(sessionId: String? = chat.selectedSessionId) {
        sendRemoteCommand("requestSnapshot", sessionId = sessionId)
    }

    fun insertPath(path: String) {
        val next = if (chat.inputText.isBlank()) path else "${chat.inputText}\n$path"
        chat = chat.copy(inputText = next)
    }

    fun openFile(entry: RemoteFileEntry) {
        if (!entry.isDirectory) return
        viewModelScope.launch { reloadFiles(entry.relativePath) }
    }

    fun openParentDirectory() {
        val parent = chat.parentFilePath ?: return
        viewModelScope.launch { reloadFiles(parent) }
    }

    private fun connectRemoteChat(config: RemoteChatConfig, client: OkHttpClient? = null) {
        chat = chat.copy(config = config, connectionStatus = "连接中", lastError = null)
        val lanClient = client ?: if (config.isPrivateLanConfig()) {
            LanNetworkSelector.wifiBoundClient(getApplication())
        } else {
            null
        }
        remoteChatClient.connect(
            config = config,
            focusedSessionId = chat.selectedSessionId,
            lastRevision = snapshot?.revision,
            client = lanClient,
        )
    }

    private fun sendRemoteCommand(op: String, sessionId: String? = null, args: JSONObject = JSONObject()): String {
        val commandId = UUID.randomUUID().toString()
        trackPendingCommand(PendingRemoteCommand(commandId, op, sessionId, JSONObject(args.toString())))
        return sendRemoteCommandInternal(commandId, op, sessionId, args)
    }

    private fun sendRemoteCommandInternal(commandId: String, op: String, sessionId: String? = null, args: JSONObject = JSONObject()): String {
        return remoteChatClient.sendCommand(op, sessionId, args, commandId)
    }

    private fun trackPendingCommand(command: PendingRemoteCommand) {
        pendingCommands.removeAll { it.commandId == command.commandId }
        pendingCommands += command
        if (pendingCommands.size > 200) {
            pendingCommands.subList(0, pendingCommands.size - 200).clear()
        }
    }

    private fun removePendingCommand(commandId: String) {
        pendingCommands.removeAll { it.commandId == commandId }
    }

    private fun replayPendingCommands() {
        val commands = pendingCommands.toList()
        commands.forEach { command ->
            sendRemoteCommandInternal(
                commandId = command.commandId,
                op = command.op,
                sessionId = command.sessionId,
                args = JSONObject(command.args.toString()),
            )
        }
    }

    private fun bindChatClient() {
        remoteChatClient.onStatus = { status ->
            viewModelScope.launch {
                chat = chat.copy(connectionStatus = status)
                if (status == "已连接") replayPendingCommands()
            }
        }
        remoteChatClient.onError = { error -> viewModelScope.launch { chat = chat.copy(lastError = error) } }
        remoteChatClient.onSnapshot = { next -> viewModelScope.launch { adoptSnapshot(next) } }
        remoteChatClient.onPatch = { patch -> viewModelScope.launch { applyRemotePatch(patch) } }
        remoteChatClient.onAck = { commandId, status, message, sessionId ->
            viewModelScope.launch {
                removePendingCommand(commandId)
                if (!sessionId.isNullOrBlank()) chat = chat.copy(selectedSessionId = sessionId)
                if (status == "error" || status == "rejected") chat = chat.copy(lastError = message)
            }
        }
    }

    private fun adoptSnapshot(next: RemotePanelSnapshot) {
        snapshot = next
        remoteChatClient.updateResumeContext(next.currentSessionId ?: chat.selectedSessionId, next.revision)
        val projectId = chat.selectedProjectId ?: next.sessions.firstOrNull { it.id == next.currentSessionId }?.projectId ?: next.projects.firstOrNull()?.id
        val modelId = next.composer.modelID.ifBlank {
            next.models.firstOrNull { it.cli == next.composer.cli && it.isDefault }?.id ?: next.models.firstOrNull()?.id.orEmpty()
        }
        chat = chat.copy(
            projects = next.projects,
            models = next.models,
            sessions = next.sessions,
            selectedProjectId = projectId,
            selectedSessionId = next.currentSessionId ?: chat.selectedSessionId,
            selectedModelId = modelId,
            messages = next.messages,
            streamingTexts = next.streamingTexts,
            composer = next.composer,
            queuedRequests = next.queuedRequests,
            runtimeStatus = next.statusText.ifBlank { next.status },
            isAwaitingFirstModelOutput = next.isAwaitingFirstModelOutput,
            isLoadingHistory = next.isLoadingHistory,
            tokensUsed = next.tokensUsed,
            tokensTotal = next.tokensTotal,
            capabilities = next.capabilities,
            lastError = null,
        )
        if (chat.config.supportsDirectHttp) viewModelScope.launch { reloadFiles() }
    }

    private fun applyRemotePatch(patch: com.codevoke.android.data.RemotePanelPatch) {
        val current = snapshot
        if (current == null) {
            requestSnapshot(patch.sessionId ?: chat.selectedSessionId)
            return
        }
        val merged = current.applyPatch(patch)
        if (merged == null) {
            requestSnapshot(patch.sessionId ?: current.currentSessionId ?: chat.selectedSessionId)
            return
        }
        adoptSnapshot(merged)
    }

    private suspend fun reloadFiles(path: String = chat.currentFilePath) {
        val project = chat.selectedProject ?: return
        val config = chat.config
        if (!config.supportsDirectHttp) {
            chat = chat.copy(
                files = emptyList(),
                isLoadingFiles = false,
                fileError = "远程连接暂不支持文件树浏览，请在同一局域网连接后使用。",
            )
            return
        }
        chat = chat.copy(isLoadingFiles = true, fileError = null)
        runCatching { RemoteLanClient(config).projectFiles(project.id, path) }
            .onSuccess {
                chat = chat.copy(
                    files = it.entries,
                    currentFilePath = it.path,
                    parentFilePath = it.parentPath,
                    isLoadingFiles = false,
                    fileError = null,
                )
            }
            .onFailure { chat = chat.copy(isLoadingFiles = false, fileError = userMessage(it, "文件列表加载失败。")) }
    }

    private fun beginAttachmentUpload() {
        pendingAttachmentUploadCount += 1
        chat = chat.copy(isUploadingAttachment = true, lastError = null)
    }

    private fun finishAttachmentUpload() {
        pendingAttachmentUploadCount = (pendingAttachmentUploadCount - 1).coerceAtLeast(0)
        chat = chat.copy(isUploadingAttachment = pendingAttachmentUploadCount > 0)
    }

    private fun expectedArgs(): JSONObject {
        val args = JSONObject()
        chat.selectedProjectId?.let { args.put("expectedProjectId", it) }
        chat.selectedSessionId?.let { args.put("expectedSessionId", it) }
        return args
    }

    private fun RemoteInteractiveResponse.toJson(): JSONObject {
        val selected = org.json.JSONArray()
        selectedOptionIDs.forEach { selected.put(it) }
        return JSONObject()
            .put("requestID", requestID)
            .put("selectedOptionIDs", selected)
            .put("customText", customText)
    }

    private fun scheduleProjectFocusTimeout(projectId: String) {
        pendingProjectFocusJob?.cancel()
        pendingProjectFocusJob = viewModelScope.launch {
            delay(8_000)
            if (chat.selectedProjectId == projectId) {
                sendRemoteCommand("requestSnapshot", sessionId = chat.selectedSessionId)
            }
        }
    }

    private fun scheduleSessionFocusTimeout(sessionId: String) {
        pendingSessionFocusJob?.cancel()
        pendingSessionFocusJob = viewModelScope.launch {
            delay(8_000)
            if (chat.selectedSessionId == sessionId) {
                sendRemoteCommand("requestSnapshot", sessionId = sessionId)
            }
        }
    }

    private suspend fun waitForDirectRemoteChatReady() {
        repeat(160) {
            if (remoteChatClient.isReady || remoteChatClient.awaitReady(100)) return
        }
        remoteChatClient.disconnect()
        chat = chat.copy(connectionStatus = "未连接", lastError = "局域网连接通道建立超时，请确认电脑端在线后重试。")
        throw IllegalStateException("局域网连接通道建立超时，请确认电脑端在线后重试。")
    }

    private suspend fun waitForSnapshotRevisionAfter(previousRevision: Int) {
        repeat(30) {
            if ((snapshot?.revision ?: 0) > previousRevision) return
            delay(100)
        }
    }

    private fun userMessage(error: Throwable, fallback: String = "请求失败。"): String {
        return error.localizedMessage?.takeIf { it.isNotBlank() } ?: fallback
    }

    private fun isRemoteChatReady(): Boolean =
        chat.connectionStatus == "已连接" || remoteChatClient.isReady

    private fun RemoteChatConfig.isPrivateLanConfig(): Boolean =
        supportsDirectHttp && isPrivateIPv4Host(macHost)

    private fun isPrivateIPv4Host(host: String): Boolean {
        val octets = host.trim().split(".").mapNotNull { it.toIntOrNull() }
        if (octets.size != 4 || octets.any { it !in 0..255 }) return false
        return when (octets[0]) {
            10 -> true
            172 -> octets[1] in 16..31
            192 -> octets[1] == 168
            else -> false
        }
    }

    private suspend fun tryEstablishDirectConnection(config: RemoteChatConfig): Throwable? {
        val app = getApplication<Application>()
        var directConfig = config
        val clients = LanNetworkSelector.lanClientsForAttempt(app)
        val wifiSubnet = LanNetworkSelector.wifiSubnetPrefix(app)
        val offeredSubnet = directConfig.macHost.split(".").take(3).joinToString(".")
        if (
            wifiSubnet != null &&
            directConfig.isPrivateLanConfig() &&
            offeredSubnet != wifiSubnet
        ) {
            LanSubnetProbe.discoverHealthHost(
                context = app,
                port = directConfig.port,
                preferredHost = LanNetworkSelector.localWifiIPv4(app),
            )?.let { discoveredHost ->
                directConfig = directConfig.copy(macHost = discoveredHost)
            }
        }

        var healthClient: OkHttpClient? = null
        for (client in clients) {
            if (runCatching { RemoteLanClient(directConfig, client).health() }.getOrDefault(false)) {
                healthClient = client
                break
            }
        }
        if (healthClient == null && directConfig.isPrivateLanConfig()) {
            val discoveredHost = LanSubnetProbe.discoverHealthHost(
                context = app,
                port = directConfig.port,
                preferredHost = directConfig.macHost,
            )
            if (discoveredHost != null) {
                directConfig = directConfig.copy(macHost = discoveredHost)
                for (client in clients) {
                    if (runCatching { RemoteLanClient(directConfig, client).health() }.getOrDefault(false)) {
                        healthClient = client
                        break
                    }
                }
            }
        }
        if (healthClient == null) {
            val failure = IllegalStateException(
                "无法访问电脑地址 ${directConfig.macHost}:${directConfig.port}，请确认手机与电脑在同一 WiFi。",
            )
            chat = chat.copy(connectionStatus = "未连接", lastError = failure.localizedMessage)
            return failure
        }

        val wsClients = buildList {
            add(healthClient)
            addAll(clients.filter { it !== healthClient })
        }
        var lastError: Throwable? = null
        for (wsClient in wsClients) {
            remoteChatClient.disconnect()
            chat = chat.copy(config = directConfig, connectionStatus = "连接中", lastError = null)
            connectRemoteChat(directConfig, client = wsClient)
            try {
                waitForDirectRemoteChatReady()
                return null
            } catch (error: Throwable) {
                lastError = error
                remoteChatClient.disconnect()
            }
        }
        val failure = lastError ?: IllegalStateException("局域网连接失败。")
        chat = chat.copy(connectionStatus = "未连接", lastError = userMessage(failure, "局域网连接失败。"))
        return failure
    }

    private fun lanBoundClient(): OkHttpClient =
        LanNetworkSelector.wifiBoundClient(getApplication())
            ?: LanNetworkSelector.defaultLanClient()

    private companion object {
        const val PREFS_NAME = "codevoke.lan"
        const val KEY_HOST = "host"
        const val KEY_PORT = "port"
        const val DEFAULT_PORT = 18765
    }
}
