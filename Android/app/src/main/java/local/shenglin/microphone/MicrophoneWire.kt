package local.shenglin.microphone

import local.shenglin.core.Crypto
import org.json.JSONObject
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.SocketChannel
import java.util.concurrent.TimeUnit
import uniffi.shenglin_core.audioOpen
import uniffi.shenglin_core.audioSeal
import uniffi.shenglin_core.audioSessionKey

/** 与桌面端共用 v1 协议；所有网络操作有总时限，慢客户端不能积压录音。 */
internal class MicrophoneWire(private val channel: SocketChannel) : Closeable {
    private val selector = Selector.open()
    private var tx = byteArrayOf()
    private var rx = byteArrayOf()
    private var sent = 0uL
    private var received = 0uL
    init { channel.configureBlocking(false); channel.socket().tcpNoDelay = true; channel.register(selector, 0) }

    fun authenticate(key: ByteArray, role: String) {
        val server = Crypto.random(32)
        writeLine(JSONObject().put("version", 1).put("nonce", Crypto.base64(server)))
        val hello = readLine()
        val client = Crypto.decode(hello.getString("nonce"))
        require(client.size == 32) { "麦克风挑战无效" }
        tx = audioSessionKey(key, server, client, role)
        rx = audioSessionKey(key, server, client, if (role == "initiator") "responder" else "initiator")
        require(Crypto.matches(hello.getString("proof"), Crypto.sign("microphone-open|1", rx))) { "麦克风认证失败" }
        writeLine(JSONObject().put("proof", Crypto.sign("microphone-ready|1", tx)))
    }
    fun request(): JSONObject {
        val deadline = deadline(3000)
        val size = ByteBuffer.wrap(read(4, deadline)).int
        require(size in 17..16400) { "音频帧长度无效" }
        val body = audioOpen(rx, received, read(size, deadline)); received++
        require(body.firstOrNull() == 1.toByte()) { "麦克风请求无效" }
        return JSONObject(String(body, 1, body.size - 1, Charsets.UTF_8))
    }
    fun respond(value: JSONObject) = send(byteArrayOf(1) + value.toString().toByteArray(Charsets.UTF_8))
    fun send(body: ByteArray) {
        val encrypted = audioSeal(tx, sent, body); sent++
        val frame = ByteBuffer.allocate(4 + encrypted.size).putInt(encrypted.size).put(encrypted)
        frame.flip(); transfer(frame, true, deadline(300))
    }
    private fun writeLine(value: JSONObject) = transfer(ByteBuffer.wrap((value.toString() + "\n").toByteArray(Charsets.UTF_8)), true, deadline(3000))
    private fun readLine(): JSONObject {
        val bytes = ByteArray(1024)
        val deadline = deadline(3000)
        for (index in 0..bytes.size) {
            val byte = read(1, deadline)[0]
            if (byte == 10.toByte()) return JSONObject(String(bytes, 0, index, Charsets.UTF_8))
            require(index < bytes.size) { "麦克风认证消息过长" }
            bytes[index] = byte
        }
        throw IOException("麦克风认证消息无效")
    }
    private fun read(size: Int, deadline: Long) = ByteBuffer.allocate(size).also { transfer(it, false, deadline) }.array()
    private fun transfer(buffer: ByteBuffer, writing: Boolean, deadline: Long) {
        channel.keyFor(selector).interestOps(if (writing) SelectionKey.OP_WRITE else SelectionKey.OP_READ)
        while (buffer.hasRemaining()) {
            val remaining = deadline - System.nanoTime()
            if (remaining <= 0) throw IOException("麦克风网络超时")
            val count = if (writing) channel.write(buffer) else channel.read(buffer)
            if (count < 0) throw EOFException("麦克风连接已关闭")
            if (count == 0) { selector.select(maxOf(1, TimeUnit.NANOSECONDS.toMillis(remaining))); selector.selectedKeys().clear() }
        }
    }
    private fun deadline(ms: Long) = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(ms)
    override fun close() { channel.close(); selector.close() }
}
