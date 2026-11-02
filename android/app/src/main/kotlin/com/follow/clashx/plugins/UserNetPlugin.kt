// SPDX-FileCopyrightText: 2026 Ivan Zorin <creator@localzet.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// Source: https://github.com/localzet/FlClashX

package com.follow.clashx.plugins

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URI
import java.net.URL
import java.util.concurrent.TimeUnit
import java.util.IdentityHashMap
import java.util.UUID

data object UserNetPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private const val CHANNEL = "usernet_transport"
    private val channels = IdentityHashMap<BinaryMessenger, MethodChannel>()
    private var context: Context? = null
    private var process: Process? = null
    private var writer: BufferedWriter? = null
    private var readerThread: Thread? = null
    private data class Launch(
        val platform: String, val joinLink: String, val socksPort: Int,
        val serviceUserId: String?, val serviceCredential: String?,
        val workPlatform: String, val egressId: String,
    )
    private var recoveryLaunch: Launch? = null
    private var networkManager: ConnectivityManager? = null
    private var physicalNetwork: Network? = null
    private var observedNetwork = false
    private var pendingNetworkRestart: Runnable? = null
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) ||
                !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return
            mainHandler.post { handlePhysicalNetwork(network) }
        }
        override fun onLost(network: Network) {
            mainHandler.post {
                if (physicalNetwork == network) handlePhysicalNetwork(null)
            }
        }
    }

    @Volatile private var generation = 0L
    private var verificationTicket = 0L
    private var activeStage = "transport"
    private var controlState = "idle"
    private var transportState = "idle"
    private var controlCarrier = ""
    private var transportCarrier = ""
    @Volatile private var lastStatus = "STOPPED"
    private val mainHandler = Handler(Looper.getMainLooper())

    @Synchronized
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        if (networkManager == null) {
            val manager = binding.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val request = NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build()
                manager.registerBestMatchingNetworkCallback(request, networkCallback, mainHandler)
            } else {
                manager.registerDefaultNetworkCallback(networkCallback)
            }
            networkManager = manager
        }
        channels[binding.binaryMessenger] = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    @Synchronized
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channels.remove(binding.binaryMessenger)?.setMethodCallHandler(null)
        if (channels.isEmpty()) {
            networkManager?.unregisterNetworkCallback(networkCallback)
            networkManager = null
            physicalNetwork = null
            observedNetwork = false
            pendingNetworkRestart?.let(mainHandler::removeCallbacks)
            pendingNetworkRestart = null
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> runCatching {
                val link = requireNotNull(call.argument<String>("joinLink"))
                val platform = call.argument<String>("platform") ?: "wbstream"
                val port = call.argument<Int>("socksPort") ?: 17890
                start(
                    platform = platform,
                    joinLink = link,
                    socksPort = port,
                    serviceUserId = call.argument("serviceUserId"),
                    serviceCredential = call.argument("serviceCredential"),
                    workPlatform = call.argument<String>("workPlatform") ?: "telemost",
                    egressId = call.argument<String>("egressId") ?: "auto",
                )
            }.onSuccess { result.success(null) }
                .onFailure { result.error("USERNET_START", it.message, null) }
            "stop" -> {
                stop()
                result.success(null)
            }
            "isRunning" -> result.success(process?.isAlive == true)
            "getStatus" -> result.success(lastStatus)
            "getConnectionState" -> result.success(synchronized(this) {
                mapOf("status" to lastStatus, "controlState" to controlState,
                    "transportState" to transportState, "controlCarrier" to controlCarrier,
                    "transportCarrier" to transportCarrier)
            })
            "probe" -> probe(result)
            "request" -> request(call, result)
            else -> result.notImplemented()
        }
    }

    @Synchronized
    private fun handlePhysicalNetwork(network: Network?) {
        if (physicalNetwork == network) return
        val changed = observedNetwork
        physicalNetwork = network
        observedNetwork = true
        pendingNetworkRestart?.let(mainHandler::removeCallbacks)
        pendingNetworkRestart = null
        if (!changed) return
        Log.i("UserNet", if (network == null) "network: unavailable" else "network: changed")
        val expectedGeneration = generation
        val request = synchronized(this) {
            if (process?.isAlive != true) return
            recoveryLaunch ?: return
        }
        emit("status", "RECONNECTING", expectedGeneration)
        if (network == null) return
        val restart = Runnable {
            Thread {
                synchronized(this) {
                    if (generation != expectedGeneration || process?.isAlive != true) return@Thread
                    stop(resetState = false)
                    emit("status", "RECONNECTING")
                    runCatching {
                        start(request.platform, request.joinLink, request.socksPort,
                            request.serviceUserId, request.serviceCredential, request.workPlatform, request.egressId)
                    }.onFailure { emit("status", "ERROR:NETWORK_RECOVERY") }
                }
            }.apply { name = "UserNet-network-recovery"; isDaemon = true; start() }
        }
        pendingNetworkRestart = restart
        mainHandler.postDelayed(restart, 750)
    }

    private fun probe(result: MethodChannel.Result) {
        Thread {
            val reachable = runCatching {
                val connection = URL("https://api.userlay.com/app/v1/plans")
                    .openConnection() as HttpURLConnection
                try {
                    connection.requestMethod = "GET"
                    connection.connectTimeout = 3_000
                    connection.readTimeout = 3_000
                    connection.instanceFollowRedirects = false
                    val status = connection.responseCode
                    if (status !in 200..299 && status != 401 && status != 403) {
                        false
                    } else {
                        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
                        val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
                        val trimmed = body.trim()
                        if (trimmed.startsWith("{")) {
                            JSONObject(trimmed)
                            true
                        } else if (trimmed.startsWith("[")) {
                            org.json.JSONArray(trimmed)
                            true
                        } else {
                            false
                        }
                    }
                } finally {
                    connection.disconnect()
                }
            }.getOrDefault(false)
            mainHandler.post { result.success(reachable) }
        }.apply {
            name = "UserNet-direct-probe"
            isDaemon = true
            start()
        }
    }

    private fun request(call: MethodCall, result: MethodChannel.Result) {
        val method = call.argument<String>("method") ?: "GET"
        val rawUrl = call.argument<String>("url").orEmpty()
        val headers = call.argument<Map<String, String>>("headers").orEmpty()
        val body = call.argument<String>("body")
        val port = call.argument<Int>("socksPort") ?: 17890
        Thread {
            runCatching {
                require(process?.isAlive == true) { "UserNet carrier is not running" }
                require(method == "GET" || method == "POST") { "Unsupported HTTP method" }
                require(port in 1..65535) { "Invalid SOCKS port" }
                val uri = URI(rawUrl)
                require(
                    uri.scheme == "https" &&
                        uri.host.equals("api.userlay.com", true) &&
                        (uri.port == -1 || uri.port == 443)
                ) {
                    "Only the UserNet API endpoint is allowed"
                }
                val proxy = Proxy(
                    Proxy.Type.SOCKS,
                    InetSocketAddress("127.0.0.1", port),
                )
                val connection = URL(rawUrl).openConnection(proxy) as HttpURLConnection
                try {
                    connection.requestMethod = method
                    connection.connectTimeout = 8_000
                    connection.readTimeout = 12_000
                    connection.instanceFollowRedirects = false
                    headers.forEach(connection::setRequestProperty)
                    if (body != null) {
                        connection.doOutput = true
                        connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                    }
                    val statusCode = connection.responseCode
                    val stream = if (statusCode in 200..399) connection.inputStream else connection.errorStream
                    val responseBody = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
                    mapOf("statusCode" to statusCode, "body" to responseBody)
                } finally {
                    connection.disconnect()
                }
            }.onSuccess { response ->
                mainHandler.post { result.success(response) }
            }.onFailure { error ->
                mainHandler.post { result.error("USERNET_REQUEST", error.message, null) }
            }
        }.apply {
            name = "UserNet-api-request"
            isDaemon = true
            start()
        }
    }

    @Synchronized
    private fun start(
        platform: String,
        joinLink: String,
        socksPort: Int,
        serviceUserId: String? = null,
        serviceCredential: String? = null,
        workPlatform: String = "telemost",
        egressId: String = "auto",
    ) {
        require(platform in setOf("wbstream", "telemost", "vk")) { "Unsupported carrier: $platform" }
        require(workPlatform in setOf("wbstream", "telemost", "vk")) { "Unsupported work carrier: $workPlatform" }
        require(joinLink.isNotBlank()) { "joinLink is required" }
        require(socksPort in 1..65535) { "Invalid SOCKS port" }
        val serviceMode = !serviceUserId.isNullOrBlank()
        if (serviceMode) {
            require(!serviceCredential.isNullOrBlank()) { "serviceCredential is required" }
        }
        stop()
        recoveryLaunch = Launch(platform, joinLink, socksPort, serviceUserId, serviceCredential, workPlatform, egressId)
        activeStage = if (serviceMode) "control" else "transport"
        controlState = if (serviceMode) "connecting" else "idle"
        transportState = if (serviceMode) "idle" else "connecting"
        controlCarrier = if (serviceMode) platform else ""
        transportCarrier = if (serviceMode) workPlatform else platform
        emit("status", "STARTING")
        launch(
            platform = platform,
            joinLink = joinLink,
            socksPort = socksPort,
            serviceUserId = serviceUserId,
            serviceCredential = serviceCredential,
            workPlatform = workPlatform,
            egressId = egressId,
        )
    }

    @Synchronized
    private fun launch(
        platform: String,
        joinLink: String,
        socksPort: Int,
        serviceUserId: String? = null,
        serviceCredential: String? = null,
        workPlatform: String = "telemost",
        egressId: String = "auto",
    ) {

        val appContext = checkNotNull(context) { "UserNet plugin is not attached" }
        val relay = File(appContext.applicationInfo.nativeLibraryDir, "libusernetrelay.so")
        check(relay.isFile) { "UserNet relay binary is missing" }
        val args = mutableListOf(
            relay.absolutePath,
            "--mode", "$platform-headless-joiner",
            "--socks-host", "127.0.0.1",
            "--socks-port", socksPort.toString(),
        )
        val serviceMode = !serviceUserId.isNullOrBlank()
        if (serviceMode) {
            args += listOf(
                "--service-control",
                "--service-user-id", serviceUserId,
                "--service-credential", serviceCredential.orEmpty(),
                "--service-work-platform", workPlatform,
                "--service-request-id", UUID.randomUUID().toString(),
                "--service-tunnel-mode", "video",
                "--egress-id", egressId,
            )
        }
        val builder = ProcessBuilder(args).redirectErrorStream(true)
        // Go runs as a Linux executable and needs Android's system CA directories.
        builder.environment()["SSL_CERT_DIR"] =
            "/apex/com.android.conscrypt/cacerts:/system/etc/security/cacerts"
        val proc = builder.start()
        process = proc
        writer = BufferedWriter(OutputStreamWriter(proc.outputStream))
        val currentGeneration = ++generation
        readerThread = Thread {
            runCatching {
                proc.inputStream.bufferedReader().use { input ->
                    while (true) {
                        val line = input.readLine() ?: break
                        if (currentGeneration != generation) return@Thread
                        when {
                            line == "STATUS:READY" -> sendJoin(platform, joinLink, currentGeneration)
                            line.startsWith("RESOLVE:") -> resolve(line.removePrefix("RESOLVE:"), currentGeneration)
                            line.startsWith("SERVICE_SESSION_READY:") -> {
                                val session = JSONObject(line.removePrefix("SERVICE_SESSION_READY:"))
                                val workLink = session.getString("joinLink")
                                emit("status", "WORK_SESSION_READY", currentGeneration)
                                if (currentGeneration == generation) {
                                    synchronized(this) {
                                        if (currentGeneration != generation) return@Thread
                                        stop(resetState = false)
                                        activeStage = "transport"
                                        transportState = "connecting"
                                        emit("status", "TRANSPORT_STARTING")
                                        launch(platform = workPlatform, joinLink = workLink, socksPort = socksPort)
                                    }
                                }
                                return@Thread
                            }
                            line == "STATUS:TUNNEL_CONNECTED" && serviceMode -> emit("status", "CONTROL_CONNECTED", currentGeneration)
                            line == "STATUS:TUNNEL_CONNECTED" -> verifyTransport(socksPort, currentGeneration)
                            line.startsWith("STATUS:") -> emit("status", line.removePrefix("STATUS:"), currentGeneration)
                            else -> {
                                Log.d("UserNetRelay", line)
                                emit("log", line, currentGeneration)
                            }
                        }
                    }
                }
            }.onFailure { error ->
                // Closing the process interrupts this blocking pipe read on
                // Android. That is a normal relay lifecycle transition.
                if (currentGeneration == generation && process === proc) {
                    Log.e("UserNet", "relay output failed", error)
                    emit("status", "ERROR:RELAY_OUTPUT", currentGeneration)
                }
            }
            if (currentGeneration == generation && !lastStatus.startsWith("ERROR:")) {
                emit("status", "STOPPED", currentGeneration)
            }
        }.also {
            it.name = "UserNet-relay-output"
            it.start()
        }
    }

    private fun emit(method: String, value: String, expectedGeneration: Long? = null) {
        val emissionGeneration = synchronized(this) {
            if (expectedGeneration != null && expectedGeneration != generation) return
            if (method == "status") updateStatus(value)
            generation
        }
        mainHandler.post {
            val activeChannels = synchronized(this) {
                if (emissionGeneration != generation) return@post
                channels.values.toList()
            }
            activeChannels.forEach { it.invokeMethod(method, value) }
        }
    }

    @Synchronized
    private fun updateStatus(value: String) {
        when {
            value == "CONTROL_CONNECTED" -> controlState = "connected"
            value == "WORK_SESSION_READY" -> {
                controlState = "complete"
                transportState = "connecting"
            }
            value == "TUNNEL_CONNECTED" -> transportState = "connected"
            value == "TRANSPORT_VERIFYING" -> transportState = "connecting"
            value == "TUNNEL_LOST" || value == "RECONNECTING" || value == "CONNECTING" -> {
                verificationTicket++
                if (activeStage == "control") controlState = "connecting" else transportState = "connecting"
            }
            value.startsWith("ERROR:") -> {
                if (activeStage == "control") controlState = "failed" else transportState = "failed"
            }
            value == "STOPPED" -> {
                if (activeStage == "control" && controlState != "complete") controlState = "idle"
                transportState = "idle"
            }
        }
        lastStatus = value
        Log.i("UserNet", "status: $value")
    }

    private fun verifyTransport(port: Int, expectedGeneration: Long) {
        val ticket = synchronized(this) {
            if (expectedGeneration != generation) return
            verificationTicket++
            emit("status", "TRANSPORT_VERIFYING", expectedGeneration)
            verificationTicket
        }
        Thread {
            repeat(3) {
                if (expectedGeneration != generation || process?.isAlive != true) return@Thread
                val connected = runCatching {
                    val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", port))
                    val connection = URL("https://api.userlay.com/app/v1/account")
                        .openConnection(proxy) as HttpURLConnection
                    try {
                        connection.connectTimeout = 3_000
                        connection.readTimeout = 5_000
                        connection.instanceFollowRedirects = false
                        connection.setRequestProperty("Accept", "application/json")
                        val code = connection.responseCode
                        val stream = if (code in 200..299) connection.inputStream else connection.errorStream
                        val body = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
                        if (code !in 200..299 && code != 401 && code != 403) {
                            Log.w("UserNet", "transport verification: HTTP $code")
                        }
                        (code in 200..299 || code == 401 || code == 403) &&
                            runCatching { JSONObject(body) }.isSuccess
                    } finally {
                        connection.disconnect()
                    }
                }.getOrDefault(false)
                synchronized(this) {
                    if (expectedGeneration != generation || ticket != verificationTicket || process?.isAlive != true) return@Thread
                    if (connected) {
                        emit("status", "TUNNEL_CONNECTED", expectedGeneration)
                        return@Thread
                    }
                }
                Thread.sleep(500)
            }
            synchronized(this) {
                if (expectedGeneration == generation && ticket == verificationTicket && process?.isAlive == true) {
                    emit("status", "ERROR:TRANSPORT_UNREACHABLE", expectedGeneration)
                }
            }
        }.apply {
            name = "UserNet-transport-verification"
            isDaemon = true
            start()
        }
    }

    private fun sendJoin(platform: String, link: String, expectedGeneration: Long) {
        val publicLink = link.substringBefore('#')
        val roomId = when {
            publicLink.startsWith("wbstream://") -> publicLink.removePrefix("wbstream://").trim('/')
            else -> publicLink.substringAfterLast('/').trim('/')
        }
        val payload = JSONObject().apply {
            if (platform == "wbstream") put("roomId", roomId) else put("joinLink", publicLink)
            link.substringAfter("#key=", "").takeIf { it.isNotBlank() }?.let {
                put("tunnelKey", it.substringBefore('&'))
            }
            put("displayName", "UserNet")
            put("tunnelMode", "video")
            put("vp8Fps", 24)
			put("vp8Batch", 30)
			put("dualTrack", false)
			put("reliable", platform == "telemost")
		}
        writeLine("${if (platform == "vk") "AUTH" else "JOIN"}:$payload", expectedGeneration)
    }

    private fun resolve(hostname: String, expectedGeneration: Long) {
        val addresses = runCatching { InetAddress.getAllByName(hostname) }.getOrNull().orEmpty()
        val selected = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull()
        writeLine(selected?.hostAddress.orEmpty(), expectedGeneration)
    }

    @Synchronized
    private fun writeLine(value: String, expectedGeneration: Long) {
        if (expectedGeneration != generation) return
        runCatching {
            writer?.write(value)
            writer?.newLine()
            writer?.flush()
        }.onFailure { Log.e("UserNet", "relay stdin failed", it) }
    }

    @Synchronized
    private fun stop(resetState: Boolean = true) {
        generation++
        pendingNetworkRestart?.let(mainHandler::removeCallbacks)
        pendingNetworkRestart = null
        if (resetState) {
            recoveryLaunch = null
            controlState = "idle"
            transportState = "idle"
            controlCarrier = ""
            transportCarrier = ""
            emit("status", "STOPPED")
        }
        runCatching {
            writer?.write("STOP")
            writer?.newLine()
            writer?.flush()
        }
        runCatching { writer?.close() }
        writer = null
        val active = process
        if (active != null && !active.waitFor(2000, TimeUnit.MILLISECONDS)) {
            active.destroy()
        }
        if (active != null && active.isAlive && !active.waitFor(500, TimeUnit.MILLISECONDS)) {
            active.destroyForcibly()
        }
        process = null
        readerThread?.interrupt()
        readerThread = null
    }
}
