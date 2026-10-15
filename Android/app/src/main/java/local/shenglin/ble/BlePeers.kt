package local.shenglin.ble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import android.util.Log
import local.shenglin.core.PeerState
import local.shenglin.core.Wire
import org.json.JSONException
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import java.util.Arrays
import java.util.HashMap
import java.util.HashSet
import java.util.LinkedHashMap
import java.util.UUID

/** Already-paired BLE links. Public methods and listener callbacks run on the main thread. */
@Suppress("DEPRECATION")
class BlePeers(context: Context, private val listener: Listener) {
    interface Listener {
        fun localUpdate(peerId: String): PeerState.Update
        fun receiveUpdate(peerId: String, update: PeerState.Update): PeerState.Ack
        fun receivedAck(peerId: String, ack: PeerState.Ack)
        fun verifiedChanged(peerId: String, verified: Boolean)
        fun issue(message: String)
    }

    class Peer(id: String, key: ByteArray, platform: String, localRole: String) {
        @JvmField val id = id
        @JvmField val platform = platform
        @JvmField val localRole = localRole
        private val key = key.clone()

        init {
            require(key.size == 32 && (localRole == "initiator" || localRole == "responder")) { "无效配对关系" }
            BleProtocol.central(platform, localRole)
        }

        fun key(): ByteArray = key.clone()
        fun remote() = if (localRole == "initiator") "responder" else "initiator"
        fun same(other: Peer) = id == other.id && platform == other.platform && localRole == other.localRole && key.contentEquals(other.key)
    }

    companion object {
        @JvmField val SERVICE: UUID = UUID.fromString("8A27D37F-A94F-4A53-AD7C-0D48CC8108CF")
        private val STATE_WRITE = UUID.fromString("E1FA496A-299F-4C84-9621-63396F75A3F2")
        private val STATE_ACK = UUID.fromString("0F20B426-BBC9-48A4-A518-82827239AA9E")
        private val PEER_STATE = UUID.fromString("1AD254E9-97D9-443F-AB4B-C815B92CD364")
        private val PEER_ACK = UUID.fromString("51BCDB25-1849-480E-9512-2E41A2E52622")
        private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val peers = LinkedHashMap<String, Peer>()
    private val centrals = HashMap<String, Central>()
    private val peripherals = HashMap<String, Peripheral>()
    private val retryAfter = HashMap<String, Long>()
    private val verified = HashSet<String>()
    private val notifications = ArrayDeque<Notification>()
    private var adapter: BluetoothAdapter? = null
    private var scanner: BluetoothLeScanner? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var server: BluetoothGattServer? = null
    private var ackCharacteristic: BluetoothGattCharacteristic? = null
    private var stateCharacteristic: BluetoothGattCharacteristic? = null
    private var started = false
    private var receiverRegistered = false
    private var notifying = false
    private var epoch = 0L
    private var lastPublish = 0L
    private var lastIssue: String? = null
    private var scanCallback: ScanCallback? = null
    private var advertiseCallback: AdvertiseCallback? = null

    private val bluetoothState = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = restart()
    }

    private fun assertMain() {
        check(Looper.myLooper() == Looper.getMainLooper()) { "BLE 必须在主线程调用" }
    }

    fun setPeers(values: List<Peer>) {
        assertMain()
        val next = LinkedHashMap<String, Peer>().apply { values.forEach { put(it.id, it) } }
        val changed = next.size != peers.size || next.values.any { !it.same(peers[it.id] ?: return@any true) }
        if (!changed) return
        peers.clear()
        peers.putAll(next)
        restart()
    }

