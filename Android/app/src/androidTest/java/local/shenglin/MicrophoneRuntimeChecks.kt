package local.shenglin

import android.app.Instrumentation
import android.content.*
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Bundle
import android.os.IBinder
import android.os.SystemClock
import local.shenglin.core.Crypto
import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import uniffi.shenglin_core.audioOpen
import uniffi.shenglin_core.audioSeal
import uniffi.shenglin_core.audioSessionKey

/** 临时配对只用于本机认证客户端；保留原有关系，不保存音频或输出密钥。 */
object MicrophoneRuntimeChecks {
    @JvmStatic fun run(test: Instrumentation, result: Bundle) {
        val context = test.targetContext
        val preferences = context.getSharedPreferences("preferences", Context.MODE_PRIVATE)
        val wasEnabled = preferences.getBoolean("enabled", false)
        preferences.edit().putBoolean("enabled", false).commit()
        val key = Crypto.random(32)
        val id = Crypto.sha256(key).take(8).joinToString("") { "%02x".format(it) }
        val store = SecureStore(context)
        val saved = store.read()
        val root = saved?.let { JSONObject(String(it, Charsets.UTF_8)) } ?: JSONObject()
        val peers = root.optJSONArray("peers") ?: JSONArray().also { root.put("peers", it) }
        peers.put(JSONObject().put("id", id).put("key", Crypto.base64(key)).put("role", "responder")
            .put("name", "麦克风验收客户端").put("platform", "mac").put("pending", false).put("microphoneShared", true))
        store.write(root.toString().toByteArray(Charsets.UTF_8))
        var service: PeerService? = null
        val bound = CountDownLatch(1)
        val binding = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) { service = (binder as PeerService.LocalBinder).service(); bound.countDown() }
            override fun onServiceDisconnected(name: ComponentName) = Unit
        }
        var client: Client? = null
        try {
            val activity = test.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            context.bindService(Intent(context, PeerService::class.java), binding, Context.BIND_AUTO_CREATE)
            check(bound.await(5, TimeUnit.SECONDS)) { "服务绑定超时" }
            fun state() = service!!.state.value
            test.runOnMainSync { context.startForegroundService(Intent(context, PeerService::class.java).setAction("START_MICROPHONE")) }
            await { state().microphoneEnabled }
            val nsd = context.getSystemService(NsdManager::class.java)
            val endpoint = resolve(nsd, "${Crypto.serviceName(key)}-responder")
            Client(endpoint, key).use { list ->
                list.request(JSONObject().put("operation", "list"))
                val sources = list.json().getJSONArray("sources")
                check(sources.length() == 1 && sources.getJSONObject(0).getString("id") == "android.builtin")
            }
            check(!state().microphoneCapturing) { "列出输入不能开始采集" }
            test.runOnMainSync { activity.moveTaskToBack(true) }
            SystemClock.sleep(1500)
            client = Client(endpoint, key).also { it.stream(); it.packets(50) }
            await { state().microphoneCapturing && state().recording == false }
            Client(endpoint, key).use { busy ->
                busy.request(JSONObject().put("operation", "stream").put("sourceID", "android.builtin"))
                check(busy.json().getString("error").contains("另一接收设备"))
            }
            client.packets(10)
            client.close(); client = null
            await { !state().microphoneCapturing }
            client = Client(endpoint, key).also { it.stream(); it.packets(20) }
            test.runOnMainSync { context.startForegroundService(Intent(context, PeerService::class.java)) }
            await { state().enabled }
            test.runOnMainSync { service!!.pause() }
            check(state().microphoneEnabled && !state().enabled)
            client.packets(20)
            test.runOnMainSync { service!!.setMicrophoneShared(id, false) }
            await { !state().microphoneCapturing }
            client.close(); client = null
            test.runOnMainSync { service!!.setMicrophoneShared(id, true) }
            val restored = resolve(nsd, "${Crypto.serviceName(key)}-responder")
            client = Client(restored, key).also { it.stream(); it.packets(20) }
            test.runOnMainSync { service!!.stopMicrophone() }
            await { !state().microphoneCapturing && !state().microphoneEnabled }
            result.putString("stream", "麦克风前台服务、列表不采集、后台首次/再次采集、并发占用拒绝、Float32帧、自身录音排除、暂停协同不断流、撤销/重授与停止释放通过。音频能量未作为此平台测试的断言。\n")
        } finally {
            client?.close()
            test.runOnMainSync { service?.stopMicrophone(); service?.forget(id); service?.pause() }
            context.unbindService(binding)
            preferences.edit().putBoolean("enabled", wasEnabled).commit()
            if (service == null) {
                val clean = JSONArray()
                for (index in 0 until peers.length()) if (peers.getJSONObject(index).optString("id") != id) clean.put(peers.getJSONObject(index))
                root.put("peers", clean); store.write(root.toString().toByteArray(Charsets.UTF_8))
            }
        }
    }
    private fun await(condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 7000
        while (!condition()) { check(SystemClock.elapsedRealtime() < deadline) { "状态变化超时" }; SystemClock.sleep(50) }
    }
    private fun resolve(nsd: NsdManager, name: String): InetSocketAddress {
        val found = CountDownLatch(1)
        val endpoint = AtomicReference<InetSocketAddress>()
        var resolving = false
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) = Unit
            override fun onDiscoveryStopped(type: String) = Unit
            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onStartDiscoveryFailed(type: String, code: Int) { found.countDown() }
            override fun onStopDiscoveryFailed(type: String, code: Int) = Unit
            override fun onServiceFound(info: NsdServiceInfo) {
                if (info.serviceName != name || resolving) return
                resolving = true
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) { found.countDown() }
                    override fun onServiceResolved(info: NsdServiceInfo) { endpoint.set(InetSocketAddress(info.host, info.port)); found.countDown() }
                })
            }
        }
        nsd.discoverServices("_shenglin-mic._tcp.", NsdManager.PROTOCOL_DNS_SD, listener)
        try { check(found.await(15, TimeUnit.SECONDS)) { "发现麦克风服务超时" }; return checkNotNull(endpoint.get()) { "麦克风服务解析失败" } }
        finally { nsd.stopServiceDiscovery(listener) }
    }
    private class Client(endpoint: InetSocketAddress, key: ByteArray) : AutoCloseable {
        private val socket = Socket().apply { soTimeout = 5000; connect(endpoint, 3000) }
        private val input = DataInputStream(socket.getInputStream())
        private val output = DataOutputStream(socket.getOutputStream())
        private val tx: ByteArray
        private val rx: ByteArray
        private var received = 0uL
        init {
            fun line(): JSONObject {
                val bytes = mutableListOf<Byte>()
                while (true) { val byte = input.readByte(); if (byte == 10.toByte()) break; check(bytes.size < 1024); bytes.add(byte) }
                return JSONObject(String(bytes.toByteArray(), Charsets.UTF_8))
            }
            val hello = line()
            check(hello.getInt("version") == 1)
            val server = Crypto.decode(hello.getString("nonce")); val client = Crypto.random(32)
            tx = audioSessionKey(key, server, client, "initiator"); rx = audioSessionKey(key, server, client, "responder")
            output.write((JSONObject().put("nonce", Crypto.base64(client)).put("proof", Crypto.sign("microphone-open|1", tx)).toString() + "\n").toByteArray())
            check(Crypto.matches(line().getString("proof"), Crypto.sign("microphone-ready|1", rx)))
        }
        fun request(value: JSONObject) {
            val encrypted = audioSeal(tx, 0u, byteArrayOf(1) + value.toString().toByteArray(Charsets.UTF_8))
            output.writeInt(encrypted.size); output.write(encrypted)
        }
        private fun next(): ByteArray {
            val size = input.readInt(); check(size in 17..16400)
            val bytes = ByteArray(size); input.readFully(bytes)
            return audioOpen(rx, received++, bytes)
        }
        fun json(): JSONObject { val frame = next(); check(frame[0] == 1.toByte()); return JSONObject(String(frame, 1, frame.size - 1, Charsets.UTF_8)) }
        fun stream() {
            request(JSONObject().put("operation", "stream").put("sourceID", "android.builtin"))
            val format = json()
            check(format.optInt("sampleRate") == 48000 && format.optInt("channels") == 1 && format.optInt("packetFrames") == 960 && format.optString("encoding") == "f32le") { format.toString() }
        }
        fun packets(count: Int) { repeat(count) {
            val packet = next(); check(packet.size == 3841 && packet[0] == 2.toByte()) { "音频帧无效：类型=${packet.firstOrNull()}，长度=${packet.size}" }
            val samples = ByteBuffer.wrap(packet, 1, packet.size - 1).order(ByteOrder.LITTLE_ENDIAN)
            repeat(960) { check(samples.float.isFinite()) }
        } }
        override fun close() = socket.close()
    }
}
