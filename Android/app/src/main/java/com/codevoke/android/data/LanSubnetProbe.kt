package com.codevoke.android.data

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

object LanSubnetProbe {
    suspend fun discoverHealthHost(
        context: Context,
        port: Int,
        preferredHost: String? = null,
    ): String? = discoverHealthHosts(context, port, preferredHost).firstOrNull()

    suspend fun discoverHealthHosts(
        context: Context,
        port: Int,
        preferredHost: String? = null,
    ): List<String> = withContext(Dispatchers.IO) {
        val client = LanNetworkSelector.wifiBoundClient(context, connectTimeoutSeconds = 1)
            ?: OkHttpClient.Builder()
                .connectTimeout(1, TimeUnit.SECONDS)
                .readTimeout(1, TimeUnit.SECONDS)
                .build()
        val found = mutableListOf<String>()
        preferredHost?.takeIf { it.isNotBlank() }?.let { host ->
            if (healthOk(client, host, port)) found += host
        }
        val prefix = LanNetworkSelector.wifiSubnetPrefix(context) ?: return@withContext found
        coroutineScope {
            (1..254).chunked(40).forEach { chunk ->
                val hits = chunk.map { host ->
                    async {
                        val ip = "$prefix.$host"
                        if (ip == preferredHost) null else if (healthOk(client, ip, port)) ip else null
                    }
                }.awaitAll().filterNotNull()
                found += hits
            }
        }
        found
    }

    private fun healthOk(client: OkHttpClient, host: String, port: Int): Boolean =
        runCatching {
            val request = Request.Builder().url("http://$host:$port/health").build()
            client.newCall(request).execute().use { it.isSuccessful }
        }.getOrDefault(false)
}
