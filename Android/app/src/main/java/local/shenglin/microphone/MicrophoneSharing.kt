package local.shenglin.microphone

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import local.shenglin.core.Crypto
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

internal data class MicrophonePeer(val id: String, val key: ByteArray, val role: String)

/** 配对与网络由 PeerTransport 持有；这里仅提供已授权内置输入的按需音频。 */
internal class MicrophoneSharing(private val context: Context, private val changed: () -> Unit) : Closeable {
    private val main = Handler(Looper.getMainLooper())
    private val audio = context.getSystemService(AudioManager::class.java)
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private val workers = ThreadPoolExecutor(0, 8, 30, TimeUnit.SECONDS, SynchronousQueue<Runnable>())
    private val endpoints = mutableMapOf<String, Endpoint>()
    private val captureLock = ReentrantLock()
    private var address: InetAddress? = null
    private var retryAfter = 0L
    private var portAddress: InetAddress? = null
    private val ports = mutableMapOf<String, Int>()
    @Volatile var ownSession: Int? = null
        private set
    @Volatile var status = "共享已关闭"
        private set
    val capturing get() = ownSession != null

    fun update(enabled: Boolean, address: InetAddress?, peers: List<MicrophonePeer>) {
        check(Looper.myLooper() == Looper.getMainLooper())
        val selected = if (enabled) address else null
        if (address != null && portAddress != address) { ports.clear(); portAddress = address }
        if (this.address != selected) { endpoints.values.forEach { it.close() }; endpoints.clear(); this.address = selected; retryAfter = 0 }
        val allowed = peers.map { it.id }.toSet()
        endpoints.keys.filter { it !in allowed }.forEach { endpoints.remove(it)?.close() }
        if (selected != null && SystemClock.elapsedRealtime() >= retryAfter) {
            peers.filter { it.id !in endpoints }.forEach { peer ->
                try { endpoints[peer.id] = Endpoint(selected, peer).also { it.start() } }
                catch (error: Exception) { retryAfter = SystemClock.elapsedRealtime() + 5000; report("麦克风服务启动失败：${error.message}") }
            }
        }
        if (!enabled) report("共享已关闭")
        else if (selected == null) report("等待局域网连接")
        else if (peers.isEmpty()) report("请在设备详情中授权接收设备")
        else if (!capturing && status in setOf("共享已关闭", "等待局域网连接", "请在设备详情中授权接收设备")) report("等待接收设备使用")
    }

