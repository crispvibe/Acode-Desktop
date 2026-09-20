package com.codevoke.android.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.concurrent.TimeUnit
import javax.net.SocketFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.X509TrustManager

/** 单个可达地址，对应契约 eps 元素 {"a": 地址, "p": 端口}。 */
data class WanEndpoint(
    val address: String,
    val port: Int,
) {
    /** IPv6 字面量进 URL 必须加方括号。 */
    val urlHost: String get() = if (':' in address) "[${address.trim()}]" else address.trim()
    val httpsBaseUrl: String get() = "https://$urlHost:$port"
    val chatWssUrl: String get() = "wss://$urlHost:$port/chat"
    val isLanAddress: Boolean
        get() = LanNetworkSelector.isPrivateIPv4(address) ||
            address.startsWith("fe80:", ignoreCase = true) ||
            address == "localhost" || address == "127.0.0.1" || address == "::1"

    fun toJson(): JSONObject = JSONObject().put("a", address).put("p", port)

    companion object {
        fun fromJson(json: JSONObject): WanEndpoint? {
            val address = json.optString("a").trim()
            val port = json.optInt("p", 0)
            return if (address.isBlank() || port !in 1..65535) null else WanEndpoint(address, port)
        }

        fun listFrom(array: JSONArray?): List<WanEndpoint> =
            array?.objects()?.mapNotNull { fromJson(it) }?.distinct().orEmpty()
    }
}

/**
 * 已配对设备（契约 §6 EndpointStore 记录：hostId/name/token/certFP/eps/lastGood/updatedAt）。
 * hostId 取 certFP —— 本协议里 SPKI pin 就是主机身份；证书轮换后指纹变，必须重新配对。
 */
data class PairedHost(
    val hostId: String,
    val name: String,
    val token: String,
    val certFP: String,
    val eps: List<WanEndpoint>,
    val lastGood: WanEndpoint?,
    val updatedAt: Long,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", hostId)
        .put("name", name)
        .put("token", token)
        .put("fp", certFP)
        .put("eps", JSONArray().also { arr -> eps.forEach { arr.put(it.toJson()) } })
        .put("lastGood", lastGood?.toJson() ?: JSONObject.NULL)
        .put("updatedAt", updatedAt)

    companion object {
        fun fromJson(json: JSONObject): PairedHost? {
            val id = json.optString("id").trim()
            val token = json.optString("token")
            val fp = json.optString("fp").lowercase()
            if (id.isBlank() || token.isBlank() || fp.isBlank()) return null
            return PairedHost(
                hostId = id,
                name = json.optString("name").ifBlank { "电脑" },
                token = token,
                certFP = fp,
                eps = WanEndpoint.listFrom(json.optJSONArray("eps")),
                lastGood = json.optJSONObject("lastGood")?.let { WanEndpoint.fromJson(it) },
                updatedAt = json.optLong("updatedAt", 0L),
            )
        }
    }
}

/** wss+token 握手探测结果。区分证书/鉴权失败（需重新配对）与单纯不可达（地址可能已变化）。 */
enum class WanProbeResult { Success, AuthFailed, PinMismatch, Failed }

data class WanHealth(val proto: Int, val pair: Boolean, val name: String)

data class WanConnectInfo(val name: String, val eps: List<WanEndpoint>)

/**
 * WAN/LAN 统一直连客户端（契约 §4、§6）：
 * - 已配对连接：TLS 只认 SPKI-SHA256 pin，忽略 CN/SAN/有效期/链；所有 HTTP/WS 带 Bearer token。
 * - 发现与配对：此时还没有 pin，用信任任意证书的 client（仅 /health、/pair，不发送 token）。
 */
object RemoteWanClient {
    const val PAIR_LINK_PREFIX = "acode://pair?d="

    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    /** 只认 SPKI-SHA256 pin 的 TrustManager：忽略 CN/SAN/有效期/链，不匹配即失败（契约 §4.3）。 */
    private class SpkiPinTrustManager(pinHex: String) : X509TrustManager {
        private val expectedPin = pinHex.lowercase()

        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
            throw CertificateException("client certificates not supported")
        }

        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
            val cert = chain.firstOrNull()
                ?: throw CertificateException("server presented no certificate")
            if (sha256Hex(cert.publicKey.encoded) != expectedPin) {
                throw CertificateException("server SPKI pin mismatch")
            }
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    /** 信任任意证书：仅用于配对前的 /health 发现与 /pair（6 位码本身是鉴权），禁止携带 token。 */
    private class TrustAllManager : X509TrustManager {
        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit
        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = Unit
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    private fun sslContextFor(trustManager: X509TrustManager): SSLContext =
        SSLContext.getInstance("TLS").apply { init(null, arrayOf(trustManager), SecureRandom()) }

