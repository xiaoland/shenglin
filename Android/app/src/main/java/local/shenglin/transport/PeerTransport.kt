package local.shenglin.transport

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkAddress
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import local.shenglin.SecureStore
import local.shenglin.ble.BleProtocol
import local.shenglin.ble.BlePeers
import local.shenglin.core.Crypto
import local.shenglin.core.Pairing
import local.shenglin.core.PeerState
import local.shenglin.core.Wire
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import java.util.Collections
import java.util.Comparator
import java.util.HashMap
import java.util.HashSet
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Wi-Fi/Ethernet LAN pairing and authenticated peer state transport. Public methods are main-thread safe. */
class PeerTransport(context: Context, private val listener: Listener, private val secureStore: SecureStore) {
    interface Listener {
        fun onDemand(quiet: Boolean, manualTakeover: Boolean): String
        fun onStatus(message: String)
        fun onPeersChanged()
    }

    class Peer(
        @JvmField val id: String,
        @JvmField val name: String,
        @JvmField val platform: String,
        @JvmField val connected: Boolean,
        @JvmField val lanConnected: Boolean,
        @JvmField val bleConnected: Boolean,
        @JvmField val spaceEligible: Boolean,
    ) {
        constructor(id: String, name: String, platform: String, connected: Boolean) : this(id, name, platform, connected, connected, false, false)
        constructor(id: String, name: String, platform: String, connected: Boolean, lanConnected: Boolean, bleConnected: Boolean) :
            this(id, name, platform, connected, lanConnected, bleConnected, false)
    }

    class PairingSnapshot internal constructor(
        @JvmField val code: String?,
        @JvmField val status: String,
        @JvmField val expiresAtElapsedRealtime: Long,
    )

    companion object {
        private const val LOG_TAG = "ShenglinPeer"
        private const val PAIR_TYPE = "_shenglin-pair4._tcp."
        private const val STATE_TYPE = "_shenglin._tcp."
        private const val MAX_LINE = 1024
        private const val PAIR_WINDOW_MS = 120_000L
        private const val HANDSHAKE_MS = 90_000L
        private const val CONNECT_TIMEOUT_MS = 8_000L
        private const val PENDING_TTL_MS = 5 * 60_000L
        private const val LEASE_SECONDS = 20L
        private const val RENEW_SECONDS = 5L
    }

    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val io: ExecutorService = Executors.newCachedThreadPool()
    private val connectivity = this.context.getSystemService(ConnectivityManager::class.java)
    private val nsd = this.context.getSystemService(NsdManager::class.java)
    private val wifi = this.context.getSystemService(WifiManager::class.java)
    private val ledger = PeerState.Ledger()
    private val pairingEpoch = TransportLifecycle.Epoch()
    private val peers = HashMap<String, PeerRecord>()
    private val links = HashMap<String, StateLink>()
    private val pairCandidates = HashMap<String, NsdServiceInfo>()
    private val recentLocalPairServices = HashMap<String, LocalPairEndpoint>()
    private val resolveQueue = ArrayDeque<ResolveRequest>()
    private val verifiedLan = HashSet<String>()
    private val verifiedWifi = HashSet<String>()
    private val verifiedBle = HashSet<String>()
    private val spaceGates = HashMap<String, PeerState.SpaceGate>()
    private val lastSpaceEvaluation = HashMap<String, SpaceEvaluation>()
    private val lastInboundUpdate = HashMap<String, InboundUpdate>()
    private val blePeers: BlePeers

    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var lanNetwork: Network? = null
    @Volatile private var lanMedium: String? = null
    @Volatile private var lanAddress: InetAddress? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var pairDiscovery: NsdManager.DiscoveryListener? = null
    private var activeResolve: ResolveRequest? = null
    private var resolveTimeout: Runnable? = null
    private var pairRegistration: NsdManager.RegistrationListener? = null
    @Volatile private var pairServer: ServerSocket? = null
    @Volatile private var pairResponder: Pairing.Responder? = null
    private var pairInitiator: Pairing.Initiator? = null
    @Volatile private var pairSocket: Socket? = null
    @Volatile private var pairCode: String? = null
    @Volatile private var pairDeadline = 0L
    @Volatile private var pairAttempts = 0
    @Volatile private var pairSession = 0L
    @Volatile private var pairingStatus = "idle"
    @Volatile private var pairingPeerId: String? = null
    private var enabled = false
    @Volatile private var started = false
    private var localRecordingKnown = false
    private var localRecording = false
    private var requireBoth = false
    private var spaceMode = "nearbyOrWiFi"
    private var networkScope = "wifi"
    private var deviceName = "Android"
    private var localRevision = 0L
    private var lastDemand: String? = null
    private var lastManualTakeover: Boolean? = null
    private var stopGeneration = 0L
    private var stopDrainTimeout: Runnable? = null

    private data class SpaceEvaluation(val allowed: Boolean, val predicate: Boolean, val wallMillis: Long)
    private data class InboundUpdate(
        val path: String, val revision: Long, val known: Boolean, val quiet: Boolean,
        val accepted: Boolean, val spaceAllowed: Boolean, val reason: String,
        val wallMillis: Long, val elapsedMillis: Long,
    )

    init {
        blePeers = BlePeers(this.context, object : BlePeers.Listener {
            override fun localUpdate(peerId: String) = localUpdateFor(peerId)
            override fun receiveUpdate(peerId: String, update: PeerState.Update) = receiveBleUpdate(peerId, update)
            override fun receivedAck(peerId: String, ack: PeerState.Ack) = Unit
            override fun verifiedChanged(peerId: String, verified: Boolean) = bleVerificationChanged(peerId, verified)
            override fun issue(message: String) { postStatus(message) }
        })
        restore()
    }

    fun start() = runMain {
        if (started) return@runMain
        stopGeneration++
        stopDrainTimeout?.let(main::removeCallbacks)
        stopDrainTimeout = null
        started = true
        acquireMulticast()
        requestWifi()
        syncBlePeers()
        blePeers.start()
        if (lanNetwork != null && lanAddress != null) {
            startPairDiscovery()
            peers.values.forEach(::startLink)
        }
        lastDemand = null
        recomputeDemand()
        main.removeCallbacks(tick)
        main.post(tick)
    }

    fun stop() = runMain {
        if (!started) return@runMain
        started = false
        val token = ++stopGeneration
        main.removeCallbacks(tick)
        stopPairing("配对已取消")
        stopPairDiscovery()
        blePeers.stop()
        val closingLinks = links.values.toList()
        links.clear()
        verifiedLan.clear(); verifiedWifi.clear()
        recomputeDemand()
        if (closingLinks.isEmpty()) { finishStop(token); return@runMain }
        var remaining = closingLinks.size
        val timeout = Runnable {
            if (started || token != stopGeneration) return@Runnable
            closingLinks.forEach(StateLink::stop)
            finishStop(token)
        }
        stopDrainTimeout = timeout
        main.postDelayed(timeout, 1500)
        closingLinks.forEach { link ->
            link.closeAfterWrites {
                if (started || token != stopGeneration) return@closeAfterWrites
                remaining--
                if (remaining == 0) {
                    stopDrainTimeout?.let(main::removeCallbacks)
                    stopDrainTimeout = null
                    finishStop(token)
                }
            }
        }
    }

    private fun finishStop(token: Long) {
        if (started || token != stopGeneration) return
        unregisterWifi()
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        stopDrainTimeout?.let(main::removeCallbacks)
        stopDrainTimeout = null
        recomputeDemand()
    }

    fun setEnabled(value: Boolean) = runMain {
        if (enabled == value) return@runMain
        enabled = value
        if (!value) {
            TransportLifecycle.resetSpaceGates(spaceGates)
            links.values.filter { it.verified }.forEach { it.sendCurrentState(true) }
            val change = ledger.stopResponding(nowSeconds())
            if (change.ended || change.activeCount == 0) persist()
        } else links.values.filter { it.verified }.forEach(StateLink::sendCurrentState)
        blePeers.publish()
        recomputeDemand()
    }