    fun start() {
        assertMain()
        if (started) {
            restart()
            return
        }
        started = true
        context.registerReceiver(bluetoothState, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        receiverRegistered = true
        restart()
        main.post(tick)
    }

    fun stop() {
        assertMain()
        started = false
        main.removeCallbacks(tick)
        val closingEpoch = epoch
        verified.toList().forEach {
            verified.remove(it)
            listener.verifiedChanged(it, false)
        }
        // Leave the last signed clear queued for ATT or the peer's one-second read poll.
        main.postDelayed({ if (!started && epoch == closingEpoch) stopRuntime() }, 1_500)
        if (receiverRegistered) {
            context.unregisterReceiver(bluetoothState)
            receiverRegistered = false
        }
    }

    fun publish() {
        assertMain()
        if (!started) return
        centrals.values.toList().filter { it.ready }.forEach { it.publish() }
        peripherals.values.toList().filter { it.peer != null }.forEach(::publish)
        lastPublish = elapsed()
    }

    private fun issue(value: String) {
        if (lastIssue != value) {
            lastIssue = value
            listener.issue(value)
        }
    }

    private fun permissions(): Boolean = if (Build.VERSION.SDK_INT >= 31) {
        granted(Manifest.permission.BLUETOOTH_SCAN) && granted(Manifest.permission.BLUETOOTH_CONNECT) &&
            granted(Manifest.permission.BLUETOOTH_ADVERTISE)
    } else granted(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun granted(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun restart() {
        stopRuntime()
        if (!started || peers.isEmpty()) return
        if (!permissions()) {
            issue("蓝牙权限未授予，近距条件尚未验证")
            return
        }
        val manager = context.getSystemService(BluetoothManager::class.java)
        adapter = manager?.adapter
        try {
            val bluetooth = adapter
            if (bluetooth == null || !bluetooth.isEnabled) {
                issue("蓝牙未开启，近距条件尚未验证")
                return
            }
            val needCentral = peers.values.any { BleProtocol.central(it.platform, it.localRole) }
            val needPeripheral = peers.values.any { !BleProtocol.central(it.platform, it.localRole) }
            if (needCentral) startScan()
            if (needPeripheral && manager != null) startServer(manager)
        } catch (error: SecurityException) {
            issue("蓝牙启动失败：${error.message}")
        } catch (error: IllegalStateException) {
            issue("蓝牙启动失败：${error.message}")
        }
    }

    private fun stopRuntime() {
        epoch++
        try {
            scanner?.let { scan -> scanCallback?.let(scan::stopScan) }
            advertiser?.let { adv -> advertiseCallback?.let(adv::stopAdvertising) }
        } catch (_: SecurityException) {
        } catch (_: IllegalStateException) {
        }
        scanner = null
        advertiser = null
        scanCallback = null
        advertiseCallback = null
        centrals.values.toList().forEach(Central::close)
        centrals.clear()
        peripherals.clear()
        notifications.clear()
        notifying = false
        try {
            server?.close()
        } catch (_: SecurityException) {
        }
        server = null
        verified.toList().forEach {
            verified.remove(it)
            listener.verifiedChanged(it, false)
        }
    }

    private fun refreshProof(id: String) {
        val now = elapsed()
        val value = started && (
            centrals.values.any { it.peer.id == id && it.proof.verified(now) } ||
                peripherals.values.any { it.peer?.id == id && it.proof.verified(now) }
            )
        val changed = if (value) verified.add(id) else verified.remove(id)
        if (changed) {
            Log.i("ShenglinBLE", "proof=$value peer=$id")
            listener.verifiedChanged(id, value)
        }
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!started) return
            val now = elapsed()
            retryAfter.entries.removeIf { it.value <= now }
            centrals.values.toList().forEach { central ->
                if ((!central.everVerified && now - central.connectedAt >= 12_000) ||
                    (central.everVerified && !central.proof.verified(now))
                ) central.close() else if (central.ready) {
                    central.read(STATE_ACK)
                    central.read(PEER_STATE)
                }
            }
            peripherals.values.toList().forEach { peripheral ->
                if ((!peripheral.everVerified && now - peripheral.connectedAt >= 15_000) ||
                    (peripheral.everVerified && !peripheral.proof.verified(now))
                ) disconnect(peripheral)
            }
            if (now - lastPublish >= 5_000) publish()
            peers.keys.toList().forEach(::refreshProof)
            main.postDelayed(this, 1_000)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startScan() {
        scanner = adapter?.bluetoothLeScanner
        val activeScanner = scanner
        if (activeScanner == null) {
            issue("此设备无法扫描蓝牙设备")
            return
        }
        val generation = epoch
        scanCallback = object : ScanCallback() {
            override fun onScanResult(type: Int, result: ScanResult) {
                main.post { if (generation == epoch) discovered(result.device) }
            }

            override fun onScanFailed(code: Int) {
                main.post { if (generation == epoch) issue("蓝牙扫描失败：$code") }
            }
        }
        activeScanner.startScan(
            listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()),
            ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build(),
            scanCallback,
        )
    }

    private fun discovered(device: BluetoothDevice) {
        try {
            val address = device.address
            if (centrals.containsKey(address) || centrals.size >= peers.size) return
            for (peer in peers.values) {
                if (!BleProtocol.central(peer.platform, peer.localRole) || retryAfter.getOrDefault(peer.id + address, 0L) > elapsed()) continue
                if (centrals.values.any { it.peer.id == peer.id }) continue
                Central(peer, device).also { centrals[address] = it; it.connect() }
                return
            }
        } catch (_: SecurityException) {
            issue("蓝牙连接权限不可用")
        }
    }

    private fun encode(value: JSONObject): ByteArray = value.toString().toByteArray(StandardCharsets.UTF_8).also {
        require(it.size <= BleProtocol.MAX_VALUE) { "蓝牙消息超过 512 字节" }
    }

    @Throws(JSONException::class)
    private fun decode(value: ByteArray?): JSONObject {
        if (value == null || value.isEmpty() || value.size > BleProtocol.MAX_VALUE) throw JSONException("蓝牙消息长度无效")
        return JSONObject(String(value, StandardCharsets.UTF_8))
    }

    private fun elapsed() = SystemClock.elapsedRealtime()
    private fun wall() = System.currentTimeMillis() / 1_000L

    private inner class Central(val peer: Peer, private val device: BluetoothDevice) {
        val address = device.address
        val connectedAt = elapsed()
        val generation = epoch
        val proof = BleProtocol.Proof()
        private val queue = ArrayDeque<Operation>()
        private var gatt: BluetoothGatt? = null
        private var service: BluetoothGattService? = null
        private var active: Operation? = null
        var ready = false
            private set
        var closed = false
            private set
        var everVerified = false
            private set

        @SuppressLint("MissingPermission")
        fun connect() {
            gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            if (gatt == null) close()
        }

        private fun current(candidate: BluetoothGatt) = !closed && generation == epoch && gatt === candidate

        private fun post(candidate: BluetoothGatt, action: () -> Unit) {
            main.post {
                if (current(candidate)) try {
                    action()
                } catch (_: SecurityException) {
                    close()
                } catch (_: IllegalArgumentException) {
                    close()
                }
            }
        }

        private val callback = object : BluetoothGattCallback() {
            @SuppressLint("MissingPermission")
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) = post(gatt) {
                if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                    close()
                    return@post
                }
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    Log.i("ShenglinBLE", "central connected; requesting MTU")
                    if (!gatt.requestMtu(517)) discover()
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) = post(gatt) {
                Log.i("ShenglinBLE", "central mtu=$mtu status=$status")
                discover()
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) = post(gatt) {
                service = gatt.getService(SERVICE)
                val found = service
                if (status != BluetoothGatt.GATT_SUCCESS || found == null) {
                    close()
                    return@post
                }
                if (listOf(STATE_WRITE, STATE_ACK, PEER_STATE, PEER_ACK).any { found.getCharacteristic(it) == null }) {
                    close()
                    return@post
                }
                subscribe(STATE_ACK)
                subscribe(PEER_STATE)
            }

            override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) = post(gatt) {
                if (!complete(2, descriptor.characteristic.uuid, status)) return@post
                if (queue.isEmpty() && active == null && !ready) {
                    ready = true
                    publish()
                    read(PEER_STATE)
                }
            }

            override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) =
                post(gatt) { complete(1, characteristic.uuid, status) }

