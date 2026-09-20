package com.codevoke.android.data

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

/** 子网扫到的 proto:2 主机。pairedHostId 由 ViewModel 静默刷新阶段回填。 */
data class LanDiscoveredHost(
    val address: String,
    val name: String,
    val port: Int,
    val pairedHostId: String? = null,
)

object LanSubnetProbe {
    /**
     * 扫描当前 Wi-Fi 网段内响应 https /health 且 proto:2（鉴权服务器）的主机。
     * 契约 §4.1 起服务端全 TLS，发现阶段尚未配对不知道 pin，故用信任任意证书的
     * discoveryClient —— /health 不携带任何凭据，仅取 proto/pair/name。
     */
    suspend fun discoverHealthHosts(
        context: Context,
        port: Int,
        preferredHost: String? = null,
    ): List<LanDiscoveredHost> = withContext(Dispatchers.IO) {
        val socketFactory = LanNetworkSelector.wifiNetwork(context)?.socketFactory
        val client = RemoteWanClient.discoveryClient(socketFactory = socketFactory, timeoutSec = 2)
        val found = mutableListOf<LanDiscoveredHost>()
        preferredHost?.takeIf { it.isNotBlank() }?.let { host ->
            healthInfo(client, host, port)?.let { found += it }
        }
        val prefix = LanNetworkSelector.wifiSubnetPrefix(context) ?: return@withContext found
        coroutineScope {
            (1..254).chunked(40).forEach { chunk ->
                val hits = chunk.map { host ->
                    async {
                        val ip = "$prefix.$host"
                        if (ip == preferredHost) null else healthInfo(client, ip, port)
                    }
                }.awaitAll().filterNotNull()
                found += hits
            }
        }
        found
    }

    private suspend fun healthInfo(client: OkHttpClient, host: String, port: Int): LanDiscoveredHost? =
        RemoteWanClient.health(client, WanEndpoint(host, port))
            ?.takeIf { it.proto == 2 }
            ?.let { LanDiscoveredHost(address = host, name = it.name, port = port) }
}
