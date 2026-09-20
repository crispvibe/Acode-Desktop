package com.codevoke.android.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys
import org.json.JSONArray

/**
 * EndpointStore（契约 §6）：持久化 [{hostId, name, token, certFP, eps[], lastGood, updatedAt}]。
 * token 属敏感数据，存 EncryptedSharedPreferences（项目此前只用普通 SharedPreferences 存
 * 非敏感的 host/port，没有现成的敏感数据存储惯例，按任务要求新建）。
 * security-crypto 1.0.0 稳定版 API：MasterKeys.getOrCreate 生成 AndroidKeyStore 主密钥别名。
 */
class EndpointStore(context: Context) {

    private val prefs: SharedPreferences = runCatching {
        val masterKeyAlias = MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC)
        EncryptedSharedPreferences.create(
            FILE_NAME,
            masterKeyAlias,
            context,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }.getOrElse {
        // 极少数设备 Keystore 损坏时降级为普通偏好存储，避免 App 直接崩溃。
        context.getSharedPreferences("$FILE_NAME.fallback", Context.MODE_PRIVATE)
    }

    @Synchronized
    fun list(): List<PairedHost> =
        runCatching { JSONArray(prefs.getString(KEY_HOSTS, "[]").orEmpty()) }
            .getOrElse { JSONArray() }
            .objects()
            .mapNotNull { PairedHost.fromJson(it) }

    fun get(hostId: String): PairedHost? = list().firstOrNull { it.hostId == hostId }

    @Synchronized
    fun upsert(host: PairedHost) {
        val next = list().filterNot { it.hostId == host.hostId } +
            host.copy(updatedAt = System.currentTimeMillis())
        save(next)
    }

    @Synchronized
    fun remove(hostId: String) {
        save(list().filterNot { it.hostId == hostId })
    }

    @Synchronized
    fun markLastGood(hostId: String, endpoint: WanEndpoint) {
        save(
            list().map {
                if (it.hostId == hostId) it.copy(lastGood = endpoint, updatedAt = System.currentTimeMillis()) else it
            },
        )
    }

    /**
     * /connect_info 静默刷新：更新名字与地址列表，保留 lastGood。
     * reachableVia（当前扫到并完成握手的 LAN 地址）并入 eps，保证下次竞速能用到它。
     */
    @Synchronized
    fun refreshEndpoints(hostId: String, name: String?, eps: List<WanEndpoint>, reachableVia: WanEndpoint? = null) {
        save(
            list().map { host ->
                if (host.hostId != hostId) {
                    host
                } else {
                    host.copy(
                        name = name?.takeIf { it.isNotBlank() } ?: host.name,
                        eps = (listOfNotNull(reachableVia) + eps + host.eps).distinct(),
                        updatedAt = System.currentTimeMillis(),
                    )
                }
            },
        )
    }

    private fun save(hosts: List<PairedHost>) {
        val array = JSONArray()
        hosts.forEach { array.put(it.toJson()) }
        prefs.edit().putString(KEY_HOSTS, array.toString()).apply()
    }

    private companion object {
        const val FILE_NAME = "acode.endpoints"
        const val KEY_HOSTS = "hosts"
    }
}
