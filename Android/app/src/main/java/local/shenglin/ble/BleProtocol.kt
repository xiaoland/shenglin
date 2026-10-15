package local.shenglin.ble

import local.shenglin.core.PeerState
import java.io.ByteArrayOutputStream

/** Android GATT framing helpers; peer roles and authenticated proof are owned by Rust. */
object BleProtocol {
    const val MAX_VALUE = 512

    @JvmStatic fun central(platform: String, localRole: String): Boolean =
        PeerState.androidBleCentral(platform, localRole)

    @JvmStatic fun slice(value: ByteArray?, offset: Int, mtu: Int): ByteArray {
        require(value != null && value.size <= MAX_VALUE && offset >= 0 && offset <= value.size && mtu >= 23) {
            "无效读取偏移"
        }
        return value.copyOfRange(offset, minOf(value.size, offset + mtu - 1))
    }

    class PreparedWrite {
        private var characteristic: String? = null
        private val bytes = ByteArrayOutputStream()

        fun append(id: String, offset: Int, value: ByteArray?) {
            if (value == null || offset != bytes.size() || offset + value.size > MAX_VALUE ||
                (characteristic != null && characteristic != id)
            ) {
                clear()
                throw IllegalArgumentException("无效长写入")
            }
            characteristic = id
            bytes.write(value)
        }

        fun characteristic(): String? = characteristic
        fun value(): ByteArray = bytes.toByteArray()
        fun clear() {
            characteristic = null
            bytes.reset()
        }
    }

    class Proof {
        private val core = PeerState.BleProof()

        fun sent(update: PeerState.Update) = core.sent(update)
        fun accept(
            ack: PeerState.Ack, key: ByteArray, remoteOrigin: String,
            wallSeconds: Long, elapsedMillis: Long,
        ): Boolean = core.accept(ack, key, remoteOrigin, wallSeconds, elapsedMillis)

        fun verified(elapsedMillis: Long): Boolean = core.verified(elapsedMillis)
        fun clear() = core.clear()
    }
}
