package com.codevoke.android.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import okhttp3.OkHttpClient
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.TimeUnit

object LanNetworkSelector {
    fun wifiBoundClient(context: Context, connectTimeoutSeconds: Long = 8): OkHttpClient? {
        val network = wifiNetwork(context) ?: return null
        return OkHttpClient.Builder()
            .socketFactory(network.socketFactory)
            .connectTimeout(connectTimeoutSeconds, TimeUnit.SECONDS)
            .readTimeout(connectTimeoutSeconds, TimeUnit.SECONDS)
            .writeTimeout(connectTimeoutSeconds, TimeUnit.SECONDS)
            .build()
    }

    fun wifiNetwork(context: Context): android.net.Network? {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val active = cm.activeNetwork
        val activeCaps = active?.let { cm.getNetworkCapabilities(it) }
        if (activeCaps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) {
            return active
        }
        return cm.allNetworks.firstOrNull { network ->
            cm.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    }

    fun isOnWifi(context: Context): Boolean = wifiNetwork(context) != null

    fun defaultLanClient(connectTimeoutSeconds: Long = 8): OkHttpClient =
        OkHttpClient.Builder()
            .connectTimeout(connectTimeoutSeconds, TimeUnit.SECONDS)
            .readTimeout(connectTimeoutSeconds, TimeUnit.SECONDS)
            .writeTimeout(connectTimeoutSeconds, TimeUnit.SECONDS)
            .build()

    /** Prefer Wi-Fi bound client, then fall back to the process default route. */
    fun lanClientsForAttempt(context: Context, connectTimeoutSeconds: Long = 8): List<OkHttpClient> {
        val wifiClient = wifiBoundClient(context, connectTimeoutSeconds)
        val defaultClient = defaultLanClient(connectTimeoutSeconds)
        return if (wifiClient != null) listOf(wifiClient, defaultClient) else listOf(defaultClient)
    }

    fun localWifiIPv4(context: Context): String? {
        wifiNetwork(context)?.let { network ->
            (context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager)
                .getLinkProperties(network)
                ?.linkAddresses
                ?.firstOrNull { it.address is Inet4Address && !it.address.isLoopbackAddress }
                ?.address
                ?.hostAddress
                ?.takeIf { isPrivateIPv4(it) }
                ?.let { return it }
        }
        return NetworkInterface.getNetworkInterfaces().toList().flatMap { it.inetAddresses.toList() }
            .firstOrNull { !it.isLoopbackAddress && it is Inet4Address && isPrivateIPv4(it.hostAddress.orEmpty()) }
            ?.hostAddress
    }

    fun wifiSubnetPrefix(context: Context): String? {
        val ip = localWifiIPv4(context) ?: return null
        val octets = ip.split(".")
        if (octets.size != 4) return null
        return octets.take(3).joinToString(".")
    }

    fun isPrivateIPv4(host: String): Boolean {
        val octets = host.trim().split(".").mapNotNull { it.toIntOrNull() }
        if (octets.size != 4 || octets.any { it !in 0..255 }) return false
        return when (octets[0]) {
            10 -> true
            172 -> octets[1] in 16..31
            192 -> octets[1] == 168
            else -> false
        }
    }
}
