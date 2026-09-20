package com.codevoke.android.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

class RemoteChatClient(
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val defaultClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build(),
) {
    @Volatile
    var onStatus: ((String) -> Unit)? = null
    @Volatile
    var onError: ((String?) -> Unit)? = null
    @Volatile
    var onSnapshot: ((RemotePanelSnapshot) -> Unit)? = null
    @Volatile
    var onPatch: ((RemotePanelPatch) -> Unit)? = null
    @Volatile
    var onAck: ((commandId: String, status: String, message: String?, sessionId: String?) -> Unit)? = null
    /// 连续重连失败多轮后回调：当前端点大概率已失效（Wi-Fi/蜂窝切换、
    /// host 重启换址），上层应重跑 endpoint 竞速而不是继续死磕旧地址。
    @Volatile
    var onConnectionStale: (() -> Unit)? = null
    @Volatile
    var isConnected: Boolean = false
        private set
    @Volatile
    var isTransportConnected: Boolean = false
        private set
    val isReady: Boolean get() = isConnected

    // 以下字段被主线程（ViewModel 调用）与 OkHttp 回调线程/reconnectJob
    // （Dispatchers.IO）双向读写 —— @Volatile 保证可见性，connect/disconnect
    // 用 @Synchronized 串行化，避免两轮连接交错互相覆盖。
    @Volatile
    private var webSocket: WebSocket? = null
    @Volatile
    private var config: RemoteChatConfig? = null
    @Volatile
    private var activeClient: OkHttpClient = defaultClient
    @Volatile
    private var reconnectSessionId: String? = null
    @Volatile
    private var reconnectLastRevision: Int? = null
    @Volatile
    private var reconnectJob: Job? = null
    @Volatile
    private var reconnectAttempt = 0
    @Volatile
    private var intentionallyClosed = false
    @Volatile
    private var connectionGeneration = 0
    @Volatile
    private var readySignal: CompletableDeferred<Boolean> = CompletableDeferred()

    @Synchronized
    fun connect(
        config: RemoteChatConfig,
        focusedSessionId: String? = null,
        lastRevision: Int? = null,
        client: OkHttpClient? = null,
    ) {
        disconnect()
        val generation = ++connectionGeneration
        this.config = config
        // 重连（scheduleReconnect 不传 client）必须沿用首次连接用的
        // pinned/wifi-bound client，否则 TLS pin 或网卡绑定会丢失。
        activeClient = client ?: activeClient
        reconnectSessionId = focusedSessionId
        reconnectLastRevision = lastRevision
        intentionallyClosed = false
        resetReadySignal()
        isTransportConnected = false
        onStatus?.invoke("连接中")
        val requestBuilder = Request.Builder().url(config.webSocketUrl)
        // 契约 §4.2：/chat upgrade 请求头带 Authorization，鉴权失败在 101 之前回 401。
        if (config.token.isNotBlank()) {
            requestBuilder.header("Authorization", "Bearer ${config.token}")
        }
        webSocket = activeClient.newWebSocket(requestBuilder.build(), Listener(focusedSessionId, lastRevision, generation))
    }

    @Synchronized
    fun disconnect() {
        intentionallyClosed = true
        isTransportConnected = false
        completeReadySignal(false)
        connectionGeneration += 1
        reconnectJob?.cancel()
        reconnectJob = null
        // close() 是优雅关闭（要等对方回 close 帧），网络已死时会滞留；
        // cancel() 立即释放 socket —— 后台挂起/手动断开都要求资源当场归还。
        webSocket?.close(1000, "client closing")
        webSocket?.cancel()
        webSocket = null
    }

    fun updateResumeContext(focusedSessionId: String?, lastRevision: Int?) {
        reconnectSessionId = focusedSessionId
        reconnectLastRevision = lastRevision
    }

    suspend fun awaitReady(timeoutMillis: Long? = null): Boolean {
        if (isReady) return true
        val signal = readySignal
        return if (timeoutMillis == null) {
            signal.await()
        } else {
            withTimeoutOrNull(timeoutMillis) { signal.await() } ?: false
        }
    }

    fun sendResume(sessionId: String?, lastRevision: Int?) {
        // JSONObject.put(k, null) 会移除键；host 端 schema 要求键存在（值可为 null）。
        val frame = JSONObject()
            .put("type", "resume")
            .put("sessionId", sessionId ?: JSONObject.NULL)
            .put("lastRevision", lastRevision ?: JSONObject.NULL)
        if (webSocket?.send(frame.toString()) != true) {
            onError?.invoke("远程连接暂不可用，正在等待重连。")
        }
    }

    fun sendCommand(op: String, sessionId: String? = null, args: JSONObject = JSONObject(), commandId: String = UUID.randomUUID().toString()): String {
        val frame = JSONObject()
            .put("type", "command")
            .put("commandId", commandId)
            .put("op", op)
            .put("sessionId", sessionId)
            .put("args", args)
        if (webSocket?.send(frame.toString()) != true) {
            onError?.invoke("命令已排队，远程连接恢复后会重试。")
        }
        return commandId
    }

    private fun scheduleReconnect() {
        val nextConfig = config ?: return
        if (intentionallyClosed) return
        val seconds = when (reconnectAttempt.coerceAtMost(5)) {
            0 -> 1L
            1 -> 2L
            2 -> 4L
            3 -> 8L
            4 -> 16L
            else -> 30L
        }
        reconnectAttempt = (reconnectAttempt + 1).coerceAtMost(5)
        reconnectJob?.cancel()
        // 调度时记下一代际：等待期间若有新的 connect()/disconnect()，到点
        // 必须放弃 —— 否则旧 job 会用陈旧 session/revision 覆盖新连接。
        val scheduledGeneration = connectionGeneration
        reconnectJob = scope.launch {
            delay(seconds * 1000)
            if (scheduledGeneration != connectionGeneration || intentionallyClosed) return@launch
            connect(nextConfig, reconnectSessionId, reconnectLastRevision)
        }
        // 已连续失败多轮（约 ≥7s）：通知上层重竞速 endpoint。
        if (reconnectAttempt >= 3) {
            onConnectionStale?.invoke()
        }
    }

    private fun resetReadySignal() {
        isConnected = false
        completeReadySignal(false)
        readySignal = CompletableDeferred()
    }

    private fun completeReadySignal(ready: Boolean) {
        isConnected = ready
        if (readySignal.isCompleted) readySignal = CompletableDeferred()
        if (!readySignal.isCompleted) readySignal.complete(ready)
    }

    private fun markReady(generation: Int) {
        if (generation != connectionGeneration) return
        if (!isConnected) onStatus?.invoke("已连接")
        completeReadySignal(true)
    }

    private inner class Listener(
        private val focusedSessionId: String?,
        private val lastRevision: Int?,
        private val generation: Int,
    ) : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            if (generation != connectionGeneration) return
            reconnectAttempt = 0
            isTransportConnected = true
            sendResume(focusedSessionId, lastRevision)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            if (generation != connectionGeneration) return
            val json = runCatching { JSONObject(text) }.getOrNull() ?: return
            when (json.optString("type")) {
                "panel_state" -> {
                    markReady(generation)
                    when (json.optString("kind")) {
                        "snapshot" -> json.optJSONObject("snapshot")?.let { onSnapshot?.invoke(it.toPanelSnapshot()) }
                        "patch" -> json.optJSONObject("patch")?.let { onPatch?.invoke(it.toPanelPatch()) }
                    }
                }
                "command_ack" -> {
                    markReady(generation)
                    onAck?.invoke(
                        json.optString("commandId"),
                        json.optString("status"),
                        json.stringOrNull("message"),
                        json.stringOrNull("sessionId"),
                    )
                }
                "hello" -> markReady(generation)
            }
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            if (generation != connectionGeneration) return
            isTransportConnected = false
            completeReadySignal(false)
            onStatus?.invoke("未连接")
            scheduleReconnect()
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            if (generation != connectionGeneration) return
            isTransportConnected = false
            completeReadySignal(false)
            onStatus?.invoke("未连接")
            // 401（token 失效）与证书指纹不匹配都是确定性失败，重试无意义，
            // 需重新配对 —— 停止自动重连，避免无限循环；错误归类为可执行文案，
            // 不把 SSL/HTTP 原始异常串直接弹给用户。
            val authFailed = response?.code == 401
            val certFailed = RemoteWanClient.isCertificateFailure(t)
            onError?.invoke(
                when {
                    authFailed -> "鉴权失败，请删除该设备后重新配对。"
                    certFailed -> "电脑端证书已更换，请删除该设备后重新配对。"
                    else -> t.localizedMessage
                },
            )
            if (authFailed || certFailed) {
                intentionallyClosed = true
                return
            }
            scheduleReconnect()
        }
    }
}
