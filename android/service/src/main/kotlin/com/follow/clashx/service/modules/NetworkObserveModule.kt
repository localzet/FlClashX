package com.follow.clashx.service.modules

import android.app.Service
import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import com.follow.clashx.common.GlobalState
import com.follow.clashx.service.Module
import com.google.gson.Gson

class NetworkObserveModule(service: Service) : Module(service) {
    private var registered = false
    private var currentNetwork: Network? = null

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            super.onAvailable(network)
            val prev = currentNetwork
            currentNetwork = network
            if (prev != null && prev != network) {
                GlobalState.log("Network changed: $prev -> $network, resetting connections")
                runCatching { com.follow.clashx.core.Core.resetConnections() }
                    .onFailure { GlobalState.log("resetConnections failed: ${it.message}") }
            }
        }

        override fun onLost(network: Network) {
            super.onLost(network)
            if (currentNetwork == network) {
                currentNetwork = null
            }
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            super.onLinkPropertiesChanged(network, linkProperties)
            val dns = linkProperties.dnsServers.map { it.hostAddress ?: "" }.filter { it.isNotBlank() }
            runCatching {
                com.follow.clashx.core.Core.updateDns(Gson().toJson(dns))
            }.onFailure { GlobalState.log("updateDns failed: ${it.message}") }
        }
    }

    override suspend fun install() {
        val cm = service.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        runCatching {
            cm.registerNetworkCallback(request, callback)
            registered = true
        }.onFailure { GlobalState.log("registerNetworkCallback failed: ${it.message}") }
    }

    override suspend fun uninstall() {
        if (!registered) return
        val cm = service.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        runCatching { cm.unregisterNetworkCallback(callback) }
        registered = false
    }
}
