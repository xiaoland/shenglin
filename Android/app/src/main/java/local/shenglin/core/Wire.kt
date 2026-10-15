package local.shenglin.core

import org.json.JSONObject
import org.json.JSONException
import uniffi.shenglin_core.*

/** JSON envelopes belong to Android transports; signed payload codecs belong to Rust. */
object Wire {
    @JvmStatic fun pairing(value: JSONObject) = decode { Pairing.Frame.from(decodePairing(value.toString())) }
    @JvmStatic fun json(value: Pairing.Frame) = JSONObject(encodePairing(value.rust()))
    @JvmStatic fun update(value: JSONObject) = decode { PeerState.Update.from(decodeUpdate(value.toString())) }
    @JvmStatic fun json(value: PeerState.Update) = JSONObject(encodeUpdate(value.rust()))
    @JvmStatic fun ack(value: JSONObject) = decode { PeerState.Ack.from(decodeAck(value.toString())) }
    @JvmStatic fun json(value: PeerState.Ack) = JSONObject(encodeAck(value.rust()))
    @JvmStatic fun name(value: JSONObject) = decode { PeerState.NameClaim.from(decodeName(value.toString())) }
    @JvmStatic fun json(value: PeerState.NameClaim) = JSONObject(encodeName(value.rust()))
    // Preserve the Android decoder contract so invalid remote frames are rejected at
    // existing transport boundaries; unrelated native failures must still surface.
    private inline fun <T> decode(block: () -> T): T = try {
        block()
    } catch (error: CoreException.InvalidMessage) {
        throw JSONException("Invalid peer message").also { it.initCause(error) }
    }
}