    fun setSpaceMode(value: String) = runMain {
        val next = if (value == "nearbyAndWiFi") "nearbyAndWiFi" else "nearbyOrWiFi"
        if (spaceMode == next) return@runMain
        spaceMode = next
        requireBoth = next == "nearbyAndWiFi"
        recomputeSpacePolicy()
    }

    fun setNetworkScope(value: String) = runMain {
        val next = if (value == "lan") "lan" else "wifi"
        if (networkScope == next) return@runMain
        networkScope = next
        recomputeSpacePolicy()
    }

    fun setDeviceName(value: String) = runMain {
        val cleaned = cleanName(value, "Android", 128)
        if (deviceName == cleaned) return@runMain
        deviceName = cleaned
        saveQuietly()
        links.values.filter { it.verified }.forEach(StateLink::sendCurrentName)
        publishPeers()
    }

    fun setLocalRecording(value: Boolean?) = runMain {
        if (!TransportLifecycle.recordingChanged(localRecordingKnown, localRecording, value)) return@runMain
        localRecordingKnown = value != null
        localRecording = value == true
        links.values.filter { it.verified }.forEach(StateLink::sendCurrentState)
        blePeers.publish()
    }

    fun takeOver() = runMain { ledger.takeOver(nowSeconds()); persist(); dispatchDemand(true) }
    fun refreshBluetooth() = runMain { syncBlePeers(); if (started) blePeers.start() }

