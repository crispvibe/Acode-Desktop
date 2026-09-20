package com.codevoke.android.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.net.Inet4Address
import java.net.NetworkInterface

object LanNetworkSelector {
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
