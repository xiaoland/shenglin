package local.shenglin.core

import org.json.JSONException
import org.json.JSONObject
import org.junit.Assert.assertThrows
import org.junit.Test

class WireTest {
    @Test fun malformedRemotePayloadsRespectTransportRejectionBoundary() {
        val decoders: List<(JSONObject) -> Any> = listOf(Wire::pairing, Wire::update, Wire::ack, Wire::name)
        for (decoder in decoders) {
            for (payload in listOf("{}", "{\"revision\":[],\"origin\":false,\"version\":{}}")) {
                assertThrows(JSONException::class.java) { decoder(JSONObject(payload)) }
            }
        }
    }

    @Test fun oversizedSignedTargetsCannotBecomeValidThroughIntegerTruncation() {
        val key = ByteArray(32)
        val update = PeerState.Update.signed("initiator", 1, true, true, 120, 100, key)
        val ack = PeerState.Ack.signed("responder", 1, true, "applied", 100, key)
        for (target in listOf(-1L, 501L, 4294967396L, Long.MAX_VALUE)) {
            assertThrows(JSONException::class.java) { Wire.update(Wire.json(update).put("targetMilli", target)) }
            assertThrows(JSONException::class.java) { Wire.ack(Wire.json(ack).put("targetMilli", target)) }
        }
    }
}
