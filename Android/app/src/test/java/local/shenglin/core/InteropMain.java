package local.shenglin.core;

import java.io.*;
import org.json.*;

/** Host-only driver: each stdout line is a frame or a final authenticated result. */
public final class InteropMain {
    public static void main(String[] args) throws Exception {
        BufferedReader input = new BufferedReader(new InputStreamReader(System.in, java.nio.charset.StandardCharsets.UTF_8));
        String peerName = System.getenv().getOrDefault("SHENGLIN_TEST_PEER_NAME", "互操作设备");
        int version = args.length > 2 ? Integer.parseInt(args[2]) : 4;
        long now = System.currentTimeMillis() / 1000;
        if (args[0].equals("initiator")) {
            try (Pairing.Initiator pairing = new Pairing.Initiator("004219", peerName, now, version)) {
                emit(Wire.json(pairing.startFrame()));
                emit(Wire.json(pairing.receiveOffer(Wire.pairing(new JSONObject(input.readLine())), now)));
                byte[] key = pairing.receiveFinish(Wire.pairing(new JSONObject(input.readLine())), now);
                result(key, pairing.peerPlatform);
            }
        } else {
            try (Pairing.Responder pairing = new Pairing.Responder(Wire.pairing(new JSONObject(input.readLine())), "004219", peerName, now, version)) {
                emit(Wire.json(pairing.offerFrame()));
                emit(Wire.json(pairing.receiveConfirm(Wire.pairing(new JSONObject(input.readLine())), now)));
                result(pairing.confirmedKey(), pairing.peerPlatform);
            }
        }
    }
    private static void result(byte[] key, String peerPlatform) throws JSONException {
        emit(new JSONObject().put("result", "ok").put("proof", Crypto.sign("interop", key))
                .put("peerPlatform", peerPlatform)
                .put("stateSignature", PeerState.Update.signed("initiator", 42, true, true, 2000000000L, 200, key).signature)
                .put("ackSignature", PeerState.Ack.signed("responder", 42, true, "protectedLocal", 200, key).signature)
                .put("serviceName", Crypto.serviceName(key))
                .put("wifiProof", Crypto.wifiProof("initiator", Crypto.base64(new byte[16]), key))
                .put("networkMediumWifiProof", Crypto.networkMediumProof("initiator", Crypto.base64(new byte[16]), "wifi", key))
                .put("networkMediumEthernetProof", Crypto.networkMediumProof("initiator", Crypto.base64(new byte[16]), "ethernet", key)));
    }
    private static void emit(JSONObject o) { System.out.println(o.toString()); System.out.flush(); }
}
