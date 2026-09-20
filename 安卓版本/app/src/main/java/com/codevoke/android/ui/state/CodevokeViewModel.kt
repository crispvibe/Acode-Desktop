package com.codevoke.android.ui.state

import android.app.Application
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.codevoke.android.data.AppUpdateClient
import com.codevoke.android.data.AppUpdateInfo
import com.codevoke.android.data.AppUpdateInstaller
import com.codevoke.android.data.AppVersions
import com.codevoke.android.data.EndpointStore
import com.codevoke.android.data.LanDiscoveredHost
import com.codevoke.android.data.PairedHost
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
import com.codevoke.android.data.RemoteWanClient
import com.codevoke.android.data.WanEndpoint
import com.codevoke.android.data.WanProbeResult
import com.codevoke.android.data.LanNetworkSelector
import com.codevoke.android.data.LanSubnetProbe
import com.codevoke.android.data.applyPatch
import com.codevoke.android.data.toJson
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.SocketFactory

/** 正在输入 6 位配对码的局域网目标。 */
data class PairTarget(
    val host: String,
    val port: Int,
    val label: String,
)

data class DeviceUiState(
    val hosts: List<LanDiscoveredHost> = emptyList(),
    val pairedHosts: List<PairedHost> = emptyList(),
    val scanning: Boolean = false,
    val connecting: Boolean = false,
    val pairing: Boolean = false,
    val pairTarget: PairTarget? = null,
    val pairError: String? = null,
    val manualHost: String = "",
    val manualPort: String = "18765",
    val connectionString: String = "",
    val message: String? = null,
    val connectedHostId: String? = null,
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

/// GitHub Releases 应用内更新状态（设置页 banner + 弹窗共用）。
data class UpdateUiState(
    val checking: Boolean = false,
    /// 发现的新版本；null = 无更新或未检查。
    val update: AppUpdateInfo? = null,
    val dialogVisible: Boolean = false,
    /// 手动检查的结果提示（"已是最新版本"/失败原因）；静默检查不填。
    val notice: String? = null,
    val downloading: Boolean = false,
    /// 0f..1f；总长度未知时按 downloadedBytes 显示。
    val downloadProgress: Float = 0f,
    val downloadedBytes: Long = 0,
    val downloadTotal: Long = 0,
    val downloadedApk: java.io.File? = null,
    /// downloadedApk 对应的版本号；检查发现更新版后旧包不能复用。
    val downloadedVersion: String? = null,
    val error: String? = null,
    /// 已跳"安装未知应用"系统授权页，回到前台后自动继续安装。
    val pendingInstall: Boolean = false,
)

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
    var update by mutableStateOf(UpdateUiState())
        private set
    val transportLabel: String
        get() = when {
            chat.connectionStatus != "已连接" -> ""
            connectedViaLan -> "局域网"
            else -> "跨网直连"
        }

    private val endpointStore = EndpointStore(application)
    private val remoteChatClient = RemoteChatClient()
    /// 当前连接走的是局域网地址还是公网地址（驱动 transportLabel）。
    private var connectedViaLan = false
    private var snapshot: RemotePanelSnapshot? = null
    private val pendingCommands = mutableListOf<PendingRemoteCommand>()
    private var pendingProjectFocusJob: Job? = null
    private var pendingSessionFocusJob: Job? = null
    /// 等待 focus 到位的目标（=用户最新意图）。pending 期间到达的其它
    /// session/项目 snapshot 只更新目录，不替换消息区与选中态（对齐 iOS
    /// shouldAccept 语义，避免切换途中被迟到快照把消息区闪回旧会话）。
    private var pendingProjectFocusId: String? = null
    private var pendingSessionFocusId: String? = null
    /// per-session snapshot 缓存：切会话时先贴上次看到的快照，server 的
    /// focusSession 响应到达后再覆盖（iOS PanelStateMirror 的等价物）。
    private val snapshotCacheBySessionId = mutableMapOf<String?, RemotePanelSnapshot>()
    /// endpoint 重竞速去重：连续重连失败期间 onConnectionStale 会反复触发。
    private var endpointReraceRunning = false
    /// 每收到一个 panel_state envelope（含被门禁拒绝的）+1 —— 是"连接活着"
    /// 的最硬证据，refresh 等待与超时判定用它而不是 revision（revision 按
    /// session 日志独立编号，跨会话不可比）。
    private var panelStateSequence = 0
    private var pendingAttachmentUploadCount = 0
    /// 合并窗口：流式期间 host 每 ~30ms 推一个 patch，绝大多数只改
    /// streamingTexts/statusText/tokens 这类外观字段。这类 patch 立即并入
    /// `snapshot`（保住 baseRevision 链），但 `chat` 的 Compose 状态发布
    /// 合并到 ~80ms 尾部刷新，避免每个 patch 都让整棵 ChatScreen 重组。
    private var pendingCosmeticSnapshot: RemotePanelSnapshot? = null
    private var cosmeticPublishJob: Job? = null
    /// 已经自动拉过文件树的项目 id；防止 adoptSnapshot 每个 patch 都打一次
    /// projectFiles HTTP（流式期间约 30 次/秒，是明显的卡顿/网络风暴根因）。
    private var autoLoadedFilesProjectId: String? = null
    private val maxAttachmentBytes = 10 * 1024 * 1024
    private val maxTotalAttachmentBytes = 20 * 1024 * 1024
    private val prefs = application.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    init {
        bindChatClient()
        devices = devices.copy(
            manualHost = prefs.getString(KEY_HOST, "").orEmpty(),
            manualPort = prefs.getInt(KEY_PORT, DEFAULT_PORT).toString(),
            pairedHosts = endpointStore.list(),
        )
    }

    /** 启动自动连接目标：上次连接的已配对设备，否则第一台配对设备。 */
    fun autoConnectTarget(): PairedHost? {
        val hosts = endpointStore.list()
        val lastId = prefs.getString(KEY_HOST_ID, null)
        return hosts.firstOrNull { it.hostId == lastId } ?: hosts.firstOrNull()
    }

    fun updateManualHost(value: String) {
        devices = devices.copy(manualHost = value, message = null)
    }

    fun updateManualPort(value: String) {
        devices = devices.copy(manualPort = value, message = null)
    }

    fun updateConnectionString(value: String) {
        devices = devices.copy(connectionString = value, message = null)
    }

    fun scanLanDevices() {
        if (devices.scanning) return
        viewModelScope.launch {
            devices = devices.copy(scanning = true, message = null)
            val preferred = devices.manualHost.trim().takeIf { it.isNotBlank() }
            val port = devices.manualPort.trim().toIntOrNull() ?: DEFAULT_PORT
            val found = LanSubnetProbe.discoverHealthHosts(getApplication(), port = port, preferredHost = preferred)
            // 静默刷新（契约 §6）：扫到的 proto:2 host 若能完成 wss+token 握手，
            // 即确认为是已配对设备，调 /connect_info 更新其 eps。
            val matched = silentRefreshPairedHosts(found)
            devices = devices.copy(
                hosts = found.map { it.copy(pairedHostId = matched[it.address]) },
                pairedHosts = endpointStore.list(),
                scanning = false,
                message = if (found.isEmpty()) "没有发现设备，请确认电脑端已开启连接服务。" else null,
            )
        }
    }

    private suspend fun silentRefreshPairedHosts(found: List<LanDiscoveredHost>): Map<String, String> {
        val paired = endpointStore.list()
        if (paired.isEmpty() || found.isEmpty()) return emptyMap()
        val wifiFactory = LanNetworkSelector.wifiNetwork(getApplication())?.socketFactory
        val matched = ConcurrentHashMap<String, String>()
        coroutineScope {
            found.map { lanHost ->
                async {
                    val endpoint = WanEndpoint(lanHost.address, lanHost.port)
                    var device: PairedHost? = null
                    for (candidate in paired) {
                        val result = try {
                            RemoteWanClient.probeChat(
                                endpoint = endpoint,
                                token = candidate.token,
                                certFP = candidate.certFP,
                                socketFactory = wifiFactory,
                                timeoutMillis = PROBE_TIMEOUT_MS / 2,
                            )
                        } catch (cancelled: kotlinx.coroutines.CancellationException) {
                            throw cancelled
                        } catch (error: Throwable) {
                            WanProbeResult.Failed
                        }
                        if (result == WanProbeResult.Success) {
                            device = candidate
                            break
                        }
                    }
                    val matchedDevice = device ?: return@async
                    matched[lanHost.address] = matchedDevice.hostId
                    val httpClient = RemoteWanClient.httpClient(matchedDevice.certFP, wifiFactory)
                    RemoteWanClient.connectInfo(httpClient, endpoint, matchedDevice.token)?.let { info ->
                        endpointStore.refreshEndpoints(matchedDevice.hostId, info.name, info.eps, reachableVia = endpoint)
                    }
                }
            }.awaitAll()
        }
        return matched
    }

    // ---- 配对（契约 §6 三个入口：扫码 / 连接串 / 局域网 6 位码）----

    fun openPairDialog(host: String, port: Int, label: String) {
        val clean = host.trim()
        if (clean.isBlank() || port !in 1..65535) {
            devices = devices.copy(message = "请输入有效的地址和端口。")
            return
        }
        devices = devices.copy(
            pairTarget = PairTarget(clean, port, label.ifBlank { clean }),
            pairError = null,
            message = null,
        )
    }

    fun openManualPairDialog() {
        val port = devices.manualPort.trim().toIntOrNull() ?: DEFAULT_PORT
        openPairDialog(devices.manualHost, port, devices.manualHost.trim())
    }

    fun dismissPairDialog() {
        if (devices.pairing) return
        devices = devices.copy(pairTarget = null, pairError = null)
    }

    /** 局域网 6 位码配对：POST /pair（仅私网来源）。 */
    fun submitPairCode(code: String, onConnected: () -> Unit) {
        val target = devices.pairTarget ?: return
        val digits = code.trim()
        if (devices.pairing) return
        if (digits.length != 6 || digits.any { !it.isDigit() }) {
            devices = devices.copy(pairError = "请输入电脑端显示的 6 位数字配对码。")
            return
        }
        viewModelScope.launch {
            devices = devices.copy(pairing = true, pairError = null)
            val endpoint = WanEndpoint(target.host, target.port)
            val wifiFactory = LanNetworkSelector.wifiNetwork(getApplication())?.socketFactory
            val outcome = try {
                Result.success(
                    RemoteWanClient.pair(
                        client = RemoteWanClient.discoveryClient(socketFactory = wifiFactory),
                        endpoint = endpoint,
                        code = digits,
                        deviceName = "${Build.MANUFACTURER} ${Build.MODEL}".trim().ifBlank { "Android" },
                    ),
                )
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                Result.failure(error)
            }
            outcome.onSuccess { paired ->
                endpointStore.upsert(paired)
                prefs.edit().putString(KEY_HOST, target.host).putInt(KEY_PORT, target.port).apply()
                devices = devices.copy(
                    pairing = false,
                    pairTarget = null,
                    pairedHosts = endpointStore.list(),
                )
                connectPairedHost(paired.hostId, onConnected)
            }.onFailure { error ->
                devices = devices.copy(
                    pairing = false,
                    pairError = userMessage(error, "配对失败，请确认配对码正确且手机与电脑在同一网络。"),
                )
            }
        }
    }

    /** 扫码 / 手动粘贴连接串：解析 acode://pair?d=<base64url(JSON)>（契约 §4.4）。 */
    fun pairFromConnectionString(raw: String, onConnected: () -> Unit) {
        val paired = RemoteWanClient.parsePairLink(raw)
        if (paired == null) {
            devices = devices.copy(message = "配对信息无效，请确认二维码或连接串来自电脑端设置页（acode://pair?d=…）。")
            return
        }
        endpointStore.upsert(paired)
        devices = devices.copy(connectionString = "", pairedHosts = endpointStore.list(), message = null)
        connectPairedHost(paired.hostId, onConnected)
    }

    fun connectDiscoveredHost(host: LanDiscoveredHost, onConnected: () -> Unit) {
        host.pairedHostId?.let { connectPairedHost(it, onConnected) }
            ?: openPairDialog(host.address, host.port, host.name.ifBlank { host.address })
    }

    fun forgetPairedHost(hostId: String) {
        endpointStore.remove(hostId)
        if (prefs.getString(KEY_HOST_ID, null) == hostId) {
            prefs.edit().remove(KEY_HOST_ID).apply()
        }
        if (devices.connectedHostId == hostId) {
            disconnectRemote()
        }
        devices = devices.copy(pairedHosts = endpointStore.list())
    }

    /**
     * 连接已配对设备（契约 §6）：lastGood 先行 + 其余 eps 并行竞速，
     * 单条 3s 未握手换下；全部失败提示"地址可能已变化"。
     */
    fun connectPairedHost(hostId: String, onConnected: () -> Unit) {
        val device = endpointStore.get(hostId)
        if (device == null) {
            devices = devices.copy(message = "设备信息不存在，请重新配对。")
            return
        }
        if (devices.connecting) return
        viewModelScope.launch {
            devices = devices.copy(connecting = true, message = null)
            snapshot = null
            cancelCosmeticPublish()
            autoLoadedFilesProjectId = null
            clearPendingSessionFocus()
            clearPendingProjectFocus()
            snapshotCacheBySessionId.clear()
            // 上一台设备未 ack 的命令不带过来 —— sessionId/命令语义都只对
            // 原 host 有效，重放到新 host 只会收获一串 reject。
            pendingCommands.clear()
            remoteChatClient.disconnect()
            chat = ChatUiState(connectionStatus = "连接中")
            val wifiFactory = LanNetworkSelector.wifiNetwork(getApplication())?.socketFactory
            val ordered = (listOfNotNull(device.lastGood) + device.eps).distinct()
            if (ordered.isEmpty()) {
                devices = devices.copy(
                    connecting = false,
                    message = "该设备没有可用地址，请回到同一局域网刷新或重新配对。",
                )
                chat = chat.copy(connectionStatus = "未连接")
                return@launch
            }
            val race = raceEndpoints(device, ordered, wifiFactory)
            val winner = race.winner
            if (winner == null) {
                val failure = when {
                    race.sawAuthFailure || race.sawPinMismatch ->
                        "配对信息已失效或电脑证书已更换，请删除该设备后重新配对。"
                    else ->
                        "无法连接到 ${device.name}，地址可能已变化。请回到同一局域网刷新，或重新扫码配对。"
                }
                devices = devices.copy(connecting = false, message = failure)
                chat = chat.copy(connectionStatus = "未连接", lastError = failure)
                return@launch
            }
            endpointStore.markLastGood(hostId, winner)
            connectedViaLan = winner.isLanAddress
            val config = RemoteChatConfig(
                macHost = winner.address,
                port = winner.port,
                token = device.token,
                certFP = device.certFP,
            )
            connectRemoteChat(
                config,
                client = RemoteWanClient.wsClient(device.certFP, socketFactoryFor(winner, wifiFactory)),
            )
            try {
                waitForDirectRemoteChatReady()
                prefs.edit().putString(KEY_HOST_ID, hostId).apply()
                devices = devices.copy(
                    connecting = false,
                    connectedHostId = hostId,
                    pairedHosts = endpointStore.list(),
                )
                onConnected()
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                devices = devices.copy(
                    connecting = false,
                    message = userMessage(error, "连接失败，请重试。"),
                )
            }
        }
    }

    private data class EndpointRace(
        val winner: WanEndpoint?,
        val sawAuthFailure: Boolean,
        val sawPinMismatch: Boolean,
    )

    private suspend fun raceEndpoints(
        device: PairedHost,
        eps: List<WanEndpoint>,
        wifiFactory: SocketFactory?,
    ): EndpointRace = coroutineScope {
        val winner = CompletableDeferred<WanEndpoint>()
        val sawAuthFailure = AtomicBoolean()
        val sawPinMismatch = AtomicBoolean()
        eps.forEach { endpoint ->
            launch {
                val result = try {
                    RemoteWanClient.probeChat(
                        endpoint = endpoint,
                        token = device.token,
                        certFP = device.certFP,
                        socketFactory = socketFactoryFor(endpoint, wifiFactory),
                        timeoutMillis = PROBE_TIMEOUT_MS,
                    )
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    WanProbeResult.Failed
                }
                when (result) {
                    WanProbeResult.Success -> winner.complete(endpoint)
                    WanProbeResult.AuthFailed -> sawAuthFailure.set(true)
                    WanProbeResult.PinMismatch -> sawPinMismatch.set(true)
                    WanProbeResult.Failed -> Unit
                }
            }
        }
        val first = withTimeoutOrNull(PROBE_TIMEOUT_MS + 800) { winner.await() }
        coroutineContext.cancelChildren()
        EndpointRace(first, sawAuthFailure.get(), sawPinMismatch.get())
    }

    /** LAN 地址走 Wi-Fi 网卡绑定的 socket；公网地址用系统默认路由。 */
    private fun socketFactoryFor(endpoint: WanEndpoint, wifiFactory: SocketFactory?): SocketFactory? =
        if (endpoint.isLanAddress) wifiFactory else null

    private fun socketFactoryForHost(host: String): SocketFactory? =
        if (LanNetworkSelector.isPrivateIPv4(host) || host.startsWith("fe80:", ignoreCase = true)) {
            LanNetworkSelector.wifiNetwork(getApplication())?.socketFactory
        } else {
            null
        }

    private fun httpClientFor(config: RemoteChatConfig): OkHttpClient =
        RemoteWanClient.httpClient(config.certFP, socketFactoryForHost(config.macHost))

    fun disconnectRemote() {
        remoteChatClient.disconnect()
        snapshot = null
        cancelCosmeticPublish()
        autoLoadedFilesProjectId = null
        clearPendingSessionFocus()
        clearPendingProjectFocus()
        snapshotCacheBySessionId.clear()
        pendingCommands.clear()
        connectedViaLan = false
        devices = devices.copy(connectedHostId = null)
        chat = ChatUiState()
    }

    /**
     * 进后台：断开 WS。Android 上 OkHttp ping 在后台继续跑既耗电又会让
     * 连接进入半死态（网络一切换 socket 就黑洞化）；回前台由
     * resumeFromForeground → refreshChat 恢复。pendingCommands 与
     * pending focus 保留，重连后经 resume/replay 自动收敛。
     */
    fun suspendForBackground() {
        if (!chat.config.isComplete) return
        remoteChatClient.disconnect()
        cancelCosmeticPublish()
        chat = chat.copy(connectionStatus = "未连接")
    }

    fun refreshChat() {
        val config = chat.config
        if (!config.isComplete) {
            chat = chat.copy(connectionStatus = "未连接", lastError = "请先连接远程设备。")
            return
        }
        viewModelScope.launch {
            chat = chat.copy(isRefreshing = true, lastError = null)
            val baseline = panelStateSequence
            if (config.supportsDirectHttp) {
                val healthOk = runCatching { RemoteLanClient(config, httpClientFor(config)).health() }.getOrDefault(false)
                if (!healthOk || chat.connectionStatus != "已连接") {
                    // 端点可能已失效（网络切换/host 重启换址）：先对保存的
                    // eps 重竞速；无赢家时 connectRemoteChat 直连原地址兜底。
                    if (!reraceEndpoints(config)) connectRemoteChat(config)
                }
                sendRemoteCommand("requestSnapshot", sessionId = chat.selectedSessionId)
            } else {
                sendRemoteCommand("requestSnapshot", sessionId = chat.selectedSessionId)
            }
            if (!waitForFreshSnapshot(baseline)) {
                // 已连接但 ~3s 没有任何 panel_state：连接可能半死（TCP 黑洞），
                // 强制重连一次兜底 —— 对齐 iOS refresh 的升级路径。
                connectRemoteChat(chat.config)
            }
            if (config.supportsDirectHttp) reloadFiles()
            chat = chat.copy(isRefreshing = false)
        }
    }

    /**
     * 端点重竞速（契约 §6 的恢复路径）：当前地址连续连不上时，对 EndpointStore
     * 里该主机保存的 eps 重新跑 lastGood 先行 + 并行竞速，胜出后写回 lastGood
     * 并用新地址重建 WS。返回 true = 已发起新连接。
     */
    private suspend fun reraceEndpoints(config: RemoteChatConfig): Boolean {
        if (endpointReraceRunning) return false
        val host = endpointStore.list().firstOrNull { it.certFP == config.certFP } ?: return false
        val ordered = (listOfNotNull(host.lastGood) + host.eps).distinct()
        if (ordered.isEmpty()) return false
        endpointReraceRunning = true
        try {
            val wifiFactory = LanNetworkSelector.wifiNetwork(getApplication())?.socketFactory
            val race = raceEndpoints(host, ordered, wifiFactory)
            val winner = race.winner ?: return false
            endpointStore.markLastGood(host.hostId, winner)
            connectedViaLan = winner.isLanAddress
            connectRemoteChat(
                config.copy(macHost = winner.address, port = winner.port),
                client = RemoteWanClient.wsClient(host.certFP, socketFactoryFor(winner, wifiFactory)),
            )
            return true
        } finally {
            endpointReraceRunning = false
        }
    }

    fun resumeFromForeground() {
        // 从"安装未知应用"授权页返回：已授权则继续安装，未授权清标记等用户再点。
        if (update.pendingInstall) {
            if (AppUpdateInstaller.canRequestInstalls(getApplication())) {
                installUpdate()
            } else {
                update = update.copy(pendingInstall = false)
            }
        }
        if (chat.config.isComplete) {
            refreshChat()
        }
    }

    // ---- 应用内更新（GitHub Releases，无服务器）----

    /**
     * 检查更新。manual=false 为启动静默检查：失败和无新版都不打扰用户，
     * 有新版才弹窗 + 设置页 banner；manual=true 为设置页手动入口，结果写进 notice。
     */
    fun checkForUpdates(manual: Boolean = false) {
        if (update.checking) return
        viewModelScope.launch {
            update = update.copy(checking = true, notice = null)
            val latest = AppUpdateClient.fetchLatestRelease()
            when {
                latest == null -> update = update.copy(
                    checking = false,
                    notice = if (manual) "检查更新失败，请稍后重试。" else null,
                )
                AppVersions.isNewer(latest.tag, currentVersionName()) -> update = update.copy(
                    checking = false,
                    update = latest,
                    dialogVisible = true,
                    notice = null,
                )
                else -> update = update.copy(
                    checking = false,
                    notice = if (manual) "已是最新版本。" else null,
                )
            }
        }
    }

    fun dismissUpdateDialog() {
        update = update.copy(dialogVisible = false)
    }

    /** 设置页 banner 点击后重新打开更新弹窗。 */
    fun showUpdateDialog() {
        if (update.update != null) update = update.copy(dialogVisible = true)
    }

    /** 「下载安装」：下载 APK 到缓存目录，完成后自动进入安装流程。 */
    fun downloadAndInstallUpdate() {
        val info = update.update ?: return
        if (update.downloading) return
        // 同版本已下载过直接装，不重复下载。
        update.downloadedApk
            ?.takeIf { it.exists() && update.downloadedVersion == info.version }
            ?.let {
                installUpdate()
                return
            }
        viewModelScope.launch {
            update = update.copy(
                downloading = true,
                downloadProgress = 0f,
                downloadedBytes = 0,
                downloadTotal = 0,
                error = null,
            )
            try {
                val file = AppUpdateClient.downloadApk(getApplication(), info) { soFar, total ->
                    val progress = if (total > 0) (soFar.toFloat() / total.toFloat()).coerceIn(0f, 1f) else 0f
                    update = update.copy(
                        downloadProgress = progress,
                        downloadedBytes = soFar,
                        downloadTotal = total,
                    )
                }
                update = update.copy(
                    downloading = false,
                    downloadedApk = file,
                    downloadedVersion = info.version,
                    downloadProgress = 1f,
                )
                installUpdate()
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                update = update.copy(downloading = false)
                throw cancelled
            } catch (error: Throwable) {
                update = update.copy(
                    downloading = false,
                    error = userMessage(error, "下载失败，请稍后重试。"),
                )
            }
        }
    }

    /** 安装已下载 APK；API 26+ 无安装权限先跳系统授权页，回来后由 resumeFromForeground 续装。 */
    fun installUpdate() {
        val file = update.downloadedApk ?: return
        val app = getApplication<Application>()
        if (!AppUpdateInstaller.canRequestInstalls(app)) {
            update = update.copy(pendingInstall = true)
            AppUpdateInstaller.openInstallPermissionSettings(app)
            return
        }
        update = update.copy(pendingInstall = false)
        AppUpdateInstaller.installApk(app, file)
    }

    /** release 没附 APK 时的兜底：浏览器打开发布页手动下载。 */
    fun openReleasePage() {
        val url = update.update?.pageUrl ?: AppUpdateClient.RELEASE_PAGE_URL
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        getApplication<Application>().startActivity(intent)
    }

    private fun currentVersionName(): String =
        runCatching {
            getApplication<Application>().packageManager
                .getPackageInfo(getApplication<Application>().packageName, 0)
                .versionName
        }.getOrNull().orEmpty().ifBlank { "0.0.0" }

    fun selectProject(project: RemoteProject) {
        cancelCosmeticPublish()
        clearPendingSessionFocus()
        pendingProjectFocusId = project.id
        autoLoadedFilesProjectId = project.id
        chat = chat.copy(
            selectedProjectId = project.id,
            selectedSessionId = null,
            inputText = "",
            attachments = emptyList(),
            files = emptyList(),
            fileError = null,
            currentFilePath = "",
            parentFilePath = null,
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
        cancelCosmeticPublish()
        clearPendingProjectFocus()
        val previousProjectId = chat.selectedProjectId
        pendingSessionFocusId = session.id
        chat = chat.copy(
            selectedSessionId = session.id,
            selectedProjectId = session.projectId ?: chat.selectedProjectId,
            inputText = "",
            attachments = emptyList(),
        )
        if (session.projectId != null && session.projectId != previousProjectId) {
            // 会话属于别的项目：文件树跟随实际会话上下文（对齐 iOS selectSession）。
            autoLoadedFilesProjectId = null
            chat = chat.copy(files = emptyList(), fileError = null, currentFilePath = "", parentFilePath = null)
            viewModelScope.launch { reloadFiles() }
        }
        // 先贴缓存快照 —— 用户点击后立即看到该会话的历史，而不是等
        // server 回完 focusSession 才出现内容；新 snapshot 到达后覆盖。
        snapshotCacheBySessionId[session.id]?.let { cached ->
            snapshot = cached
            remoteChatClient.updateResumeContext(cached.sessionId, cached.revision)
            publishSnapshot(cached, clearError = false)
        }
        scheduleSessionFocusTimeout(session.id)
        sendRemoteCommand("focusSession", sessionId = session.id, args = JSONObject().put("sessionId", session.id))
    }

    fun startNewChat() {
        val projectId = pendingProjectFocusId ?: chat.selectedProject?.id ?: return
        cancelCosmeticPublish()
        clearPendingSessionFocus()
        pendingProjectFocusId = projectId
        scheduleProjectFocusTimeout(projectId)
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
            runCatching { RemoteLanClient(config, httpClientFor(config)).uploadAttachment(safeName, data) }
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
        // lastRevision 与 focusedSessionId 必须属于同一条 session 日志：当前
        // snapshot 若已是别的会话（切换途中），带它的 revision 会让 server
        // 回放错误日志的 patch 链。不匹配就走全量 snapshot。
        val resumeRevision = snapshot
            ?.takeIf { it.sessionId != null && it.sessionId == chat.selectedSessionId }
            ?.revision
        remoteChatClient.connect(
            config = config,
            focusedSessionId = chat.selectedSessionId,
            lastRevision = resumeRevision,
            client = client,
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
        remoteChatClient.onSnapshot = { next -> viewModelScope.launch { cancelCosmeticPublish(); handleIncomingSnapshot(next) } }
        remoteChatClient.onPatch = { patch -> viewModelScope.launch { applyRemotePatch(patch) } }
        remoteChatClient.onAck = { commandId, status, message, sessionId ->
            viewModelScope.launch {
                removePendingCommand(commandId)
                // 等待目标会话期间，旧上下文命令迟到的 ack 不能覆盖用户最新选择。
                if (!sessionId.isNullOrBlank() &&
                    (pendingSessionFocusId == null || pendingSessionFocusId == sessionId)
                ) {
                    chat = chat.copy(selectedSessionId = sessionId)
                }
                if (status == "error" || status == "rejected") chat = chat.copy(lastError = message)
            }
        }
        // 连续重连失败：当前 endpoint 大概率已失效 → 重跑竞速换新地址。
        remoteChatClient.onConnectionStale = {
            viewModelScope.launch { reraceEndpoints(chat.config) }
        }
    }

    /// snapshot 到达：先进 per-session 缓存，再按 pending/聚焦门禁决定是否进 UI。
    /// 被拒绝的 envelope 只更新目录 —— 消息区与选中态不被迟到/外会话状态覆盖。
    private fun handleIncomingSnapshot(next: RemotePanelSnapshot) {
        panelStateSequence++
        snapshotCacheBySessionId[next.sessionId] = next
        if (!shouldAdoptSnapshot(next)) {
            chat = chat.copy(
                projects = next.projects,
                models = next.models,
                sessions = next.sessions,
            )
            if (snapshot == null && shouldAcceptBootstrapSnapshot(next)) {
                // 首个 envelope：总得先给 UI 一份可看的状态。
                adoptSnapshot(next, clearError = true)
            }
            return
        }
        adoptSnapshot(next, clearError = true)
    }

    /// 是否把这份 snapshot 应用到消息区/选中态（对齐 iOS shouldAccept 语义）。
    private fun shouldAdoptSnapshot(next: RemotePanelSnapshot): Boolean {
        pendingSessionFocusId?.let { pending ->
            if (next.currentSessionId == pending || next.sessionId == pending) return true
            if (next.sessions.none { it.id == pending }) {
                // 等待的会话已从目录消失（被删/换 host）→ 放弃等待。
                clearPendingSessionFocus()
                return shouldAcceptBootstrapSnapshot(next)
            }
            return false
        }
        val focused = chat.selectedSessionId
        if (focused != null) {
            if (next.currentSessionId == focused || next.sessionId == focused) return true
            if (next.sessions.none { it.id == focused }) {
                // 聚焦会话已消失 → 放弃旧焦点，让新状态进来。
                chat = chat.copy(selectedSessionId = null)
                return shouldAcceptBootstrapSnapshot(next)
            }
            return false
        }
        val projectGate = pendingProjectFocusId ?: chat.selectedProjectId
            ?: return shouldAcceptBootstrapSnapshot(next)
        val currentId = next.currentSessionId
        if (currentId != null) {
            return next.sessions.firstOrNull { it.id == currentId }?.projectId == projectGate
        }
        // 草稿面板（无 currentSessionId）：只在项目切换途中才采纳草稿快照。
        return pendingProjectFocusId != null && next.sessionId == null
    }

    private fun shouldAcceptBootstrapSnapshot(next: RemotePanelSnapshot): Boolean =
        next.projects.isNotEmpty() || next.models.isNotEmpty() ||
            next.sessions.isNotEmpty() || next.sessionId == null

    private fun clearPendingSessionFocus() {
        pendingSessionFocusJob?.cancel()
        pendingSessionFocusJob = null
        pendingSessionFocusId = null
    }

    private fun clearPendingProjectFocus() {
        pendingProjectFocusJob?.cancel()
        pendingProjectFocusJob = null
        pendingProjectFocusId = null
    }

    private fun adoptSnapshot(next: RemotePanelSnapshot, clearError: Boolean = false) {
        snapshot = next
        snapshotCacheBySessionId[next.sessionId] = next
        // resume 上下文必须配成对：revision 属于 next.sessionId 的日志。
        // （此前用 currentSessionId 配 revision —— 字段错位时 server 会在
        //   另一条日志上按这个 revision 回放，产出错误 patch 链。）
        remoteChatClient.updateResumeContext(next.sessionId, next.revision)
        // pending focus 到位 → 清标记；sessionId 命中但 currentSessionId
        // 还没翻过来的 snapshot 也算到位（避免干等 8s 超时）。
        val pendingSession = pendingSessionFocusId
        val pendingSatisfied = pendingSession != null &&
            (next.currentSessionId == pendingSession || next.sessionId == pendingSession)
        if (pendingSatisfied) clearPendingSessionFocus()
        pendingProjectFocusId?.let { pending ->
            val currentId = next.currentSessionId
            // 草稿面板（currentSessionId==null）也算项目切换到位。
            if (currentId == null || next.sessions.firstOrNull { it.id == currentId }?.projectId == pending) {
                clearPendingProjectFocus()
            }
        }
        publishSnapshot(next, clearError = clearError, forcedSessionId = if (pendingSatisfied) pendingSession else null)
    }

    /// snapshot → chat UI 状态的字段映射（adoptSnapshot 与切会话贴缓存共用）。
    private fun publishSnapshot(next: RemotePanelSnapshot, clearError: Boolean, forcedSessionId: String? = null) {
        val projectId = chat.selectedProjectId
            ?: next.sessions.firstOrNull { it.id == next.currentSessionId }?.projectId
            ?: next.projects.firstOrNull()?.id
        val modelId = next.composer.modelID.ifBlank {
            next.models.firstOrNull { it.cli == next.composer.cli && it.isDefault }?.id ?: next.models.firstOrNull()?.id.orEmpty()
        }
        chat = chat.copy(
            projects = next.projects,
            models = next.models,
            sessions = next.sessions,
            selectedProjectId = projectId,
            selectedSessionId = forcedSessionId ?: next.currentSessionId ?: chat.selectedSessionId,
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
            // patch 驱动（含合并窗口 flush）不清除 lastError —— 否则
            // command_ack 的错误/拒绝提示会被下一个流式 patch 立刻抹掉，
            // 用户根本看不到。
            lastError = if (clearError) null else chat.lastError,
        )
        if (chat.config.supportsDirectHttp) {
            // 只在首次看到某项目时自动拉一次文件树；用户主动 selectProject /
            // refresh / openFile 已有显式 reloadFiles。
            val autoLoadProjectId = chat.selectedProject?.id
            if (autoLoadProjectId != null && autoLoadedFilesProjectId != autoLoadProjectId) {
                autoLoadedFilesProjectId = autoLoadProjectId
                viewModelScope.launch { reloadFiles() }
            }
        }
    }

    private fun applyRemotePatch(patch: com.codevoke.android.data.RemotePanelPatch) {
        panelStateSequence++
        val current = snapshot
        // patch 归属面板：当前 snapshot，或 per-session 缓存里的同名 base
        // （等待目标会话期间，目标会话自己的 patch 可以提前合到缓存上）。
        val base = when {
            current != null && current.sessionId == patch.sessionId -> current
            else -> snapshotCacheBySessionId[patch.sessionId]
        }
        if (base == null) {
            // 没有该 session 的 base。只有属于当前/等待目标的 patch 才主动
            // 补 snapshot；外会话 patch 直接丢，等它的 snapshot 自然到达。
            if (patch.sessionId == null ||
                patch.sessionId == pendingSessionFocusId ||
                patch.sessionId == chat.selectedSessionId
            ) {
                requestSnapshot(patch.sessionId ?: chat.selectedSessionId)
            }
            return
        }
        val merged = base.applyPatch(patch)
        if (merged == null) {
            // base 不匹配 —— 主动请求 fresh snapshot（对齐 iOS 行为）。
            requestSnapshot(patch.sessionId ?: base.currentSessionId ?: chat.selectedSessionId)
            return
        }
        snapshotCacheBySessionId[merged.sessionId] = merged
        if (base === current) {
            // mirror 状态必须先推进 —— 下一个 patch 的 baseRevision 校验依赖它。
            snapshot = merged
            // pending 会话过滤：等待目标期间，其它会话的 patch 只刷缓存不进 UI。
            val pending = pendingSessionFocusId
            if (pending != null && patch.sessionId != pending) return
            if (patch.isCosmeticOnly()) {
                pendingCosmeticSnapshot = merged
                scheduleCosmeticPublish()
            } else {
                cancelCosmeticPublish()
                adoptSnapshot(merged)
            }
        } else if (patch.sessionId == pendingSessionFocusId) {
            // 缓存里的目标会话被 patch 更新 → 认为 focus 已到位，立即发布。
            cancelCosmeticPublish()
            snapshot = merged
            adoptSnapshot(merged)
        }
    }

    /// 仅外观字段变化的 patch 允许合并发布；结构性字段（消息列表、会话、
    /// composer、运行状态等）一旦出现必须立即发布。
    private fun com.codevoke.android.data.RemotePanelPatch.isCosmeticOnly(): Boolean =
        projects == null && models == null && sessions == null &&
            currentSessionIdField == null && currentSessionId == null &&
            messages == null && queuedRequests == null && status == null &&
            isLoadingHistory == null && composer == null &&
            activeRunStartedAtField == null && activeRunStartedAt == null &&
            isMirroringRemoteSession == null && capabilities == null

    private fun scheduleCosmeticPublish() {
        if (cosmeticPublishJob != null) return
        cosmeticPublishJob = viewModelScope.launch {
            delay(COSMETIC_PUBLISH_DELAY_MS)
            cosmeticPublishJob = null
            val pending = pendingCosmeticSnapshot
            pendingCosmeticSnapshot = null
            if (pending != null) adoptSnapshot(pending)
        }
    }

    /// 结构性变化或上下文切换前丢弃未发布的合并快照 —— 否则迟到的 flush
    /// 会把切换前的旧状态（比如旧的 selectedSessionId）重新贴回 UI。
    private fun cancelCosmeticPublish() {
        cosmeticPublishJob?.cancel()
        cosmeticPublishJob = null
        pendingCosmeticSnapshot = null
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
        runCatching { RemoteLanClient(config, httpClientFor(config)).projectFiles(project.id, path) }
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
            // 只有 pending 还没被 snapshot 解决才兜底 —— 对齐 iOS pendingFocusTimeout。
            if (pendingProjectFocusId == projectId) {
                pendingProjectFocusId = null
                pendingProjectFocusJob = null
                sendRemoteCommand("requestSnapshot", sessionId = chat.selectedSessionId)
            }
        }
    }

    private fun scheduleSessionFocusTimeout(sessionId: String) {
        pendingSessionFocusJob?.cancel()
        pendingSessionFocusJob = viewModelScope.launch {
            delay(8_000)
            if (pendingSessionFocusId == sessionId) {
                pendingSessionFocusId = null
                pendingSessionFocusJob = null
                sendRemoteCommand("requestSnapshot", sessionId = sessionId)
            }
        }
    }

    private suspend fun waitForDirectRemoteChatReady() {
        repeat(160) {
            if (remoteChatClient.isReady || remoteChatClient.awaitReady(100)) return
        }
        remoteChatClient.disconnect()
        chat = chat.copy(connectionStatus = "未连接", lastError = "连接通道建立超时，请确认电脑端在线后重试。")
        throw IllegalStateException("连接通道建立超时，请确认电脑端在线后重试。")
    }

    /// 等到任意一个新 panel_state envelope 落地（含被门禁拒绝的 —— 那也是
    /// 连接活着的证据）。返回 false = ~3s 无响应，调用方应升级重连。
    private suspend fun waitForFreshSnapshot(baseline: Int): Boolean {
        repeat(30) {
            if (panelStateSequence != baseline) return true
            delay(100)
        }
        return false
    }

    private fun userMessage(error: Throwable, fallback: String = "请求失败。"): String {
        return error.localizedMessage?.takeIf { it.isNotBlank() } ?: fallback
    }

    private companion object {
        const val PREFS_NAME = "codevoke.lan"
        const val KEY_HOST = "host"
        const val KEY_PORT = "port"
        const val KEY_HOST_ID = "lastHostId"
        const val DEFAULT_PORT = 18765
        /// 契约 §6：单条 endpoint 3s 未握手即换下一条。
        const val PROBE_TIMEOUT_MS = 3000L
        const val COSMETIC_PUBLISH_DELAY_MS = 80L
    }
}