    private fun pinnedClientBuilder(certFP: String): OkHttpClient.Builder {
        val trustManager = SpkiPinTrustManager(certFP)
        return OkHttpClient.Builder()
            .sslSocketFactory(sslContextFor(trustManager).socketFactory, trustManager)
            // pin 即身份；CN/SAN/有效期一律不校验（契约 §4.3）。
            .hostnameVerifier { _, _ -> true }
    }

    /** 已配对 HTTP client（/connect_info、/attachments、文件树等）。socketFactory 用于绑定 Wi-Fi 网卡。 */
    fun httpClient(certFP: String, socketFactory: SocketFactory? = null, timeoutSec: Long = 8): OkHttpClient =
        pinnedClientBuilder(certFP)
            .connectTimeout(timeoutSec, TimeUnit.SECONDS)
            .readTimeout(timeoutSec, TimeUnit.SECONDS)
            .writeTimeout(timeoutSec, TimeUnit.SECONDS)
            .apply { socketFactory?.let { socketFactory(it) } }
            .build()

    /** 已配对 WebSocket client（/chat）。 */
    fun wsClient(certFP: String, socketFactory: SocketFactory? = null, connectTimeoutSec: Long = 15): OkHttpClient =
        pinnedClientBuilder(certFP)
            .connectTimeout(connectTimeoutSec, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS)
            .pingInterval(20, TimeUnit.SECONDS)
            .apply { socketFactory?.let { socketFactory(it) } }
            .build()

    /** 发现/配对专用 client：信任任意证书，仅用于 /health 与 /pair。 */
    fun discoveryClient(socketFactory: SocketFactory? = null, timeoutSec: Long = 8): OkHttpClient {
        val trustManager = TrustAllManager()
        return OkHttpClient.Builder()
            .sslSocketFactory(sslContextFor(trustManager).socketFactory, trustManager)
            .hostnameVerifier { _, _ -> true }
            .connectTimeout(timeoutSec, TimeUnit.SECONDS)
            .readTimeout(timeoutSec, TimeUnit.SECONDS)
            .writeTimeout(timeoutSec, TimeUnit.SECONDS)
            .apply { socketFactory?.let { socketFactory(it) } }
            .build()
    }

    /** GET /health：无鉴权发现端点。proto:2 表示鉴权服务器（契约 §4.2）。 */
    suspend fun health(client: OkHttpClient, endpoint: WanEndpoint): WanHealth? = withContext(Dispatchers.IO) {
        runCatching {
            client.newCall(Request.Builder().url("${endpoint.httpsBaseUrl}/health").build()).execute().use { response ->
                if (!response.isSuccessful) return@use null
                val json = JSONObject(response.body?.string().orEmpty())
                WanHealth(
                    proto = json.optInt("proto"),
                    pair = json.optBoolean("pair"),
                    name = json.optString("name"),
                )
            }
        }.getOrNull()
    }

    /**
     * POST /pair（仅私网来源）：6 位码 + deviceName 换 {token, fp, name, eps}。
     * 这里信任任意证书属预期（TOFU）：配对码即鉴权，返回的 fp 之后固定 pin 住。
     * 成功返回的 PairedHost 把配对所用地址并入 eps 且置为 lastGood —— 配对通常发生在
     * 同一局域网，host 发布的 eps 未必包含当前可达的 LAN 地址。
     */
    suspend fun pair(client: OkHttpClient, endpoint: WanEndpoint, code: String, deviceName: String): PairedHost =
        withContext(Dispatchers.IO) {
            val payload = JSONObject().put("code", code).put("deviceName", deviceName)
            val request = Request.Builder()
                .url("${endpoint.httpsBaseUrl}/pair")
                .post(payload.toString().toRequestBody(jsonMediaType))
                .build()
            client.newCall(request).execute().use { response ->
                val raw = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    val detail = runCatching { JSONObject(raw).optString("message", JSONObject(raw).optString("error")) }
                        .getOrNull().orEmpty()
                    throw RemoteApiException(
                        when {
                            detail.isNotBlank() -> detail
                            response.code == 403 -> "配对码无效或已过期，请在电脑端重新生成配对码。"
                            response.code == 429 -> "配对尝试过于频繁，请稍后再试。"
                            else -> "配对失败：${response.code}"
                        },
                    )
                }
                val json = JSONObject(raw)
                val token = json.optString("token")
                val fp = json.optString("fp").lowercase()
                if (token.isBlank() || fp.length != 64) {
                    throw RemoteApiException("配对响应缺少 token 或证书指纹。")
                }
                PairedHost(
                    hostId = fp,
                    name = json.optString("name").ifBlank { "电脑" },
                    token = token,
                    certFP = fp,
                    eps = (listOf(endpoint) + WanEndpoint.listFrom(json.optJSONArray("eps"))).distinct(),
                    lastGood = endpoint,
                    updatedAt = System.currentTimeMillis(),
                )
            }
        }