    private fun report(value: String) {
        if (status != value) { status = value; main.post(changed) }
    }
    private fun builtin() = audio.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_MIC }

    private inner class Endpoint(address: InetAddress, val peer: MicrophonePeer) : Closeable {
        private val server = ServerSocketChannel.open().apply {
            try {
                socket().reuseAddress = true
                socket().bind(InetSocketAddress(address, ports[peer.id] ?: 0), 8)
                // A stable SRV target avoids old Android mDNS treating a quick re-grant as a name conflict.
                ports[peer.id] = socket().localPort
            } catch (error: Exception) { close(); ports.remove(peer.id); throw error }
        }
        private val clients = ConcurrentHashMap.newKeySet<SocketChannel>()
        @Volatile private var closed = false
        private var registered = false
        private val name = "${Crypto.serviceName(peer.key)}-${peer.role}"
        private val registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                main.post { if (!closed && info.serviceName != name) fail("麦克风服务名称冲突") }
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) { main.post { registered = false; if (!closed) fail("麦克风发现服务失败：$code") } }
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) = Unit
        }
        fun start() {
            try {
                nsd.registerService(NsdServiceInfo().apply { serviceName = name; serviceType = "_shenglin-mic._tcp."; port = server.socket().localPort }, NsdManager.PROTOCOL_DNS_SD, registration)
                registered = true
                Thread({ accept() }, "Shenglin-microphone-listener").start()
            } catch (error: Exception) { close(); throw error }
        }
        private fun fail(message: String) {
            close(); if (endpoints[peer.id] === this) endpoints.remove(peer.id)
            retryAfter = SystemClock.elapsedRealtime() + 5000; report(message)
        }
        private fun accept() {
            try {
                while (!closed) {
                    val channel = server.accept()
                    clients.add(channel)
                    if (closed) { channel.close(); clients.remove(channel); break }
                    try { workers.execute { serve(channel) } }
                    catch (_: java.util.concurrent.RejectedExecutionException) { clients.remove(channel); channel.close() }
                }
            } catch (error: Exception) { if (!closed) main.post { if (!closed) fail("麦克风连接服务中断：${error.message}") } }
        }
        private fun serve(channel: SocketChannel) {
            try {
                MicrophoneWire(channel).use { wire ->
                    wire.authenticate(peer.key, peer.role)
                    val request = wire.request()
                    try {
                        when (request.getString("operation")) {
                            "list" -> wire.respond(JSONObject().put("sources", JSONArray().apply {
                                if (builtin() != null) put(JSONObject().put("id", "android.builtin").put("name", "内置麦克风").put("sampleRate", 48000).put("channels", 1))
                            }))
                            "stream" -> {
                                require(request.getString("sourceID") == "android.builtin") { "麦克风不存在或未授权" }
                                check(captureLock.tryLock()) { "内置麦克风正供另一接收设备使用" }
                                try { capture(wire, channel) }
                                catch (error: Exception) {
                                    if (!closed && channel.isOpen && error !is java.io.IOException) report(error.message ?: "麦克风采集失败")
                                    throw error
                                } finally { captureLock.unlock() }
                            }
                            else -> throw IllegalArgumentException("不支持的麦克风请求")
                        }
                    } catch (error: Exception) {
                        if (!closed && channel.isOpen) wire.respond(JSONObject().put("error", error.message ?: "麦克风采集失败"))
                    }
                }
            } catch (_: Exception) { /* 未认证、断线和慢客户端只关闭自己的连接。 */ }
            finally { clients.remove(channel); channel.close() }
        }
        private fun capture(wire: MicrophoneWire, channel: SocketChannel) {
            val input = checkNotNull(builtin()) { "内置麦克风不可用" }
            val min = AudioRecord.getMinBufferSize(48000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(min > 0) { "设备不支持 48 kHz 单声道采集" }
            check(context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED) { "麦克风权限已撤销，请重新开启共享" }
            val wake = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "shenglin:microphone")
            val wireless = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "shenglin:microphone")
            val recorder = AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.MIC)
                .setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_IN_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(maxOf(min, 960 * 2 * 4)).build()
            try {
                check(!closed && channel.isOpen) { "共享已停止" }
                check(recorder.state == AudioRecord.STATE_INITIALIZED && recorder.setPreferredDevice(input)) { "无法选择内置麦克风" }
                ownSession = recorder.audioSessionId
                recorder.startRecording()
                check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "系统未允许录音，麦克风可能被其他应用占用" }
                wake.acquire(); wireless.acquire()
                report("正在共享内置麦克风")
                wire.respond(JSONObject().put("sampleRate", 48000).put("channels", 1).put("encoding", "f32le").put("packetFrames", 960))
                val samples = ShortArray(960)
                val packet = ByteBuffer.allocate(1 + 960 * 4).order(ByteOrder.LITTLE_ENDIAN)
                while (!closed && channel.isOpen) {
                    var offset = 0
                    val deadline = SystemClock.elapsedRealtime() + 2000
                    while (offset < samples.size) {
                        check(!closed && channel.isOpen) { "共享已停止" }
                        val count = recorder.read(samples, offset, samples.size - offset, AudioRecord.READ_NON_BLOCKING)
                        check(count >= 0) { "录音读取失败：$count" }
                        if (count == 0) { check(SystemClock.elapsedRealtime() < deadline) { "麦克风没有返回音频" }; Thread.sleep(5) }
                        offset += count
                    }
                    check(recorder.routedDevice?.id == input.id) { "输入路由已变化，采集已中止" }
                    if (Build.VERSION.SDK_INT >= 29) check(recorder.activeRecordingConfiguration?.isClientSilenced != true) { "系统已将麦克风静音，请检查其他录音应用或隐私设置" }
                    packet.clear(); packet.put(2); samples.forEach { packet.putFloat(it / 32768f) }
                    wire.send(packet.array())
                }
            } finally {
                releaseCaptureResources(
                    { if (recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) recorder.stop() },
                    { recorder.release() },
                    { ownSession = null },
                    { if (wireless.isHeld) wireless.release() },
                    { if (wake.isHeld) wake.release() },
                    { if (status == "正在共享内置麦克风") report("等待接收设备使用"); main.post(changed) },
                )
            }
        }

        override fun close() {
            closed = true; server.close(); clients.forEach { it.close() }
            if (registered) { registered = false; try { nsd.unregisterService(registration) } catch (_: IllegalArgumentException) { } }
        }
    }
    override fun close() { endpoints.values.forEach { it.close() }; endpoints.clear(); workers.shutdownNow() }
}

/** 一项系统资源释放失败不能阻止其余资源归还；保留异常供调用方报告。 */
internal fun releaseCaptureResources(vararg releases: () -> Unit) {
    var failure: Exception? = null
    releases.forEach { release ->
        try { release() } catch (error: Exception) {
            if (failure == null) failure = error else failure!!.addSuppressed(error)
        }
    }
    failure?.let { throw it }
}
