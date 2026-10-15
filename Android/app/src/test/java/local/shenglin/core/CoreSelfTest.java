package local.shenglin.core;

import java.util.*;
import java.util.concurrent.*;

/** Run with java -ea; no Android runtime or test framework required. */
public final class CoreSelfTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    private static void fails(Runnable action) { try { action.run(); } catch (Exception expected) { return; } throw new AssertionError("Expected rejection"); }
    public static void main(String[] args) throws Exception {
        byte[] key = new byte[32]; Arrays.fill(key, (byte) 7);
        check(Crypto.sign("The quick brown fox jumps over the lazy dog", Crypto.utf8("key")).equals("97yD9DBThCSxMpjmqm+xQ+9NWaFJRhdZl0edvC0aPNg="));
        PeerState.Ledger ledger = new PeerState.Ledger();
        PeerState.Update first = PeerState.Update.signed("initiator", 1, true, true, 125, 100, key);
        check(ledger.accept(first,"peer","initiator",key,100).started);
        check(!ledger.accept(first,"peer","initiator",key,105).accepted);
        check(ledger.accept(PeerState.Update.signed("initiator",2,false,false,130,100,key),"peer","initiator",key,110).accepted);
        check(ledger.activeCount(119) == 1); check(ledger.expire(120).ended);
        check(!ledger.accept(first,"peer","initiator",key,100).accepted);
        check(!PeerState.Update.signed("initiator",3,true,true,126,100,key).valid(key,"initiator",100));
        check(!PeerState.Update.signed("initiator",3,true,true,120,501,key).valid(key,"initiator",100));
        check(!PeerState.Update.signed("initiator",3,true,true,120,100,key).valid(key,"responder",100));
        check(ledger.accept(PeerState.Update.signed("initiator",Long.MIN_VALUE,true,true,150,100,key),"peer","initiator",key,130).accepted);
        ledger.takeOver(131); check(ledger.stopResponding("peer",132).manualAtEnd);
        PeerState.Ledger restored = new PeerState.Ledger(); restored.restoreRevisions(ledger.revisions());
        check(restored.activeCount(130) == 0);
        check(!restored.accept(PeerState.Update.signed("initiator",Long.MIN_VALUE,true,true,150,100,key),"peer","initiator",key,130).accepted);
        PeerState.Ledger active = new PeerState.Ledger();
        active.accept(PeerState.Update.signed("initiator", 1, true, true, 220, 100, key), "first", "initiator", key, 200);
        active.accept(PeerState.Update.signed("responder", 1, true, true, 225, 100, key), "second", "responder", key, 205);
        active.takeOver(206);
        PeerState.Ledger restarted = new PeerState.Ledger();
        restarted.restoreRecords(active.records(), active.manualTakeover(), 210);
        check(restarted.manualTakeover() && restarted.activeCount(210) == 2);
        check(!restarted.expire(220).ended && restarted.manualTakeover());
        check(restarted.expire(225).manualAtEnd && !restarted.manualTakeover());
        restarted.restoreRecords(active.records(), true, 225);
        check(restarted.activeCount(225) == 0 && !restarted.manualTakeover());
        PeerState.SpaceGate gate = new PeerState.SpaceGate();
        check(!gate.allows(true,true,false,100)); check(gate.allows(true,true,true,100));
        check(gate.allows(true,false,false,119)); check(!gate.allows(true,false,false,120));
        for (boolean both : new boolean[] {false, true}) {
            for (boolean ble : new boolean[] {false, true}) for (boolean wifi : new boolean[] {false, true}) {
                gate.reset();
                check(gate.allows(both, ble, wifi, 200) == (both ? ble && wifi : ble || wifi));
            }
        }
        gate.reset(); check(gate.allows(false, true, false, 300));
        gate.reset(); check(!gate.allows(true, true, false, 301));
        gate.reset(); check(gate.allows(false, false, true, 302));
        PeerState.NameClaim claim = PeerState.NameClaim.signed("  我的设备\n",key); check(claim.valid(key));
        check(!new PeerState.NameClaim("假的",claim.signature).valid(key));
        for (int version : new int[] {3, 4}) {
            try (Pairing.Initiator a = new Pairing.Initiator("123456","Android A",100,version);
                 Pairing.Responder b = new Pairing.Responder(a.startFrame(),"123456","Android B",100,version)) {
                Pairing.Frame confirm = a.receiveOffer(b.offerFrame(),101);
                byte[] agreed = a.receiveFinish(b.receiveConfirm(confirm,102),103);
                check(Arrays.equals(agreed,b.confirmedKey())); fails(() -> a.receiveFinish(b.offerFrame(),104));
            }
        }
        try (Pairing.Initiator a = new Pairing.Initiator("123456","A",100);
             Pairing.Responder b = new Pairing.Responder(a.startFrame(),"654321","B",100)) {
            Pairing.Frame confirm = a.receiveOffer(b.offerFrame(),101); fails(() -> b.receiveConfirm(confirm,102));
        }
        try (Pairing.Initiator a = new Pairing.Initiator("123456","A",100);
             Pairing.Responder b = new Pairing.Responder(a.startFrame(),"123456","B",100)) {
            Pairing.Frame f = b.offerFrame();
            Pairing.Frame altered = new Pairing.Frame(4,f.kind,f.session,f.message,f.name,f.proof,f.pairingMode,"mac");
            Pairing.Frame confirm = a.receiveOffer(altered,101); fails(() -> b.receiveConfirm(confirm,102));
        }
        try (Pairing.Initiator a = new Pairing.Initiator("123456","A",100);
             Pairing.Responder b = new Pairing.Responder(a.startFrame(),"123456","B",100)) { fails(() -> a.receiveOffer(b.offerFrame(),190)); }
        PeerState.Update serialized = PeerState.Update.signed("initiator", 42, true, true, 120, 100, key);
        check(Wire.update(Wire.json(serialized)).valid(key, "initiator", 100));
        org.json.JSONObject malformed = Wire.json(serialized).put("known", "true");
        try { Wire.update(malformed); throw new AssertionError("String boolean accepted"); } catch (Exception expected) {}
        malformed = Wire.json(serialized).put("revision", -1);
        try { Wire.update(malformed); throw new AssertionError("Negative revision accepted"); } catch (Exception expected) {}
        malformed = Wire.json(serialized).put("validUntil", 120.5);
        try { Wire.update(malformed); throw new AssertionError("Fractional timestamp accepted"); } catch (Exception expected) {}
        networkMediumProofs(key);
        concurrentCancellation();
        System.out.println("CoreSelfTest passed");
    }
    private static void networkMediumProofs(byte[] key) {
        String nonce = Crypto.base64(new byte[16]);
        byte[] nextChallenge = new byte[16]; nextChallenge[0] = 1;
        String identity = Crypto.wifiProof("initiator", nonce, key);
        for (String medium : new String[] {"wifi", "ethernet"}) {
            String proof = Crypto.networkMediumProof("initiator", nonce, medium, key);
            check(Crypto.validNetworkMediumProof(proof, "initiator", nonce, medium, key));
            check(!Crypto.validNetworkMediumProof(proof, "responder", nonce, medium, key));
            check(!Crypto.validNetworkMediumProof(proof, "initiator", Crypto.base64(nextChallenge), medium, key));
            check(!Crypto.validNetworkMediumProof(proof, "initiator", nonce, medium.equals("wifi") ? "ethernet" : "wifi", key));
            check(!Crypto.validNetworkMediumProof(proof, "initiator", nonce, null, key));
            check(!Crypto.validNetworkMediumProof(proof, "initiator", nonce, "cellular", key));
            check(!Crypto.validNetworkMediumProof(proof, "initiator", "invalid", medium, key));
            check(!Crypto.validNetworkMediumProof(null, "initiator", nonce, medium, key));
            check(!Crypto.validNetworkMediumProof(identity, "initiator", nonce, medium, key));
            check(!Crypto.validWifiProof(proof, "initiator", nonce, key));
        }
        fails(() -> Crypto.networkMediumProof("initiator", nonce, "cellular", key));
        fails(() -> Crypto.networkMediumProof("initiator", nonce, null, key));
        // Optional medium claims never replace or weaken the existing identity proof.
        check(Crypto.validWifiProof(identity, "initiator", nonce, key));
        check(!Crypto.validNetworkMediumProof(null, "initiator", nonce, null, key));
    }
    private static void concurrentCancellation() throws Exception {
        ExecutorService workers = Executors.newFixedThreadPool(2);
        try {
            for (int i = 0; i < 100; i++) {
                try (Pairing.Initiator a = new Pairing.Initiator("123456", "A", 100);
                     Pairing.Responder b = new Pairing.Responder(a.startFrame(), "123456", "B", 100)) {
                    Pairing.Frame offer = b.offerFrame();
                    race(workers, () -> a.receiveOffer(offer, 101), a::close);
                    fails(() -> a.receiveOffer(offer, 101));
                    fails(a::startFrame);
                }
                try (Pairing.Initiator a = new Pairing.Initiator("123456", "A", 100);
                     Pairing.Responder b = new Pairing.Responder(a.startFrame(), "123456", "B", 100)) {
                    Pairing.Frame confirm = a.receiveOffer(b.offerFrame(), 101);
                    race(workers, () -> b.receiveConfirm(confirm, 102), b::close);
                    fails(b::confirmedKey);
                    fails(() -> b.receiveConfirm(confirm, 102));
                    fails(b::offerFrame);
                }
            }
        } finally { workers.shutdownNow(); }
    }
    private static void race(ExecutorService workers, Runnable receive, Runnable cancel) throws Exception {
        CountDownLatch start = new CountDownLatch(1);
        Future<?> operation = workers.submit(() -> {
            await(start);
            try { receive.run(); } catch (Exception cancelled) { }
        });
        Future<?> cancellation = workers.submit(() -> { await(start); cancel.run(); });
        start.countDown();
        operation.get(10, TimeUnit.SECONDS);
        cancellation.get(10, TimeUnit.SECONDS);
    }
    private static void await(CountDownLatch latch) {
        try { latch.await(); } catch (InterruptedException e) { Thread.currentThread().interrupt(); throw new AssertionError(e); }
    }
    private static byte[] hexBytes(String s) { byte[] b = new byte[s.length()/2]; for (int i=0;i<b.length;i++) b[i]=(byte)Integer.parseInt(s.substring(i*2,i*2+2),16); return b; }
    private static String hex(byte[] b) { StringBuilder s = new StringBuilder(); for(byte v:b)s.append(String.format("%02x",v & 255));return s.toString(); }
}