    /** GET /connect_info：Bearer 鉴权，返回 {name, eps}，同 LAN 静默刷新地址用（契约 §6）。 */
    suspend fun connectInfo(client: OkHttpClient, endpoint: WanEndpoint, token: String): WanConnectInfo? =
        withContext(Dispatchers.IO) {
            runCatching {
                val request = Request.Builder()
                    .url("${endpoint.httpsBaseUrl}/connect_info")
                    .header("Authorization", "Bearer $token")
                    .build()
                client.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) return@use null
                    val json = JSONObject(response.body?.string().orEmpty())
                    WanConnectInfo(
                        name = json.optString("name"),
                        eps = WanEndpoint.listFrom(json.optJSONArray("eps")),
                    )
                }
            }.getOrNull()
        }

    /**
     * wss+token 握手探测：打开 /chat 升级请求，onOpen 即成功并立即关闭。
     * 单条 timeoutMillis 未握手即失败（契约 §6：3s）。401 → AuthFailed，
     * TLS pin 不匹配 → PinMismatch，其余 → Failed。
     */
    suspend fun probeChat(
        endpoint: WanEndpoint,
        token: String,
        certFP: String,
        socketFactory: SocketFactory? = null,
        timeoutMillis: Long = 3000,
    ): WanProbeResult = withContext(Dispatchers.IO) {
        val client = wsClient(
            certFP = certFP,
            socketFactory = socketFactory,
            connectTimeoutSec = (timeoutMillis / 1000).coerceAtLeast(1),
        )
        val done = CompletableDeferred<WanProbeResult>()
        val request = Request.Builder()
            .url(endpoint.chatWssUrl)
            .header("Authorization", "Bearer $token")
            .build()
        var socket: WebSocket? = null
        try {
            socket = client.newWebSocket(request, object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    if (done.complete(WanProbeResult.Success)) webSocket.close(1000, "probe done")
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    done.complete(
                        when {
                            response?.code == 401 -> WanProbeResult.AuthFailed
                            isCertificateFailure(t) -> WanProbeResult.PinMismatch
                            else -> WanProbeResult.Failed
                        },
                    )
                }
            })
            withTimeoutOrNull(timeoutMillis) { done.await() } ?: WanProbeResult.Failed
        } finally {
            socket?.cancel()
            client.dispatcher.executorService.shutdown()
            client.connectionPool.evictAll()
        }
    }

    /** 解析 `acode://pair?d=<base64url(JSON)>` 连接串（契约 §4.4）。 */
    fun parsePairLink(raw: String): PairedHost? {
        val trimmed = raw.trim()
        if (!trimmed.startsWith(PAIR_LINK_PREFIX)) return null
        val encoded = trimmed.removePrefix(PAIR_LINK_PREFIX)
            .substringBefore('&')
            .substringBefore('#')
        val json = runCatching {
            JSONObject(String(Base64.getUrlDecoder().decode(encoded), Charsets.UTF_8))
        }.getOrNull() ?: return null
        if (json.optInt("v") != 1) return null
        val token = json.optString("t")
        val fp = json.optString("fp").lowercase()
        val eps = WanEndpoint.listFrom(json.optJSONArray("eps"))
        if (token.isBlank() || fp.length != 64 || eps.isEmpty()) return null
        return PairedHost(
            hostId = fp,
            name = json.optString("n").ifBlank { "电脑" },
            token = token,
            certFP = fp,
            eps = eps,
            lastGood = null,
            updatedAt = System.currentTimeMillis(),
        )
    }

    /** 沿 cause 链识别 TLS 证书/指纹校验失败（pin 不匹配是确定性失败，重试无意义）。 */
    fun isCertificateFailure(t: Throwable): Boolean {
        var current: Throwable? = t
        while (current != null) {
            if (current is SSLPeerUnverifiedException || current is CertificateException) return true
            current = current.cause
        }
        return false
    }

    private fun sha256Hex(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
}