    @Throws(Exception::class)
    fun beginPairing(): String {
        check(Looper.myLooper() == Looper.getMainLooper()) { "必须在主线程调用" }
        check(lanNetwork != null && started) { "请先连接 Wi-Fi 或以太网并启动协同" }
        if (pairServer != null || pairSocket != null || pairInitiator != null) stopPairing("重新开始配对")
        val server = ServerSocket().apply {
            reuseAddress = true
            bind(java.net.InetSocketAddress(lanAddress, 0))
        }
        pairCode = Pairing.generateCode()
        pairingStatus = "waiting"
        pairingPeerId = null
        pairSession = pairingEpoch.advance()
        val serverSession = pairSession
        pairDeadline = SystemClock.elapsedRealtime() + PAIR_WINDOW_MS
        pairAttempts = 0
        pairServer = server
        val requestedServiceName = cleanName(deviceName, "Android", 63)
        val ownAddresses = localAddressesForNetwork()
        rememberLocalPairService(requestedServiceName, ownAddresses, server.localPort, pairDeadline)
        pairRegistration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                rememberLocalPairService(serviceInfo.serviceName, ownAddresses, server.localPort, pairDeadline)
                if (pairServer === server && pairingEpoch.isCurrent(serverSession)) postStatus("正在等待另一台设备输入验证码")
            }
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                if (pairServer === server && pairingEpoch.isCurrent(serverSession)) {
                    pairingStatus = "failed"; postStatus("配对服务注册失败：$errorCode"); stopPairing(null)
                }
            }
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
        }
        val service = NsdServiceInfo().apply {
            serviceName = requestedServiceName
            serviceType = PAIR_TYPE
            port = server.localPort
            setAttribute("platform", "android")
        }
        nsd.registerService(service, NsdManager.PROTOCOL_DNS_SD, pairRegistration)
        io.execute { acceptPair(server, serverSession) }
        main.postDelayed(pairTimeout, PAIR_WINDOW_MS)
        return checkNotNull(pairCode)
    }

    fun pairingActive(): Boolean = pairServer != null && pairCode != null && SystemClock.elapsedRealtime() < pairDeadline

    fun pairingSnapshot(): PairingSnapshot {
        val state = pairingStatus
        val deadline = pairDeadline
        val now = SystemClock.elapsedRealtime()
        val code = pairCode.takeIf { pairServer != null && TransportLifecycle.pairingCodeVisible(state, deadline, now) }
        return PairingSnapshot(code, TransportLifecycle.pairingStatusAt(state, deadline, now), deadline)
    }

    fun cancelPairing() = runMain { pairingStatus = "cancelled"; stopPairing("配对已取消") }

    fun pair(discoveredId: String, code: String?) = runMain {
        val service = pairCandidates[discoveredId]
        if (service == null || lanNetwork == null) { postStatus("配对设备已不可用，请重新查找"); return@runMain }
        if (code == null || !Regex("[0-9]{6}").matches(code)) { postStatus("请输入 6 位配对码"); return@runMain }
        if (pairServer != null || pairSocket != null || pairInitiator != null) stopPairing("切换到所选设备")
        try {
            pairInitiator = Pairing.Initiator(code, deviceName, nowSeconds())
            pairingStatus = "verifying"
            pairingPeerId = null
            pairSession = pairingEpoch.advance()
            val clientSession = pairSession
            pairDeadline = SystemClock.elapsedRealtime() + HANDSHAKE_MS
            val handshake = checkNotNull(pairInitiator)
            val network = checkNotNull(lanNetwork)
            postStatus("正在验证配对码")
            val query = NsdServiceInfo().apply { serviceName = discoveredId; serviceType = PAIR_TYPE }
            enqueueResolve(ResolveRequest.forPair(query, network, handshake, clientSession), true)
            main.postDelayed(pairTimeout, HANDSHAKE_MS)
        } catch (error: Exception) {
            pairingStatus = "failed"; cancelPairClient(); postStatus("无法连接配对设备：${safeMessage(error)}")
        }
    }

    private fun connectPairCandidate(service: NsdServiceInfo, network: Network, handshake: Pairing.Initiator, clientSession: Long) {
        io.execute {
            var socket: Socket? = null
            try {
                socket = network.socketFactory.createSocket()
                network.bindSocket(socket)
                socket.connect(java.net.InetSocketAddress(service.host, service.port), CONNECT_TIMEOUT_MS.toInt())
                socket.soTimeout = HANDSHAKE_MS.toInt()
                val connected = socket
                main.post {
                    if (pairInitiator === handshake && pairingEpoch.isCurrent(clientSession) && started) {
                        pairSocket = connected
                        io.execute { pairClient(connected, handshake, clientSession) }
                    } else close(connected)
                }
            } catch (error: Exception) {
                close(socket)
                main.post { failPairClient(handshake, clientSession, "无法连接配对设备：${safeMessage(error)}") }
            }
        }
    }

    private fun failPairClient(handshake: Pairing.Initiator, clientSession: Long, message: String) {
        if (pairInitiator !== handshake || !pairingEpoch.isCurrent(clientSession)) return
        pairingStatus = "failed"
        cancelPairClient()
        postStatus(message)
    }

    fun forget(id: String) = runMain {
        val record = peers.remove(id)
        val link = links.remove(id)
        link?.stop()
        verifiedLan.remove(id); verifiedWifi.remove(id); verifiedBle.remove(id); spaceGates.remove(id)
        lastSpaceEvaluation.remove(id); lastInboundUpdate.remove(id)
        val activePairing = pairServer != null || pairSocket != null || pairInitiator != null
        if (TransportLifecycle.clearPairingSnapshotOnForget(pairingStatus, pairingPeerId, id, activePairing)) {
            pairingStatus = "idle"; pairingPeerId = null
        }
        if (record != null) {
            ledger.stopResponding(id, nowSeconds())
            persist(); syncBlePeers(); publishPeers(); recomputeDemand()
            postStatus("已取消与“${record.name}”的配对")
        }
    }

    fun peers(): List<Peer> {
        check(Looper.myLooper() == Looper.getMainLooper()) { "必须在主线程读取" }
        return peers.values.map { record ->
            val lan = record.id in verifiedLan
            val ble = record.id in verifiedBle
            Peer(record.id, record.name, record.platform, lan || ble, lan, ble, spaceEvidence(record.id))
        }.sortedBy { it.name.lowercase(Locale.ROOT) }
    }

    /** Read-only snapshot for service diagnostics; does not advance a SpaceGate or expose credentials. */
    fun diagnostics(): String {
        check(Looper.myLooper() == Looper.getMainLooper()) { "必须在主线程读取" }
        val now = nowSeconds()
        val records = ledger.records()
        val rows = JSONArray()
        peers.values.sortedBy { it.name.lowercase(Locale.ROOT) }.forEachIndexed { index, peer ->
            val record = records[peer.id]
            val evaluation = lastSpaceEvaluation[peer.id]
            val inbound = lastInboundUpdate[peer.id]
            rows.put(JSONObject()
                .put("peerIndex", index)
                .put("platform", peer.platform)
                .put("localPairRole", peer.localRole)
                .put("expectedRemoteRole", remoteRole(peer.localRole))
                .put("bleCentral", BleProtocol.central(peer.platform, peer.localRole))
                .put("lanAuthenticated", peer.id in verifiedLan)
                .put("wifiAuthenticated", peer.id in verifiedWifi)
                .put("bleAuthenticated", peer.id in verifiedBle)
                .put("spacePredicate", spacePredicate(peer.id))
                .put("lastGateAllowed", evaluation?.allowed)
                .put("lastGatePredicate", evaluation?.predicate)
                .put("lastGateWallMillis", evaluation?.wallMillis)
                .put("leaseRevision", record?.revision)
                .put("leaseValidUntil", record?.validUntil)
                .put("leaseRemainingSeconds", record?.validUntil?.let { (it - now).coerceAtLeast(0) })
                .put("lastInbound", inbound?.let { event -> JSONObject()
                    .put("path", event.path)
                    .put("revision", event.revision)
                    .put("known", event.known)
                    .put("quiet", event.quiet)
                    .put("accepted", event.accepted)
                    .put("spaceAllowed", event.spaceAllowed)
                    .put("reason", event.reason)
                    .put("wallMillis", event.wallMillis)
                    .put("elapsedMillis", event.elapsedMillis)
                })
            )
        }
        return JSONObject()
            .put("started", started)
            .put("enabled", enabled)
            .put("networkScope", networkScope)
            .put("spaceMode", spaceMode)
            .put("lanNetworkAvailable", lanNetwork != null)
            .put("lanMedium", lanMedium)
            .put("activeLeaseCount", ledger.activeCount(now))
            .put("manualTakeover", ledger.manualTakeover())
            .put("peers", rows)
            .toString()
    }

    fun discovered(): List<Peer> {
        check(Looper.myLooper() == Looper.getMainLooper()) { "必须在主线程读取" }
        return pairCandidates.map { (id, service) ->
            Peer(id, service.serviceName ?: "附近设备", discoveredPlatform(service), false, false, false, false)
        }.sortedBy { it.name.lowercase(Locale.ROOT) }
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!started) return
            val now = nowSeconds()
            val expired = ledger.expire(now)
            if (expired.ended) { persist(); recomputeDemand() }
            if (enabled) links.values.toList().filter { it.verified }.forEach { link ->
                val elapsed = SystemClock.elapsedRealtime()
                if (elapsed - link.lastAckElapsed >= LEASE_SECONDS * 1000) link.stop()
                else if (elapsed - link.lastSentElapsed >= RENEW_SECONDS * 1000) link.sendCurrentState()
            }
            var removedPending = false
            peers.values.toList().filter { it.pending && TransportLifecycle.pendingExpired(it.pendingExpiresAtMillis, System.currentTimeMillis()) }.forEach { peer ->
                links.remove(peer.id)?.stop()
                peers.remove(peer.id); removedPending = true
            }
            if (removedPending) { persist(); syncBlePeers(); publishPeers() }
            if ((pairServer != null || pairInitiator != null) && SystemClock.elapsedRealtime() >= pairDeadline) {
                pairingStatus = "expired"; stopPairing("配对已超时")
            }
            main.postDelayed(this, 1000)
        }
    }

    private val pairTimeout = Runnable {
        if (pairServer != null || pairSocket != null || pairInitiator != null) { pairingStatus = "expired"; stopPairing("配对已超时") }
    }

    private fun requestWifi() {
        if (networkCallback != null) return
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { main.post { lanAvailable(network, medium(connectivity.getNetworkCapabilities(network))) } }
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) { main.post { lanAvailable(network, medium(capabilities)) } }
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) { main.post {
                if (network == lanNetwork) updateLanAddress(properties)
            } }
            override fun onLost(network: Network) { main.post { if (network == lanNetwork) lanLost() } }
        }
        connectivity.requestNetwork(request, networkCallback!!)
    }

    private fun unregisterWifi() {
        networkCallback?.let { try { connectivity.unregisterNetworkCallback(it) } catch (_: RuntimeException) { } }
        networkCallback = null
        lanNetwork = null; lanAddress = null; lanMedium = null
    }

    private fun lanAvailable(network: Network, medium: String?) {
        if (!started) return
        val old = lanNetwork
        val pathChanged = old != null && (old != network || lanMedium != medium)
        if (pathChanged) resetLanPath("局域网路径已变化")
        lanNetwork = network
        lanMedium = medium
        updateLanAddress(connectivity.getLinkProperties(network))
        if (lanAddress == null) { postStatus("正在等待局域网地址"); return }
        startPairDiscovery()
        peers.values.forEach(::startLink)
        postStatus("已连接局域网，正在查找已配对设备")
    }

    private fun updateLanAddress(properties: LinkProperties?) {
        if (properties == null) return
        val previous = lanAddress
        val chosen = properties.linkAddresses.asSequence().map(LinkAddress::getAddress)
            .firstOrNull { it is Inet4Address && !it.isLoopbackAddress && !it.isLinkLocalAddress }
        lanAddress = chosen
        if (previous != chosen && started) {
            resetLanPath("局域网地址已变化")
            if (chosen != null) { startPairDiscovery(); peers.values.forEach(::startLink) }
        }
    }

    private fun lanLost() {
        lanNetwork = null; lanAddress = null; lanMedium = null
        stopPairDiscovery(); stopPairing("局域网已断开，配对已取消")
        links.values.toList().forEach(StateLink::stop)
        verifiedLan.clear(); verifiedWifi.clear(); refreshSpaceAfterProofChange()
        blePeers.publish(); publishPeers(); postStatus("局域网已断开")
    }

    private fun resetLanPath(reason: String) {
        stopPairDiscovery()
        if (pairServer != null || pairSocket != null || pairInitiator != null) stopPairing("$reason，配对已取消")
        val old = links.values.toList()
        links.clear(); verifiedLan.clear(); verifiedWifi.clear()
        old.forEach(StateLink::stop)
        refreshSpaceAfterProofChange()
        blePeers.publish(); publishPeers()
    }

    private fun refreshSpaceAfterProofChange() {
        TransportLifecycle.resetSpaceGates(spaceGates)
        var shouldPersist = false
        peers.values.forEach { peer ->
            if (spacePredicate(peer.id)) spaceEvidence(peer.id)
            else { ledger.stopResponding(peer.id, nowSeconds()); shouldPersist = true }
        }
        if (shouldPersist) persist()
        links.values.filter { it.verified }.forEach(StateLink::sendCurrentState)
        blePeers.publish(); publishPeers(); recomputeDemand()
    }

    private fun recomputeSpacePolicy() = refreshSpaceAfterProofChange()

    private fun medium(capabilities: NetworkCapabilities?): String? = when {
        capabilities == null -> null
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
        else -> null
    }

    private fun acquireMulticast() {
        if (wifi == null || multicastLock != null) return
        multicastLock = wifi.createMulticastLock("shenglin-nsd").apply { setReferenceCounted(false); acquire() }
    }

    private fun startPairDiscovery() {
        if (pairDiscovery != null || lanNetwork == null) return
        pairCandidates.clear()
        val discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (serviceInfo.serviceType != PAIR_TYPE) return
                val query = NsdServiceInfo().apply { serviceName = serviceInfo.serviceName; serviceType = PAIR_TYPE }
                val ownServer = pairServer
                var ownAddresses: Set<InetAddress> = if (ownServer == null || ownServer.isClosed) emptySet() else localAddressesForNetwork()
                var ownPort = if (ownAddresses.isEmpty()) 0 else ownServer?.localPort ?: 0
                if (ownAddresses.isEmpty()) recentLocalPairEndpoint(serviceInfo.serviceName)?.let { ownAddresses = it.addresses; ownPort = it.port }
                enqueueResolve(ResolveRequest.forDiscovery(query, this, ownAddresses, ownPort), false)
            }
            override fun onServiceLost(serviceInfo: NsdServiceInfo) { main.post {
                if (pairCandidates.remove(serviceInfo.serviceName) != null) publishPeers()
            } }
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { postStatus("配对设备发现失败：$errorCode"); stopPairDiscovery() }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        pairDiscovery = discovery
        nsd.discoverServices(PAIR_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
    }

    private fun enqueueResolve(request: ResolveRequest, priority: Boolean) {
        if (priority) resolveQueue.addFirst(request) else resolveQueue.addLast(request)
        startNextResolve()
    }

    private fun startNextResolve() {
        if (activeResolve != null || !started) return
        while (resolveQueue.isNotEmpty()) {
            val request = resolveQueue.removeFirst()
            if (request.discovery != null && request.discovery !== pairDiscovery) continue
            if (request.initiator != null && (request.initiator !== pairInitiator || !pairingEpoch.isCurrent(request.session))) continue
            activeResolve = request
            val timeout = Runnable { finishResolve(request, null, -1) }
            resolveTimeout = timeout
            main.postDelayed(timeout, CONNECT_TIMEOUT_MS)
            try {
                nsd.resolveService(request.query, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) { main.post { finishResolve(request, null, errorCode) } }
                    override fun onServiceResolved(info: NsdServiceInfo) { main.post { finishResolve(request, info, 0) } }
                })
            } catch (_: RuntimeException) { finishResolve(request, null, -2) }
            return
        }
    }

    private fun finishResolve(request: ResolveRequest, resolved: NsdServiceInfo?, errorCode: Int) {
        if (activeResolve !== request) return
        activeResolve = null
        resolveTimeout?.let(main::removeCallbacks); resolveTimeout = null
        if (request.initiator != null && request.initiator === pairInitiator && pairingEpoch.isCurrent(request.session)) {
            if (errorCode != 0 || resolved == null) failPairClient(request.initiator, request.session, "无法刷新配对设备地址：$errorCode")
            else if (resolved.host == null || resolved.port <= 0 || request.network != lanNetwork) failPairClient(request.initiator, request.session, "配对设备地址已变化，请重新查找")
            else connectPairCandidate(resolved, request.network!!, request.initiator, request.session)
        } else if (request.discovery != null && request.discovery === pairDiscovery && started && errorCode == 0 && resolved?.host != null && resolved.port > 0) {
            if (!TransportLifecycle.sameServiceEndpointOnAddresses(request.localPairAddresses, request.localPairPort, resolved.host, resolved.port)) {
                pairCandidates[resolved.serviceName] = resolved
                publishPeers()
            }
        }
        startNextResolve()
    }

    private fun stopPairDiscovery() {
        val old = pairDiscovery
        if (old != null) try { nsd.stopServiceDiscovery(old) } catch (_: RuntimeException) { }
        pairDiscovery = null
        pairCandidates.clear()
        resolveQueue.removeIf { it.discovery === old }
    }

    private fun acceptPair(server: ServerSocket, serverSession: Long) {
        while (started && !server.isClosed && pairingEpoch.isCurrent(serverSession)) {
            var socket: Socket? = null
            try {
                socket = server.accept()
                val accepted = socket
                main.post {
                    if (pairServer !== server || !pairingEpoch.isCurrent(serverSession) || pairSocket != null || pairAttempts >= 3 || SystemClock.elapsedRealtime() >= pairDeadline) close(accepted)
                    else { pairAttempts++; pairSocket = accepted; io.execute { pairServerSocket(accepted, server, serverSession) } }
                }
            } catch (_: Exception) { close(socket); break }
        }
    }

    private fun pairServerSocket(socket: Socket, server: ServerSocket, serverSession: Long) {
        var responder: Pairing.Responder? = null
        try {
            socket.soTimeout = HANDSHAKE_MS.toInt()
            val start = Wire.pairing(readFrame(socket.getInputStream()))
            if (start.version != 4 || start.kind != "start" || !validPlatform(start.platform.orEmpty())) throw IOException("只支持 v4 配对")
            val code = pairCode ?: throw IOException("配对窗口已结束")
            synchronized(this) {
                if (pairServer !== server || !pairingEpoch.isCurrent(serverSession) || pairResponder != null || pairAttempts > 3 || SystemClock.elapsedRealtime() >= pairDeadline)
                    throw IOException("配对窗口不可用")
                responder = Pairing.Responder(start, code, deviceName, nowSeconds())
                pairResponder = responder
            }
            val activeResponder = checkNotNull(responder)
            writeFrame(socket.getOutputStream(), Wire.json(activeResponder.offerFrame()))
            val confirm = Wire.pairing(readFrame(socket.getInputStream()))
            val finish = activeResponder.receiveConfirm(confirm, nowSeconds())
            val key = activeResponder.confirmedKey() ?: throw IOException("配对密钥生成失败")
            val peerName = activeResponder.peerName ?: throw IOException("配对名称缺失")
            val peerPlatform = activeResponder.peerPlatform ?: throw IOException("配对平台缺失")
            val pending = PeerRecord(key, peerName, peerPlatform, "responder", false)
            writeFrame(socket.getOutputStream(), Wire.json(finish))
            main.post {
                if (pairServer === server && pairSocket === socket && pairResponder === activeResponder && pairingEpoch.isCurrent(serverSession) && started)
                    installPending(pending)
            }
            activeResponder.close()
            close(socket)
        } catch (error: Exception) {
            main.post { if (pairServer === server && pairSocket === socket && pairingEpoch.isCurrent(serverSession)) postStatus("配对验证失败：${safeMessage(error)}") }
            close(socket)
        } finally {
            val finishedResponder = responder
            main.post {
                if (pairServer === server && pairSocket === socket && pairingEpoch.isCurrent(serverSession)) pairSocket = null
                if (pairServer === server && pairResponder === finishedResponder && pairingEpoch.isCurrent(serverSession)) {
                    pairResponder?.close(); pairResponder = null
                }
            }
        }
    }

    private fun pairClient(socket: Socket, session: Pairing.Initiator, clientSession: Long) {
        try {
            writeFrame(socket.getOutputStream(), Wire.json(session.startFrame()))
            val offer = Wire.pairing(readFrame(socket.getInputStream()))
            val confirm = session.receiveOffer(offer, nowSeconds())
            writeFrame(socket.getOutputStream(), Wire.json(confirm))
            val finish = Wire.pairing(readFrame(socket.getInputStream()))
            val key = session.receiveFinish(finish, nowSeconds())
            val peerName = session.peerName ?: throw IOException("配对名称缺失")
            val peerPlatform = session.peerPlatform ?: throw IOException("配对平台缺失")
            val pending = PeerRecord(key, peerName, peerPlatform, "initiator", false)
            session.close()
            main.post {
                if (pairInitiator === session && pairSocket === socket && pairingEpoch.isCurrent(clientSession)) {
                    if (started) installPending(pending)
                    cancelPairClient()
                }
            }
        } catch (error: Exception) {
            main.post {
                if (pairInitiator === session && pairSocket === socket && pairingEpoch.isCurrent(clientSession)) {
                    pairingStatus = "failed"; cancelPairClient(); postStatus("配对验证失败：${safeMessage(error)}")
                }
            }
        }
    }

    private fun installPending(peer: PeerRecord) {
        pairingPeerId = peer.id
        if (peers.containsKey(peer.id)) {
            pairingStatus = "activated"; stopPairing("该设备已经配对"); return
        }
        peer.pending = true
        peer.pendingExpiresAtMillis = System.currentTimeMillis() + PENDING_TTL_MS
        peers[peer.id] = peer
        if (!persist()) {
            pairingStatus = "failed"; peers.remove(peer.id); stopPairing("无法保存待确认设备，配对未完成"); publishPeers(); return
        }
        pairingStatus = "verified"
        stopPairing("配对码已验证，正在建立安全链路")
        startLink(peer)
        publishPeers()
    }

    private fun stopPairing(message: String?) {
        if (pairingStatus == "waiting" || pairingStatus == "verifying") pairingStatus = "cancelled"
        val cancelledInitiator = pairInitiator
        pairSession = pairingEpoch.advance()
        if (cancelledInitiator != null) resolveQueue.removeIf { it.initiator === cancelledInitiator }
        main.removeCallbacks(pairTimeout)
        val stoppingServer = pairServer
        if (stoppingServer != null && !stoppingServer.isClosed) {
            val address = stoppingServer.inetAddress
            val port = stoppingServer.localPort
            val rejectUntil = SystemClock.elapsedRealtime() + 10_000
            recentLocalPairServices.replaceAll { _, endpoint ->
                if (address in endpoint.addresses && endpoint.port == port) LocalPairEndpoint(endpoint.addresses, port, rejectUntil) else endpoint
            }
            val localEndpoints = localAddressesForNetwork().toMutableSet()
            localEndpoints.add(address)
            recentLocalPairServices.values.filter { it.port == port && address in it.addresses }.forEach { localEndpoints.addAll(it.addresses) }
            val removedSelf = pairCandidates.entries.removeIf { (_, endpoint) ->
                TransportLifecycle.sameServiceEndpointOnAddresses(localEndpoints, port, endpoint.host, endpoint.port)
            }
            if (removedSelf) publishPeers()
        }
        pairRegistration?.let { try { nsd.unregisterService(it) } catch (_: RuntimeException) { } }
        pairRegistration = null
        close(pairServer); pairServer = null
        close(pairSocket); pairSocket = null
        pairResponder?.close(); pairResponder = null
        pairInitiator?.close(); pairInitiator = null
        pairCode = null
        if (message != null) postStatus(message)
    }

    private fun discoveredPlatform(service: NsdServiceInfo): String {
        val value = service.attributes["platform"] ?: return ""
        val platform = String(value, StandardCharsets.UTF_8)
        return if (validPlatform(platform)) platform else ""
    }

    private fun rememberLocalPairService(name: String?, address: InetAddress?, port: Int, expiresAt: Long) {
        if (address != null) rememberLocalPairService(name, setOf(address), port, expiresAt)
    }

    private fun rememberLocalPairService(name: String?, addresses: Set<InetAddress>, port: Int, expiresAt: Long) {
        if (name.isNullOrEmpty() || addresses.isEmpty() || port <= 0) return
        recentLocalPairServices[name.lowercase(Locale.ROOT)] = LocalPairEndpoint(addresses, port, expiresAt)
    }

    private fun recentLocalPairEndpoint(name: String?): LocalPairEndpoint? {
        val now = SystemClock.elapsedRealtime()
        recentLocalPairServices.values.removeIf { it.expiresAt <= now }
        val endpoint = name?.let { recentLocalPairServices[it.lowercase(Locale.ROOT)] }
        return endpoint?.takeIf { it.expiresAt > now }
    }

    private fun localAddressesForNetwork(): Set<InetAddress> {
        val addresses = HashSet<InetAddress>()
        lanAddress?.let(addresses::add)
        val properties = lanNetwork?.let(connectivity::getLinkProperties)
        properties?.linkAddresses?.map(LinkAddress::getAddress)?.filterNot(InetAddress::isLoopbackAddress)?.forEach(addresses::add)
        return addresses
    }

    private fun cancelPairClient() {
        pairingEpoch.advance()
        close(pairSocket); pairSocket = null
        pairInitiator?.close(); pairInitiator = null
        main.removeCallbacks(pairTimeout)
    }

    private fun startLink(peer: PeerRecord) {
        if (!started || lanNetwork == null || lanAddress == null || links.containsKey(peer.id)) return
        StateLink(peer).also { links[peer.id] = it; it.start() }
    }

    private fun linkVerified(link: StateLink, verified: Boolean, generation: Long) {
        if (links[link.peer.id] !== link) return
        if (!link.generation.isCurrent(generation)) { if (!verified) linkDisconnected(link); return }
        if (verified) {
            verifiedLan.add(link.peer.id)
            if (TransportLifecycle.wifiEvidence(true, link.localMedium, link.remoteMedium, link.remoteWifiProven)) verifiedWifi.add(link.peer.id)
            else verifiedWifi.remove(link.peer.id)
            link.lastAckElapsed = SystemClock.elapsedRealtime()
            if (link.peer.pending) {
                val pendingDeadline = link.peer.pendingExpiresAtMillis
                link.peer.pending = false; link.peer.pendingExpiresAtMillis = 0
                if (!persist()) {
                    link.peer.pending = true; link.peer.pendingExpiresAtMillis = pendingDeadline
                    links.remove(link.peer.id); verifiedLan.remove(link.peer.id); verifiedWifi.remove(link.peer.id)
                    link.stop(); postStatus("安全链路已验证，但无法保存配对；正在重试"); retryPending(link.peer); return
                }
                postStatus("已完成双向安全认证")
                if (pairingStatus == "verified") pairingStatus = "activated"
                syncBlePeers()
            }
            link.sendCurrentName(); link.sendCurrentState(); blePeers.publish()
        } else linkDisconnected(link)
        publishPeers(); recomputeDemand()
    }

    private fun linkDisconnected(link: StateLink) {
        if (links[link.peer.id] !== link) return
        if (link.stopped) { removeLink(link); return }
        if (link.verified) return
        verifiedLan.remove(link.peer.id); verifiedWifi.remove(link.peer.id)
        blePeers.publish(); publishPeers(); recomputeDemand()
    }

    private fun removeLink(link: StateLink) {
        if (links[link.peer.id] === link) links.remove(link.peer.id)
        verifiedLan.remove(link.peer.id); verifiedWifi.remove(link.peer.id)
        blePeers.publish(); publishPeers(); recomputeDemand()
        if (link.peer.pending) retryPending(link.peer)
        if (started) main.postDelayed({ startLink(link.peer) }, 2000)
    }

    private fun retryPending(peer: PeerRecord) {
        if (!started || !peer.pending || peer.pendingExpiresAtMillis <= System.currentTimeMillis()) return
        main.postDelayed({ if (peers[peer.id] === peer && peer.pending && !links.containsKey(peer.id)) startLink(peer) }, 2000)
    }

    private fun receiveUpdate(link: StateLink, update: PeerState.Update, socket: Socket, generation: Long) {
        val ack = acceptRemoteUpdate(link.peer, update, "lan")
        try { link.send(socket, generation, "ack", JSONObject().put("kind", "ack").put("ack", Wire.json(ack))) }
        catch (error: Exception) { logFailure("ack-build", error); link.stop() }
    }

    private fun receiveBleUpdate(peerId: String, update: PeerState.Update): PeerState.Ack {
        val peer = peers[peerId]
        require(peer != null && !peer.pending) { "未知 BLE 配对设备" }
        return acceptRemoteUpdate(peer, update, "ble")
    }

    private fun acceptRemoteUpdate(peer: PeerRecord, update: PeerState.Update, path: String): PeerState.Ack {
        val now = nowSeconds()
        val allowed = spaceEvidence(peer.id)
        val accepted = if (allowed) update else PeerState.Update.signed(update.origin, update.revision, false, true, update.validUntil, null, peer.key)
        val change = ledger.accept(accepted, peer.id, remoteRole(peer.localRole), peer.key, now)
        val reason = when {
            !allowed -> "outsideSpace"
            !change.accepted -> "ledgerRejected"
            !update.known -> "remoteStateUnknown"
            else -> "accepted"
        }
        lastInboundUpdate[peer.id] = InboundUpdate(
            path, update.revision, update.known, update.quiet, change.accepted, allowed, reason,
            System.currentTimeMillis(), SystemClock.elapsedRealtime(),
        )
        if (change.accepted) persist()
        var result = if (!allowed) "outsideSpace" else if (update.known) { if (update.quiet) "applied" else "restored" } else "unknown"
        val volumeResult = dispatchDemand(true)
        if (allowed && !volumeResult.isNullOrEmpty()) result = volumeResult
        return PeerState.Ack.signed(localRole(peer.localRole), update.revision, update.quiet, result, null, peer.key)
    }

    private fun spaceEvidence(peerId: String): Boolean {
        val predicate = spacePredicate(peerId)
        val allowed = TransportLifecycle.spaceAllowed(
            spaceGates, peerId, requireBoth, peerId in verifiedBle, selectedNetworkProof(peerId), nowSeconds(),
        )
        lastSpaceEvaluation[peerId] = SpaceEvaluation(allowed, predicate, System.currentTimeMillis())
        return allowed
    }

    private fun spacePredicate(peerId: String): Boolean = TransportLifecycle.spacePredicate(
        requireBoth, peerId in verifiedBle, selectedNetworkProof(peerId),
    )

    private fun selectedNetworkProof(peerId: String): Boolean = TransportLifecycle.selectedNetworkProof(
        networkScope == "lan", peerId in verifiedLan, peerId in verifiedWifi,
    )

    private fun localUpdateFor(peerId: String): PeerState.Update {
        val peer = peers[peerId]
        require(started && peer != null && !peer.pending) { "BLE 配对设备不可用" }
        localRevision = incrementRevision(localRevision)
        val update = TransportLifecycle.localUpdate(
            peer.localRole, localRevision, enabled, localRecordingKnown, localRecording,
            spaceEvidence(peerId), !enabled, nowSeconds(), peer.key,
        )
        check(persist()) { "无法保存状态版本" }
        return update
    }

    private fun bleVerificationChanged(peerId: String, verified: Boolean) {
        if (!peers.containsKey(peerId)) return
        val changed = if (verified) verifiedBle.add(peerId) else verifiedBle.remove(peerId)
        if (!changed) return
        links.values.filter { it.peer.id == peerId && it.verified }.forEach(StateLink::sendCurrentState)
        blePeers.publish(); publishPeers(); recomputeDemand()
    }

    private fun syncBlePeers() {
        val active = peers.values.filterNot(PeerRecord::pending).map { BlePeers.Peer(it.id, it.key, it.platform, it.localRole) }
        blePeers.setPeers(active)
    }

    private fun receiveAck(link: StateLink, ack: PeerState.Ack) { link.lastAckElapsed = SystemClock.elapsedRealtime() }

    private fun receiveName(link: StateLink, name: PeerState.NameClaim) {
        if (!name.valid(link.peer.key)) { link.stop(); return }
        if (link.peer.name != name.name) { link.peer.name = name.name; persist(); publishPeers() }
    }

    private fun recomputeDemand() { dispatchDemand(false) }

    private fun dispatchDemand(force: Boolean): String? {
        val quiet = enabled && ledger.activeCount(nowSeconds()) > 0
        val state = if (quiet) "quiet" else "clear"
        val manual = ledger.manualTakeover()
        if (force || state != lastDemand || lastManualTakeover == null || manual != lastManualTakeover) {
            lastDemand = state; lastManualTakeover = manual
            return listener.onDemand(quiet, manual)
        }
        return null
    }

    private fun publishPeers() = listener.onPeersChanged()
    private fun postStatus(status: String) = main.post { listener.onStatus(status) }
    private fun runMain(action: () -> Unit) { if (Looper.myLooper() == Looper.getMainLooper()) action() else main.post(action) }
    private fun logFailure(stage: String, error: Exception) { Log.w(LOG_TAG, "$stage failed (${error.javaClass.simpleName})") }

    private fun restore() {
        val encoded = secureStore.read() ?: return
        val root = JSONObject(String(encoded, StandardCharsets.UTF_8))
        deviceName = root.optString("name", deviceName)
        localRevision = parseUnsigned(root.optString("localRevision", "0"))
        var expiredPending = false
        val array = root.optJSONArray("peers")
        if (array != null) for (index in 0 until array.length()) {
            val item = array.getJSONObject(index)
            val key = Crypto.decode(item.getString("key"))
            val role = item.getString("role")
            val platform = item.getString("platform")
            if (key.size != 32 || role !in setOf("initiator", "responder") || !validPlatform(platform)) throw JSONException("配对记录无效")
            val pending = item.optBoolean("pending", false)
            val expiresAt = item.optLong("pendingExpiresAtMillis", 0)
            if (pending && TransportLifecycle.pendingExpired(expiresAt, System.currentTimeMillis())) { expiredPending = true; continue }
            val peer = PeerRecord(key, item.getString("name"), platform, role, pending).apply { pendingExpiresAtMillis = if (pending) expiresAt else 0 }
            if (peer.id != item.getString("id")) throw JSONException("设备标识无效")
            peers[peer.id] = peer
        }
        val savedLedger = root.optJSONObject("ledger")
        if (savedLedger != null) {
            val rows = savedLedger.optJSONObject("records")
            if (rows != null) {
                val saved = HashMap<String, PeerState.Record>()
                val keys = rows.keys()
                while (keys.hasNext()) {
                    val id = keys.next()
                    val row = rows.getJSONObject(id)
                    val validUntil = if (row.isNull("validUntil")) null else row.getLong("validUntil")
                    saved[id] = PeerState.Record(parseUnsigned(row.getString("revision")), validUntil)
                }
                ledger.restoreRecords(saved, savedLedger.optBoolean("manualTakeover", false), nowSeconds())
            } else {
                val legacy = HashMap<String, Long>()
                val keys = savedLedger.keys()
                while (keys.hasNext()) { val id = keys.next(); if (savedLedger.opt(id) is String) legacy[id] = parseUnsigned(savedLedger.getString(id)) }
                ledger.restoreRevisions(legacy)
            }
        } else root.optJSONObject("revisions")?.let { revisions ->
            val saved = HashMap<String, Long>()
            val keys = revisions.keys()
            while (keys.hasNext()) { val key = keys.next(); saved[key] = parseUnsigned(revisions.getString(key)) }
            ledger.restoreRevisions(saved)
        }
        if (expiredPending) persist()
    }

    private fun persist(): Boolean = try {
        val root = JSONObject()
            .put("name", deviceName)
            .put("localRevision", java.lang.Long.toUnsignedString(localRevision))
        val array = JSONArray()
        peers.values.forEach { peer ->
            array.put(JSONObject()
                .put("id", peer.id).put("name", peer.name).put("platform", peer.platform)
                .put("role", peer.localRole).put("key", Crypto.base64(peer.key))
                .put("pending", peer.pending).put("pendingExpiresAtMillis", peer.pendingExpiresAtMillis))
        }
        root.put("peers", array)
        val records = JSONObject()
        ledger.records().forEach { (id, record) ->
            records.put(id, JSONObject()
                .put("revision", java.lang.Long.toUnsignedString(record.revision))
                .put("validUntil", record.validUntil ?: JSONObject.NULL))
        }
        root.put("ledger", JSONObject().put("records", records).put("manualTakeover", ledger.manualTakeover()))
        secureStore.write(root.toString().toByteArray(StandardCharsets.UTF_8))
        true
    } catch (error: Exception) {
        postStatus("无法保存配对记录：${safeMessage(error)}")
        false
    }

    private fun saveQuietly() { if (peers.isNotEmpty()) persist() }
    private fun close(closeable: Closeable?) { try { closeable?.close() } catch (_: IOException) { } }
    private fun nowSeconds() = System.currentTimeMillis() / 1000L
    private fun remoteRole(role: String) = if (role == "initiator") "responder" else "initiator"
    private fun localRole(role: String) = role
    private fun validPlatform(value: String) = value == "mac" || value == "ipad" || value == "android" || value == "windows"

    private fun cleanName(value: String?, fallback: String, maxBytes: Int): String {
        val source = value.orEmpty()
        val filtered = buildString {
            source.codePoints().forEach { cp ->
                if (!Character.isISOControl(cp) && Character.getType(cp) != Character.FORMAT.toInt()) appendCodePoint(cp)
            }
        }
        var result = trimWhitespace(filtered)
        while (result.toByteArray(StandardCharsets.UTF_8).size > maxBytes) {
            result = result.substring(0, result.offsetByCodePoints(result.length, -1))
        }
        return result.ifEmpty { fallback }
    }

    private fun trimWhitespace(value: String): String {
        var start = 0
        var end = value.length
        while (start < end) {
            val cp = value.codePointAt(start)
            if (!Character.isWhitespace(cp) && !Character.isSpaceChar(cp)) break
            start += Character.charCount(cp)
        }
        while (end > start) {
            val cp = value.codePointBefore(end)
            if (!Character.isWhitespace(cp) && !Character.isSpaceChar(cp)) break
            end -= Character.charCount(cp)
        }
        return value.substring(start, end)
    }

    private fun safeMessage(error: Exception) = error.message ?: error.javaClass.simpleName
    private fun parseUnsigned(value: String): Long = try { java.lang.Long.parseUnsignedLong(value) } catch (_: Exception) { throw JSONException("无效的版本号") }
    private fun fingerprint(key: ByteArray): String = Crypto.sha256(key).take(8).joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 255) }

    private fun readFrame(input: InputStream): JSONObject {
        val bytes = ByteArrayOutputStream()
        while (true) {
            val value = input.read()
            if (value == -1) throw IOException("连接关闭")
            if (value == '\n'.code) {
                val line = bytes.toByteArray()
                if (line.size > MAX_LINE) throw IOException("消息过大")
                return JSONObject(String(line, StandardCharsets.UTF_8))
            }
            if (bytes.size() >= MAX_LINE) throw IOException("消息过大")
            bytes.write(value)
        }
    }

    private fun writeFrame(output: OutputStream, objectValue: JSONObject) {
        val data = objectValue.toString().toByteArray(StandardCharsets.UTF_8)
        if (data.size > MAX_LINE) throw IOException("消息过大")
        output.write(data); output.write('\n'.code); output.flush()
    }

    private inner class PeerRecord(key: ByteArray, name: String, val platform: String, val localRole: String, var pending: Boolean) {
        val key = key.clone()
        val id = fingerprint(key)
        var name = cleanName(name, platform, 128)
        var pendingExpiresAtMillis = 0L
    }

    private class ResolveRequest(
        val query: NsdServiceInfo,
        val discovery: NsdManager.DiscoveryListener?,
        val initiator: Pairing.Initiator?,
        val network: Network?,
        localPairAddresses: Set<InetAddress>,
        val localPairPort: Int,
        val session: Long,
    ) {
        val localPairAddresses: Set<InetAddress> = Collections.unmodifiableSet(HashSet(localPairAddresses))
        companion object {
            fun forDiscovery(query: NsdServiceInfo, discovery: NsdManager.DiscoveryListener, addresses: Set<InetAddress>, port: Int) =
                ResolveRequest(query, discovery, null, null, addresses, port, 0)
            fun forPair(query: NsdServiceInfo, network: Network, initiator: Pairing.Initiator, session: Long) =
                ResolveRequest(query, null, initiator, network, emptySet(), 0, session)
        }
    }

    private class LocalPairEndpoint(addresses: Set<InetAddress>, val port: Int, val expiresAt: Long) {
        val addresses: Set<InetAddress> = Collections.unmodifiableSet(HashSet(addresses))
    }

    private inner class StateLink(val peer: PeerRecord) {
        private val localOrigin = peer.localRole
        private val remoteOrigin = remoteRole(localOrigin)
        val localMedium = lanMedium
        private val listens = peer.localRole == "initiator"
        private val writer = Executors.newSingleThreadExecutor { task -> Thread(task, "shenglin-peer-writer").apply { isDaemon = true } }
        private var server: ServerSocket? = null
        @Volatile var socket: Socket? = null
            private set
        private var registration: NsdManager.RegistrationListener? = null
        private var browser: NsdManager.DiscoveryListener? = null
        private var nonce: ByteArray? = null
        private var remoteProven = false
        @Volatile var remoteWifiProven = false
            private set
        @Volatile var remoteMedium: String? = null
            private set
        @Volatile var verified = false
            private set
        @Volatile var stopped = false
            private set
        @Volatile private var closing = false
        val generation = TransportLifecycle.Epoch()
        private val connectAttempt = TransportLifecycle.Epoch()
        var lastAckElapsed = 0L
        var lastSentElapsed = 0L
        private var lastName: String? = null
        private val pending = HashSet<Long>()
        @Volatile private var connecting = false

        fun start() {
            if (stopped || lanNetwork == null) return
            if (listens) startServer() else startBrowser()
        }

        fun stop() {
            if (stopped) return
            stopped = true; closing = true
            val nextGeneration = generation.advance()
            connectAttempt.advance()
            registration?.let { try { nsd.unregisterService(it) } catch (_: RuntimeException) { } }
            registration = null
            browser?.let { try { nsd.stopServiceDiscovery(it) } catch (_: RuntimeException) { } }
            browser = null
            close(server); server = null
            val active = socket; socket = null; close(active)
            writer.shutdownNow()
            synchronized(pending) { pending.clear() }
            if (verified) { verified = false; main.post { linkVerified(this, false, nextGeneration) } }
            else main.post { removeLink(this) }
        }

        fun closeAfterWrites(completion: () -> Unit) {
            if (stopped) { completion(); return }
            closing = true
            connectAttempt.advance()
            registration?.let { try { nsd.unregisterService(it) } catch (_: RuntimeException) { } }
            registration = null
            browser?.let { try { nsd.stopServiceDiscovery(it) } catch (_: RuntimeException) { } }
            browser = null
            close(server); server = null
            try {
                writer.execute { main.post { stop(); completion() } }
            } catch (_: java.util.concurrent.RejectedExecutionException) { stop(); completion() }
        }

        private fun startServer() {
            try {
                val active = ServerSocket().apply { reuseAddress = true; bind(java.net.InetSocketAddress(lanAddress, 0)) }
                server = active
                val info = NsdServiceInfo().apply {
                    serviceName = Crypto.serviceName(peer.key)
                    serviceType = STATE_TYPE
                    port = active.localPort
                }
                registration = object : NsdManager.RegistrationListener {
                    override fun onServiceRegistered(serviceInfo: NsdServiceInfo) = Unit
                    override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) { postStatus("局域网状态服务注册失败：$errorCode") }
                    override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit
                    override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
                }
                nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration!!)
                io.execute { acceptState(active) }
            } catch (error: IOException) { postStatus("无法监听局域网状态连接：${safeMessage(error)}") }
        }

        private fun acceptState(active: ServerSocket) {
            while (!stopped && !active.isClosed) {
                var accepted: Socket? = null
                try {
                    accepted = active.accept()
                    if (!accepted.inetAddress.isLoopbackAddress && accepted.localAddress == lanAddress) attach(accepted) else close(accepted)
                } catch (_: IOException) { close(accepted); break }
            }
        }

        private fun startBrowser() {
            if (browser != null || stopped) return
            lateinit var discovery: NsdManager.DiscoveryListener
            discovery = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) = Unit
                override fun onServiceFound(info: NsdServiceInfo) {
                    if (browser !== discovery || info.serviceType != STATE_TYPE || Crypto.serviceName(peer.key) != info.serviceName || socket != null || connecting) return
                    nsd.resolveService(info, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) { main.post { restartBrowser() } }
                        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                            if (browser !== discovery || stopped || socket != null || connecting || lanNetwork == null || serviceInfo.host == null) return
                            connecting = true
                            val attempt = connectAttempt.advance()
                            val selectedNetwork = lanNetwork ?: return
                            io.execute {
                                var candidate: Socket? = null
                                try {
                                    candidate = selectedNetwork.socketFactory.createSocket()
                                    selectedNetwork.bindSocket(candidate)
                                    candidate.connect(java.net.InetSocketAddress(serviceInfo.host, serviceInfo.port), CONNECT_TIMEOUT_MS.toInt())
                                    candidate.soTimeout = CONNECT_TIMEOUT_MS.toInt()
                                    if (connectAttempt.isCurrent(attempt) && browser === discovery && !stopped) attach(candidate)
                                    else close(candidate)
                                } catch (_: Exception) {
                                    close(candidate)
                                    main.post { if (connectAttempt.isCurrent(attempt)) { connecting = false; restartBrowser() } }
                                }
                            }
                        }
                    })
                }
                override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
                override fun onDiscoveryStopped(serviceType: String) = Unit
                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    browser = null
                    main.postDelayed({ if (!stopped && socket == null && !connecting) startBrowser() }, 2000)
                }
                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            }
            browser = discovery
            nsd.discoverServices(STATE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
        }

        private fun restartBrowser() {
            if (stopped || socket != null) return
            connectAttempt.advance()
            browser?.let { try { nsd.stopServiceDiscovery(it) } catch (_: RuntimeException) { } }
            browser = null
            main.postDelayed({ if (!stopped && socket == null && !connecting) startBrowser() }, 2000)
        }

        private fun attach(candidate: Socket) {
            val attachedGeneration: Long
            synchronized(this) {
                if (stopped || socket != null) { close(candidate); return }
                connectAttempt.advance()
                socket = candidate
                attachedGeneration = generation.advance()
                connecting = false
            }
            try { candidate.soTimeout = 0 } catch (_: SocketException) { disconnect(candidate, attachedGeneration); return }
            nonce = Crypto.random(16); remoteProven = false; remoteWifiProven = false; remoteMedium = null
            synchronized(pending) { pending.clear() }
            lastName = null
            main.postDelayed({ if (socket === candidate && generation.isCurrent(attachedGeneration) && !verified) disconnect(candidate, attachedGeneration) }, CONNECT_TIMEOUT_MS)
            try {
                send(candidate, attachedGeneration, "challenge", JSONObject().put("kind", "challenge").put("nonce", Crypto.base64(nonce!!)))
                io.execute { readLoop(candidate, attachedGeneration) }
            } catch (error: Exception) { logFailure("challenge-build", error); disconnect(candidate, attachedGeneration) }
        }

        private fun readLoop(current: Socket, attachedGeneration: Long) {
            var stage = "read"
            try {
                while (!stopped && socket === current && generation.isCurrent(attachedGeneration)) {
                    val frame = readFrame(current.getInputStream())
                    val kind = frame.optString("kind", "")
                    stage = if (kind in setOf("challenge", "proof", "ready", "update", "ack", "name")) "frame-$kind" else "frame-unknown"
                    handle(frame, current, attachedGeneration)
                    stage = "read"
                }
            } catch (error: Exception) { logFailure("state-$stage", error); disconnect(current, attachedGeneration) }
        }

        private fun handle(frame: JSONObject, current: Socket, attachedGeneration: Long) {
            if (!isCurrentSocket(current, attachedGeneration)) return
            when (val kind = frame.getString("kind")) {
                "challenge" -> {
                    val remoteNonce = frame.getString("nonce")
                    if (Crypto.decode(remoteNonce).size != 16) throw IOException("无效挑战")
                    val proof = JSONObject().put("kind", "proof").put("nonce", remoteNonce)
                        .put("signature", Crypto.wifiProof(localOrigin, remoteNonce, peer.key))
                    if (localMedium == "wifi" || localMedium == "ethernet") {
                        proof.put("medium", localMedium).put("mediumSignature", Crypto.networkMediumProof(localOrigin, remoteNonce, localMedium!!, peer.key))
                    }
                    send(current, attachedGeneration, "proof", proof)
                }
                "proof" -> {
                    val remoteNonce = frame.getString("nonce")
                    val signature = frame.getString("signature")
                    if (nonce == null || Crypto.base64(nonce!!) != remoteNonce || !Crypto.validWifiProof(signature, remoteOrigin, remoteNonce, peer.key)) throw IOException("局域网身份验证失败")
                    val mediumValue = frame.opt("medium")
                    val signatureValue = frame.opt("mediumSignature")
                    remoteMedium = mediumValue as? String
                    remoteWifiProven = signatureValue is String && remoteMedium == "wifi" &&
                        Crypto.validNetworkMediumProof(signatureValue, remoteOrigin, remoteNonce, remoteMedium!!, peer.key)
                    nonce = null; remoteProven = true
                    send(current, attachedGeneration, "ready", JSONObject().put("kind", "ready"))
                }
                "ready" -> {
                    if (!remoteProven) throw IOException("状态链路尚未验证")
                    if (!verified) { verified = true; lastAckElapsed = SystemClock.elapsedRealtime(); main.post { linkVerified(this, true, attachedGeneration) } }
                }
                "name" -> {
                    if (!verified) throw IOException("未认证名称")
                    val claim = Wire.name(frame.getJSONObject("name"))
                    if (!claim.valid(peer.key)) throw IOException("设备名称签名无效")
                    main.post { if (isCurrent(current, attachedGeneration)) receiveName(this, claim) }
                }
                "update" -> {
                    if (!verified) throw IOException("未认证状态")
                    val update = Wire.update(frame.getJSONObject("update"))
                    if (!update.valid(peer.key, remoteOrigin, nowSeconds())) throw IOException("设备状态签名无效")
                    main.post { if (isCurrent(current, attachedGeneration)) receiveUpdate(this, update, current, attachedGeneration) }
                }
                "ack" -> {
                    if (!verified) throw IOException("未认证确认")
                    val ack = Wire.ack(frame.getJSONObject("ack"))
                    synchronized(pending) {
                        if (!ack.valid(peer.key, remoteOrigin) || !pending.remove(ack.revision)) throw IOException("确认签名或版本无效")
                    }
                    main.post { if (isCurrent(current, attachedGeneration)) receiveAck(this, ack) }
                }
                else -> throw IOException("未知状态消息：$kind")
            }
        }

        fun sendCurrentState() = sendCurrentState(false)

        fun sendCurrentState(paused: Boolean) {
            if (!verified || stopped || closing) return
            val current = socket
            val expectedGeneration = generation.current()
            try {
                localRevision = incrementRevision(localRevision)
                val update = TransportLifecycle.localUpdate(
                    localOrigin, localRevision, enabled, localRecordingKnown, localRecording,
                    spaceEvidence(peer.id), paused || !enabled, nowSeconds(), peer.key,
                )
                synchronized(pending) { pending.add(update.revision); if (pending.size > 8) pending.remove(pending.iterator().next()) }
                send(current, expectedGeneration, "update", JSONObject().put("kind", "update").put("update", Wire.json(update)))
                lastSentElapsed = SystemClock.elapsedRealtime()
                persist()
            } catch (error: Exception) { logFailure("state-build", error); disconnect(current, expectedGeneration) }
        }

        fun sendCurrentName() {
            if (!verified || stopped || closing || deviceName == lastName) return
            val current = socket
            val expectedGeneration = generation.current()
            try {
                val claim = PeerState.NameClaim.signed(deviceName, peer.key)
                send(current, expectedGeneration, "name", JSONObject().put("kind", "name").put("name", Wire.json(claim)))
                lastName = deviceName
            } catch (error: Exception) { logFailure("name-build", error); disconnect(current, expectedGeneration) }
        }

        fun send(current: Socket?, expectedGeneration: Long, stage: String, frame: JSONObject) {
            if (current == null || current.isClosed || closing || !generation.isCurrent(expectedGeneration)) return
            try {
                writer.execute {
                    if (stopped || socket !== current || !generation.isCurrent(expectedGeneration)) return@execute
                    try { synchronized(current) { writeFrame(current.getOutputStream(), frame) } }
                    catch (error: Exception) { logFailure("$stage-write", error); disconnect(current, expectedGeneration) }
                }
            } catch (error: java.util.concurrent.RejectedExecutionException) { logFailure("$stage-write-queue", error); disconnect(current, expectedGeneration) }
        }

        private fun isCurrentSocket(current: Socket, expectedGeneration: Long) = socket === current && generation.isCurrent(expectedGeneration)
        private fun isCurrent(current: Socket, expectedGeneration: Long) = !stopped && !closing && verified && isCurrentSocket(current, expectedGeneration)

        private fun disconnect(current: Socket?, expectedGeneration: Long) {
            if (current == null || socket !== current || !generation.isCurrent(expectedGeneration)) return
            socket = null; close(current); nonce = null; remoteProven = false; remoteWifiProven = false; remoteMedium = null
            synchronized(pending) { pending.clear() }
            lastName = null
            val wasVerified = verified
            verified = false
            val nextGeneration = generation.advance()
            if (wasVerified) main.post { linkVerified(this, false, nextGeneration) }
            else main.post { linkDisconnected(this) }
            if (!stopped && !listens) main.postDelayed({
                if (socket != null || stopped) return@postDelayed
                browser?.let { try { nsd.stopServiceDiscovery(it) } catch (_: RuntimeException) { } }
                browser = null
                startBrowser()
            }, 2000)
        }
    }

    private fun incrementRevision(value: Long): Long {
        val next = value + 1
        val wall = System.currentTimeMillis()
        return if (java.lang.Long.compareUnsigned(next, wall) < 0) wall else next
    }
}
