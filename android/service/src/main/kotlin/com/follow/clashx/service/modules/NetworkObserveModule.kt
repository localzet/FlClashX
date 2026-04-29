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

class NetworkObserveModule(
    service: Service,
    private val healthCheck: HealthCheckModule? = null,
) : Module(service) {

    companion object {
        private val gson = Gson()
    }

    private var registered = false
    private var currentNetwork: Network? = null
    private var lastCapabilities: NetworkCapabilities? = null

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            super.onAvailable(network)
            val prev = currentNetwork
            val wasLost = prev == null
            currentNetwork = network
            if (prev != null && prev != network) {
                GlobalState.log("Network changed: $prev -> $network, reconnecting core")
                resetAndCheck("network-change")
            } else if (wasLost) {
                GlobalState.log("Network restored: $network, resetting stale connections")
                resetAndCheck("network-restored")
            }
        }

        override fun onLost(network: Network) {
            super.onLost(network)
            if (currentNetwork == network) {
                GlobalState.log("Network lost: $network")
                currentNetwork = null
                lastCapabilities = null
            }
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            super.onCapabilitiesChanged(network, capabilities)
            if (network != currentNetwork) return
            val prev = lastCapabilities
            lastCapabilities = capabilities
            if (prev == null) return
            val hadInternet = prev.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            val hasInternet = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            if (!hadInternet && hasInternet) {
                GlobalState.log("Internet capability restored on $network")
                resetAndCheck("capability-restored")
            }
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            super.onLinkPropertiesChanged(network, linkProperties)
            val dns = linkProperties.dnsServers.map { it.hostAddress ?: "" }.filter { it.isNotBlank() }
            runCatching {
                com.follow.clashx.core.Core.updateDns(gson.toJson(dns))
            }.onFailure { GlobalState.log("updateDns failed: ${it.message}") }
        }
    }

    private fun resetAndCheck(reason: String) {
        runCatching { com.follow.clashx.core.Core.resetConnections() }
            .onFailure { GlobalState.log("resetConnections failed: ${it.message}") }
        healthCheck?.let { hc ->
            GlobalState.launch { hc.runCheck(reason) }
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
