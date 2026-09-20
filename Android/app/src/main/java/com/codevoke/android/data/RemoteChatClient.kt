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
    var onStatus: ((String) -> Unit)? = null
    var onError: ((String?) -> Unit)? = null
    var onSnapshot: ((RemotePanelSnapshot) -> Unit)? = null
    var onPatch: ((RemotePanelPatch) -> Unit)? = null
    var onAck: ((commandId: String, status: String, message: String?, sessionId: String?) -> Unit)? = null
    @Volatile
    var isConnected: Boolean = false
        private set
    @Volatile
    var isTransportConnected: Boolean = false
        private set
    val isReady: Boolean get() = isConnected

    private var webSocket: WebSocket? = null
    private var config: RemoteChatConfig? = null
    private var activeClient: OkHttpClient = defaultClient
    private var reconnectSessionId: String? = null
    private var reconnectLastRevision: Int? = null
    private var reconnectJob: Job? = null
    private var reconnectAttempt = 0
    private var intentionallyClosed = false
    private var connectionGeneration = 0
    @Volatile
    private var readySignal: CompletableDeferred<Boolean> = CompletableDeferred()

    fun connect(
        config: RemoteChatConfig,
        focusedSessionId: String? = null,
        lastRevision: Int? = null,
        client: OkHttpClient? = null,
    ) {
        disconnect()
        val generation = ++connectionGeneration
        this.config = config
        activeClient = client ?: defaultClient
        reconnectSessionId = focusedSessionId
        reconnectLastRevision = lastRevision
        intentionallyClosed = false
        resetReadySignal()
        isTransportConnected = false
        onStatus?.invoke("连接中")
        val request = Request.Builder()
            .url(config.webSocketUrl)
            .build()
        webSocket = activeClient.newWebSocket(request, Listener(focusedSessionId, lastRevision, generation))
    }

    fun disconnect() {
        intentionallyClosed = true
        isTransportConnected = false
        completeReadySignal(false)
        connectionGeneration += 1
        reconnectJob?.cancel()
        reconnectJob = null
        webSocket?.close(1000, "client closing")
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
        reconnectJob = scope.launch {
            delay(seconds * 1000)
            connect(nextConfig, reconnectSessionId, reconnectLastRevision)
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
            onError?.invoke(t.localizedMessage)
            if (response?.code == 401) {
                intentionallyClosed = true
                return
            }
            scheduleReconnect()
        }
    }
}