            override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
                val value = characteristic.value?.clone()
                post(gatt) { if (complete(0, characteristic.uuid, status) && status == BluetoothGatt.GATT_SUCCESS) received(characteristic.uuid, value) }
            }

            override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                val value = characteristic.value?.clone()
                post(gatt) { received(characteristic.uuid, value) }
            }
        }

        @SuppressLint("MissingPermission")
        private fun discover() {
            val current = gatt ?: return
            if (!current.discoverServices()) close()
        }

        private fun subscribe(id: UUID) = enqueue(Operation(2, id, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE))
        fun read(id: UUID) { if (ready) enqueue(Operation(0, id, null)) }
        private fun write(id: UUID, data: ByteArray) = enqueue(Operation(1, id, data))

        private fun enqueue(operation: Operation) {
            if (closed) return
            if (operation.kind == 0) {
                if (active?.let { it.kind == 0 && it.id == operation.id } == true || queue.any { it.kind == 0 && it.id == operation.id }) return
            }
            if (queue.size >= 16) {
                close()
                return
            }
            queue.add(operation)
            pump()
        }

        private fun pump() {
            try {
                pumpOperation()
            } catch (error: SecurityException) {
                issue("蓝牙操作不可用：${error.message}")
                close()
            } catch (error: IllegalStateException) {
                issue("蓝牙操作不可用：${error.message}")
                close()
            }
        }

        @SuppressLint("MissingPermission")
        private fun pumpOperation() {
            if (closed || active != null || queue.isEmpty()) return
            val currentGatt = gatt ?: run { close(); return }
            val currentService = service ?: run { close(); return }
            active = queue.remove()
            val operation = active ?: return
            val characteristic = currentService.getCharacteristic(operation.id) ?: run { close(); return }
            val accepted = when (operation.kind) {
                0 -> currentGatt.readCharacteristic(characteristic)
                1 -> {
                    characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    characteristic.value = operation.data
                    currentGatt.writeCharacteristic(characteristic)
                }
                else -> {
                    val descriptor = characteristic.getDescriptor(CCCD) ?: run { close(); return }
                    if (!currentGatt.setCharacteristicNotification(characteristic, true)) {
                        close()
                        return
                    }
                    descriptor.value = operation.data
                    currentGatt.writeDescriptor(descriptor)
                }
            }
            if (!accepted) {
                close()
                return
            }
            main.postDelayed({ if (!closed && active === operation) close() }, 8_000)
        }

        private fun complete(kind: Int, id: UUID, status: Int): Boolean {
            val operation = active ?: return false
            if (operation.kind != kind || operation.id != id) return false
            active = null
            // A peripheral may not have state to read before its first authenticated write.
            if (status != BluetoothGatt.GATT_SUCCESS && kind != 0) {
                close()
                return false
            }
            pump()
            return true
        }

        fun publish() {
            if (!ready || closed) return
            try {
                val update = listener.localUpdate(peer.id)
                proof.sent(update)
                write(STATE_WRITE, encode(Wire.json(update)))
            } catch (error: Exception) {
                issue("蓝牙状态发送失败：${error.message}")
                close()
            }
        }

        private fun received(id: UUID, data: ByteArray?) {
            if (!ready || closed || !started) return
            try {
                when (id) {
                    STATE_ACK -> {
                        val ack = Wire.ack(decode(data))
                        if (proof.accept(ack, peer.key(), peer.remote(), wall(), elapsed())) {
                            everVerified = true
                            refreshProof(peer.id)
                            listener.receivedAck(peer.id, ack)
                        }
                    }
                    PEER_STATE -> {
                        val update = Wire.update(decode(data))
                        if (!update.valid(peer.key(), peer.remote(), wall())) return
                        val ack = listener.receiveUpdate(peer.id, update)
                        write(PEER_ACK, encode(Wire.json(ack)))
                    }
                }
            } catch (_: JSONException) {
                // Short notifications are ignored; the next long read retrieves the complete value.
            } catch (_: IllegalArgumentException) {
                // Invalid wire data is ignored without changing authenticated state.
            }
        }

        fun close() {
            if (closed) return
            closed = true
            ready = false
            queue.clear()
            active = null
            proof.clear()
            if (centrals[address] === this) centrals.remove(address)
            retryAfter[peer.id + address] = elapsed() + 10_000
            try {
                gatt?.disconnect()
                gatt?.close()
            } catch (_: SecurityException) {
            }
            gatt = null
            refreshProof(peer.id)
        }
    }

    private class Operation(val kind: Int, val id: UUID, data: ByteArray?) {
        val data = data?.clone()
    }

    private inner class Peripheral(val device: BluetoothDevice) {
        val connectedAt = elapsed()
        val proof = BleProtocol.Proof()
        val prepared = BleProtocol.PreparedWrite()
        val snapshots = HashMap<UUID, ByteArray>()
        val subscriptions = HashSet<UUID>()
        var peer: Peer? = null
        var mtu = 23
        var everVerified = false
        var ack: ByteArray? = null
        var outgoing: ByteArray? = null
    }

    @SuppressLint("MissingPermission")
    private fun startServer(manager: BluetoothManager) {
        advertiser = adapter?.bluetoothLeAdvertiser
        val activeAdvertiser = advertiser
        if (activeAdvertiser == null) {
            issue("此设备不支持蓝牙外设广播，部分设备无法验证近距条件")
            return
        }
        val generation = epoch
        val callback = object : BluetoothGattServerCallback() {
            private fun post(action: () -> Unit) {
                main.post {
                    if (generation == epoch && server != null) try {
                        action()
                    } catch (_: SecurityException) {
                        issue("蓝牙权限不可用")
                    }
                }
            }

            override fun onServiceAdded(status: Int, service: BluetoothGattService) = post {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    issue("蓝牙服务注册失败：$status")
                    return@post
                }
                advertise(generation)
            }

            override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) = post {
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    peripherals[device.address] = Peripheral(device)
                    Log.i("ShenglinBLE", "peripheral connected")
                } else {
                    val disconnected = peripherals.remove(device.address)
                    disconnected?.peer?.let { refreshProof(it.id) }
                    restartAdvertising(generation)
                }
            }

            override fun onMtuChanged(device: BluetoothDevice, mtu: Int) = post {
                peripherals[device.address]?.let {
                    it.mtu = mtu
                    Log.i("ShenglinBLE", "peripheral mtu=$mtu")
                }
            }

            override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) =
                post { readRequest(device, requestId, offset, characteristic.uuid) }

            override fun onCharacteristicWriteRequest(
                device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
                preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
            ) {
                val copy = value?.clone()
                post { writeRequest(device, requestId, characteristic.uuid, preparedWrite, responseNeeded, offset, copy) }
            }

            override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) = post {
                val peripheral = peripherals[device.address]
                var status = BluetoothGatt.GATT_FAILURE
                if (peripheral != null) {
                    status = when {
                        !execute -> BluetoothGatt.GATT_SUCCESS
                        peripheral.prepared.characteristic() != null -> process(
                            peripheral, UUID.fromString(peripheral.prepared.characteristic()), peripheral.prepared.value(),
                        )
                        else -> BluetoothGatt.GATT_FAILURE
                    }
                    peripheral.prepared.clear()
                }
                if (status != BluetoothGatt.GATT_SUCCESS) Log.w("ShenglinBLE", "execute-write rejected status=$status")
                respond(device, requestId, status, 0, null)
            }

            override fun onDescriptorWriteRequest(
                device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
                preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
            ) {
                val copy = value?.clone()
                post {
                    val peripheral = peripherals[device.address]
                    var status = BluetoothGatt.GATT_FAILURE
                    if (peripheral != null && CCCD == descriptor.uuid && !preparedWrite && offset == 0 &&
                        (Arrays.equals(copy, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
                            Arrays.equals(copy, BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE))
                    ) {
                        val id = descriptor.characteristic.uuid
                        if (Arrays.equals(copy, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) peripheral.subscriptions.add(id)
                        else peripheral.subscriptions.remove(id)
                        status = BluetoothGatt.GATT_SUCCESS
                    }
                    if (responseNeeded) respond(device, requestId, status, offset, null)
                }
            }

            override fun onDescriptorReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, descriptor: BluetoothGattDescriptor) = post {
                val peripheral = peripherals[device.address]
                val value = if (peripheral != null && descriptor.characteristic.uuid in peripheral.subscriptions)
                    BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                if (offset < 0 || offset > value.size) respond(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                else respond(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value.copyOfRange(offset, value.size))
            }

            override fun onNotificationSent(device: BluetoothDevice, status: Int) = post {
                notifying = false
                notifyNext()
            }
        }

        server = manager.openGattServer(context, callback)
        val activeServer = server
        if (activeServer == null) {
            issue("无法创建蓝牙外设服务")
            return
        }
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(BluetoothGattCharacteristic(STATE_WRITE, BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE))
        service.addCharacteristic(BluetoothGattCharacteristic(PEER_ACK, BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE))
        ackCharacteristic = readable(STATE_ACK)
        stateCharacteristic = readable(PEER_STATE)
        service.addCharacteristic(ackCharacteristic)
        service.addCharacteristic(stateCharacteristic)
        if (!activeServer.addService(service)) issue("无法注册蓝牙外设服务")
    }

    private fun readable(id: UUID) = BluetoothGattCharacteristic(
        id, BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
        BluetoothGattCharacteristic.PERMISSION_READ,
    ).apply {
        addDescriptor(BluetoothGattDescriptor(CCCD, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
    }

    private fun advertise(generation: Long) {
        if (!started || generation != epoch || server == null || peers.values.none { !BleProtocol.central(it.platform, it.localRole) }) return
        lateinit var callback: AdvertiseCallback
        callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settings: AdvertiseSettings) {
                if (generation == epoch && advertiseCallback === callback && started && server != null)
                    Log.i("ShenglinBLE", "advertising ready")
            }
            override fun onStartFailure(code: Int) {
                main.post {
                    if (generation == epoch && advertiseCallback === callback && started && server != null)
                        issue("蓝牙广播失败：$code")
                }
            }
        }
        advertiseCallback = callback
        try {
            advertiser?.startAdvertising(
                AdvertiseSettings.Builder().setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED).setConnectable(true).build(),
                AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).build(),
                callback,
            )
        } catch (_: SecurityException) {
            if (generation == epoch && advertiseCallback === callback) issue("蓝牙广播权限不可用")
        } catch (_: IllegalStateException) {
            if (generation == epoch && advertiseCallback === callback) issue("无法启动蓝牙广播")
        }
    }

    /** A GATT disconnect is the reliable event at which to re-arm a possibly consumed connectable advertisement. */
    @SuppressLint("MissingPermission")
    private fun restartAdvertising(generation: Long) {
        if (!started || generation != epoch || server == null || peers.values.none { !BleProtocol.central(it.platform, it.localRole) }) return
        val activeAdvertiser = advertiser ?: return
        val previous = advertiseCallback
        if (previous != null) {
            try { activeAdvertiser.stopAdvertising(previous) }
            catch (_: SecurityException) { issue("蓝牙广播权限不可用"); return }
            catch (_: IllegalStateException) { issue("无法重启蓝牙广播"); return }
        }
        advertiseCallback = null
        if (started && generation == epoch && server != null) advertise(generation)
    }

    private fun respond(device: BluetoothDevice, request: Int, status: Int, offset: Int, value: ByteArray?) {
        try {
            server?.sendResponse(device, request, status, offset, value)
        } catch (_: SecurityException) {
            issue("蓝牙响应权限不可用")
        }
    }

    private fun readRequest(device: BluetoothDevice, request: Int, offset: Int, id: UUID) {
        val peripheral = peripherals[device.address]
        if (peripheral?.peer == null || (id != STATE_ACK && id != PEER_STATE)) {
            Log.d("ShenglinBLE", "read awaits authenticated identity characteristic=$id")
            respond(device, request, BluetoothGatt.GATT_FAILURE, offset, null)
            return
        }
        try {
            if (offset == 0) {
                val value = (if (id == STATE_ACK) peripheral.ack else if (started) localState(peripheral) else peripheral.outgoing)
                    ?: throw IllegalArgumentException("尚无状态")
                peripheral.snapshots[id] = value
            }
            val bytes = BleProtocol.slice(peripheral.snapshots[id], offset, peripheral.mtu)
            respond(device, request, BluetoothGatt.GATT_SUCCESS, offset, bytes)
        } catch (_: Exception) {
            respond(device, request, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
        }
    }

    private fun writeRequest(
        device: BluetoothDevice, request: Int, id: UUID,
        prepared: Boolean, response: Boolean, offset: Int, value: ByteArray?,
    ) {
        val peripheral = peripherals[device.address]
        var status = BluetoothGatt.GATT_FAILURE
        if (peripheral != null && (id == STATE_WRITE || id == PEER_ACK)) {
            status = if (prepared) {
                try {
                    peripheral.prepared.append(id.toString(), offset, value)
                    BluetoothGatt.GATT_SUCCESS
                } catch (_: IllegalArgumentException) {
                    BluetoothGatt.GATT_INVALID_OFFSET
                }
            } else if (offset == 0 && value != null && value.size <= BleProtocol.MAX_VALUE) process(peripheral, id, value)
            else BluetoothGatt.GATT_INVALID_OFFSET
        }
        if (status != BluetoothGatt.GATT_SUCCESS) {
            Log.w("ShenglinBLE", "write rejected characteristic=$id prepared=$prepared offset=$offset bytes=${value?.size ?: 0} status=$status")
        }
        if (response) respond(device, request, status, offset, if (prepared && status == BluetoothGatt.GATT_SUCCESS) value else null)
    }

    private fun process(peripheral: Peripheral, id: UUID, bytes: ByteArray): Int {
        try {
            if (id == STATE_WRITE) {
                if (!started) return BluetoothGatt.GATT_FAILURE
                val update = Wire.update(decode(bytes))
                var match = peripheral.peer
                if (match == null) match = peers.values.firstOrNull {
                    !BleProtocol.central(it.platform, it.localRole) && update.valid(it.key(), it.remote(), wall())
                }
                if (match == null || !update.valid(match.key(), match.remote(), wall())) {
                    Log.w("ShenglinBLE", "state rejected: no matching active identity, origin=${update.origin}")
                    return BluetoothGatt.GATT_FAILURE
                }
                peripheral.peer = match
                peripheral.ack = encode(Wire.json(listener.receiveUpdate(match.id, update)))
                notifyValue(peripheral, ackCharacteristic, peripheral.ack!!)
                publish(peripheral)
                return BluetoothGatt.GATT_SUCCESS
            }
            if (id == PEER_ACK && peripheral.peer != null) {
                val peer = peripheral.peer!!
                val ack = Wire.ack(decode(bytes))
                if (!ack.valid(peer.key(), peer.remote())) return BluetoothGatt.GATT_FAILURE
                if (peripheral.proof.accept(ack, peer.key(), peer.remote(), wall(), elapsed())) {
                    peripheral.everVerified = true
                    refreshProof(peer.id)
                    listener.receivedAck(peer.id, ack)
                }
                return BluetoothGatt.GATT_SUCCESS
            }
        } catch (error: Exception) {
            issue("蓝牙消息处理失败：${error.message}")
        }
        return BluetoothGatt.GATT_FAILURE
    }

    @Throws(JSONException::class)
    private fun localState(peripheral: Peripheral): ByteArray {
        val peerId = peripheral.peer?.id ?: throw JSONException("peer not authenticated")
        val update = listener.localUpdate(peerId)
        peripheral.proof.sent(update)
        return encode(Wire.json(update)).also { peripheral.outgoing = it }
    }

    private fun publish(peripheral: Peripheral) {
        if (peripheral.peer == null || server == null || !started) return
        try {
            notifyValue(peripheral, stateCharacteristic, localState(peripheral))
        } catch (error: Exception) {
            issue("蓝牙状态发布失败：${error.message}")
        }
    }

    private fun disconnect(peripheral: Peripheral) {
        peripherals.remove(peripheral.device.address)
        notifications.removeIf { it.peripheral === peripheral }
        try {
            server?.cancelConnection(peripheral.device)
        } catch (_: SecurityException) {
        }
        peripheral.proof.clear()
        peripheral.peer?.let { refreshProof(it.id) }
    }

    private class Notification(val peripheral: Peripheral, val characteristic: BluetoothGattCharacteristic, value: ByteArray) {
        val value = value.clone()
    }

    private fun notifyValue(peripheral: Peripheral, characteristic: BluetoothGattCharacteristic?, value: ByteArray) {
        val target = characteristic ?: return
        // Keep the complete signed value available through offset reads if MTU cannot carry it.
        if (target.uuid !in peripheral.subscriptions || value.size > peripheral.mtu - 3 || notifications.size >= 32) return
        notifications.removeIf { it.peripheral === peripheral && it.characteristic === target }
        notifications.add(Notification(peripheral, target, value))
        notifyNext()
    }

    private fun notifyNext() {
        if (notifying || server == null || notifications.isEmpty()) return
        val notification = notifications.remove()
        notification.characteristic.value = notification.value
        try {
            notifying = server?.notifyCharacteristicChanged(notification.peripheral.device, notification.characteristic, false) == true
        } catch (_: SecurityException) {
            notifying = false
            notifications.clear()
            issue("蓝牙通知权限不可用")
        }
        if (!notifying) notifyNext()
    }
}
