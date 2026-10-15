package local.shenglin.core

import uniffi.shenglin_core.*

/** Sessions release the Rust PAKE state on cancellation, completion and timeout. */
object Pairing {
    @JvmStatic fun generateCode() = pairingCode()
    class Frame(@JvmField val version: Int, @JvmField val kind: String, @JvmField val session: ByteArray,
                @JvmField val message: ByteArray?, @JvmField val name: String?, @JvmField val proof: ByteArray?,
                @JvmField val pairingMode: Boolean?, @JvmField val platform: String?) {
        constructor(kind: String, session: ByteArray, message: ByteArray?, name: String?, proof: ByteArray?) : this(4, kind, session, message, name, proof, null, "android")
        internal fun rust() = RustPairingFrame(version, kind, session, message, name, proof, pairingMode, platform)
        companion object { internal fun from(value: RustPairingFrame) = Frame(value.version, value.kind, value.session, value.message, value.name, value.proof, value.pairingMode, value.platform) }
    }
    class Initiator @JvmOverloads constructor(code: String, name: String, nowSeconds: Long, version: Int = 4) : AutoCloseable {
        private val core = RustPairingInitiator(code, name, if (version == 4) "android" else null, nowSeconds.toDouble())
        @JvmField var peerName: String? = null
        @JvmField var peerPlatform: String? = null
        fun startFrame() = Frame.from(core.startFrame())
        fun receiveOffer(frame: Frame, nowSeconds: Long): Frame {
            val result = core.receiveOffer(frame.rust(), nowSeconds.toDouble())
            peerName = core.peerName(); peerPlatform = core.peerPlatform()
            return Frame.from(result)
        }
        fun receiveFinish(frame: Frame, nowSeconds: Long) = core.receiveFinish(frame.rust(), nowSeconds.toDouble())
        override fun close() = core.close()
    }
    class Responder @JvmOverloads constructor(start: Frame, code: String, name: String, nowSeconds: Long, version: Int = 4) : AutoCloseable {
        private val core = RustPairingResponder(start.rust(), code, name, "Android", if (version == 4) "android" else null, nowSeconds.toDouble())
        @JvmField val peerName = start.name
        @JvmField val peerPlatform = core.peerPlatform()
        fun offerFrame() = Frame.from(core.offerFrame())
        fun receiveConfirm(frame: Frame, nowSeconds: Long) = Frame.from(core.receiveConfirm(frame.rust(), nowSeconds.toDouble()))
        fun confirmedKey() = core.confirmedKey()
        override fun close() = core.close()
    }
}
