package local.shenglin.microphone

import local.shenglin.core.Crypto
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import uniffi.shenglin_core.audioOpen
import uniffi.shenglin_core.audioSeal
import uniffi.shenglin_core.audioSessionKey

class MicrophoneWireTest {
    private val key = ByteArray(32) { it.toByte() }
    private fun exchange(server: (MicrophoneWire) -> Unit, client: (DataInputStream, DataOutputStream) -> Unit): Throwable? {
        val executor = Executors.newSingleThreadExecutor()
        try {
            ServerSocketChannel.open().use { listener ->
                listener.bind(InetSocketAddress(InetAddress.getLoopbackAddress(), 0))
                SocketChannel.open(listener.localAddress).use { socket ->
                    socket.socket().soTimeout = 5000
                    listener.accept().use { accepted ->
                        accepted.socket().sendBufferSize = 1024
                        val result = executor.submit<Throwable?> {
                            try { MicrophoneWire(accepted).use(server); null } catch (error: Exception) { error }
                        }
                        client(DataInputStream(socket.socket().getInputStream()), DataOutputStream(socket.socket().getOutputStream()))
                        return result.get(5, TimeUnit.SECONDS)
                    }
                }
            }
        } finally { executor.shutdownNow() }
    }
    private fun line(input: DataInputStream): JSONObject {
        val bytes = mutableListOf<Byte>()
        while (true) { val byte = input.readByte(); if (byte == 10.toByte()) break; bytes.add(byte) }
        return JSONObject(String(bytes.toByteArray(), Charsets.UTF_8))
    }
    private fun authenticate(input: DataInputStream, output: DataOutputStream, valid: Boolean = true): Pair<ByteArray, ByteArray> {
        val hello = line(input)
        assertEquals(1, hello.getInt("version"))
        val server = Crypto.decode(hello.getString("nonce"))
        val client = Crypto.random(32)
        val tx = audioSessionKey(key, server, client, "initiator")
        val rx = audioSessionKey(key, server, client, "responder")
        val proof = if (valid) Crypto.sign("microphone-open|1", tx) else Crypto.sign("microphone-open|1", ByteArray(32))
        output.writeBytes(JSONObject().put("nonce", Crypto.base64(client)).put("proof", proof).toString() + "\n")
        if (valid) assertTrue(Crypto.matches(line(input).getString("proof"), Crypto.sign("microphone-ready|1", rx)))
        return tx to rx
    }
    @Test fun desktopCompatibleRequestAndResponse() {
        assertNull(exchange({ wire ->
            wire.authenticate(key, "responder")
            assertEquals("list", wire.request().getString("operation"))
            wire.respond(JSONObject().put("sources", org.json.JSONArray()))
        }, { input, output ->
            val (tx, rx) = authenticate(input, output)
            val body = audioSeal(tx, 0u, byteArrayOf(1) + "{\"operation\":\"list\"}".toByteArray())
            output.writeInt(body.size); output.write(body)
            val encrypted = ByteArray(input.readInt()); input.readFully(encrypted)
            val response = audioOpen(rx, 0u, encrypted)
            assertEquals(1.toByte(), response[0])
            assertEquals(0, JSONObject(String(response.drop(1).toByteArray())).getJSONArray("sources").length())
        }))
    }
    @Test fun unauthenticatedPeerCannotSendRequests() {
        assertNotNull(exchange({ it.authenticate(key, "responder"); fail("必须拒绝错误密钥") }, { input, output ->
            authenticate(input, output, false)
            assertEquals(-1, input.read())
        }))
    }
    @Test fun rejectsOversizedRecordBeforeAllocatingBody() {
        assertNotNull(exchange({ it.authenticate(key, "responder"); it.request(); fail("必须拒绝超长记录") }, { input, output ->
            authenticate(input, output); output.writeInt(Int.MAX_VALUE)
            assertEquals(-1, input.read())
        }))
    }
    @Test fun modifiedCiphertextIsRejected() {
        assertNotNull(exchange({ it.authenticate(key, "responder"); it.request(); fail("必须拒绝篡改记录") }, { input, output ->
            val (tx, _) = authenticate(input, output)
            val body = audioSeal(tx, 0u, byteArrayOf(1) + "{}".toByteArray())
            body[body.lastIndex] = (body.last().toInt() xor 1).toByte()
            output.writeInt(body.size); output.write(body); assertEquals(-1, input.read())
        }))
    }
    @Test fun stalledReceiverCannotBlockAudioWorker() {
        val started = System.nanoTime()
        val failure = exchange({ wire ->
            wire.authenticate(key, "responder")
            repeat(10000) { wire.send(ByteArray(3841) { 2 }) }
            fail("慢接收端必须超时")
        }, { input, output -> authenticate(input, output) })
        assertNotNull(failure)
        assertTrue("超时必须有界", TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 4000)
    }
}
