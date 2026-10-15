package local.shenglin.ble;
import local.shenglin.core.*;
import java.util.*;
public final class BleProtocolTest {
    private static void check(boolean b) { if(!b)throw new AssertionError(); }
    private static void fails(Runnable r) { try { r.run(); }catch(IllegalArgumentException e){return;}throw new AssertionError(); }
    public static void main(String[] args) {
        check(!BleProtocol.central("mac","initiator")); check(BleProtocol.central("ipad","responder"));
        check(BleProtocol.central("android","initiator")); check(!BleProtocol.central("android","responder"));
        BleProtocol.PreparedWrite p=new BleProtocol.PreparedWrite(); p.append("state",0,new byte[300]); p.append("state",300,new byte[212]); check(p.value().length==512);
        fails(() -> p.append("state",512,new byte[1])); check(p.value().length==0);
        p.append("state",0,new byte[20]); fails(() -> p.append("ack",20,new byte[1]));
        fails(() -> p.append("state",1,new byte[1])); p.append("state",0,new byte[1]); p.clear(); check(p.characteristic()==null);
        byte[] value=new byte[256]; for(int i=0;i<value.length;i++)value[i]=(byte)i;
        check(Arrays.equals(Arrays.copyOfRange(value,22,44),BleProtocol.slice(value,22,23)));
        check(BleProtocol.slice(value,256,23).length==0); fails(() -> BleProtocol.slice(value,257,23));
        byte[] key=new byte[32]; BleProtocol.Proof proof=new BleProtocol.Proof();
        PeerState.Update state=PeerState.Update.signed("initiator",1,true,true,120,null,key); proof.sent(state);
        check(!proof.verified(1000));
        check(!proof.accept(PeerState.Ack.signed("responder",1,false,"applied",null,key),key,"responder",101,1000));
        PeerState.Ack ack=PeerState.Ack.signed("responder",1,true,"applied",null,key);
        byte[] wrongKey=new byte[32]; wrongKey[0]=1;
        check(!proof.accept(ack,wrongKey,"responder",101,1000));
        check(!proof.accept(ack,key,"initiator",101,1000));
        check(proof.accept(ack,key,"responder",101,1000)); check(proof.verified(20_999)); check(!proof.verified(21_000));
        check(!proof.accept(ack,key,"responder",102,2000));
        proof.sent(state); check(!proof.accept(ack,key,"responder",120,2000));
        proof.clear(); check(!proof.verified(1000));
        System.out.println("BleProtocolTest passed");
    }
}
