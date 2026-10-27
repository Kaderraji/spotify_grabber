package com.spotifygrabber.spotify_grabber

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities

/**
 * Whether the phone is downloading over Wi-Fi, for the Wi-Fi-only setting.
 *
 * The connection that matters is the default one: the phone may hold a Wi-Fi
 * link while sending everything over mobile data, and the reverse.
 */
object NetworkMonitor {

    fun isWifi(context: Context): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java)
            ?: return false
        val caps = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        return onWifi(caps)
    }

    /**
     * Reports every change of the default connection. Returns the callback so
     * the caller can stop watching; null when there is nothing to watch with.
     */
    fun watch(context: Context, onChange: (Boolean) -> Unit): ConnectivityManager.NetworkCallback? {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return null
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                onChange(isWifi(context))
            }

            override fun onLost(network: Network) {
                onChange(isWifi(context))
            }

            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities,
            ) {
                onChange(isWifi(context))
            }
        }
        manager.registerDefaultNetworkCallback(callback)
        return callback
    }

    fun stop(context: Context, callback: ConnectivityManager.NetworkCallback?) {
        if (callback == null) return
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return
        runCatching { manager.unregisterNetworkCallback(callback) }
    }

    /** Ethernet counts too: a docked phone is not on mobile data. */
    private fun onWifi(caps: NetworkCapabilities): Boolean =
        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
}
