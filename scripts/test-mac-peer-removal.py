#!/usr/bin/env python3
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'MacGUI/AppModel.swift').read_text(); handler=s[s.index('    func removePeer('):s.index('    private func removePadSession')]
source='''import Foundation
struct Peer { let key: Data }
final class Link { var stopped=false; func stop(){stopped=true} }
struct Change { let ended=false; let manualAtEnd=false }
final class Ledger { var removed=[String](); func stopResponding(to id:String,at:Int64)->Change {removed.append(id);return Change()} }
enum MacCredentials { static var fail=false; static func removePeer(_ key:Data)throws {if fail {throw NSError(domain:"test",code:1)}} }
final class Probe {
 var pendingMacIDs=Set<String>(), pendingKey:Data?
 var savedMacPeers=[Peer](), padSessions=[String:Peer]()
 var macWifiPeers=[String:Link](),directBLEPeers=[String:Link]()
 var directBLEVerified=Set<String>(),macPeerVerified=Set<String>(),macPeerWiFiEvidence=Set<String>(),macPeerAllowed=Set<String>()
 var macPeerGates=[String:Bool]()
 var errorMessage:String?,lastAction="before",macPeerCount=2,directMacCount=2
 let peerLedger=Ledger()
 func sourceID(for key:Data)->String{key.base64EncodedString()}
 func removePadSession(for key:Data){padSessions.removeValue(forKey:sourceID(for:key))}
 func persistPeerLedger(){}
 func updateOutputQuiet(manualAtEnd:Bool){}
 func refreshMacPeerSpaces(){}
'''+handler+'''}
let p=Probe(), android=Peer(key:Data([1])), pad=Peer(key:Data([2]))
let a=p.sourceID(for:android.key),i=p.sourceID(for:pad.key), al=Link(),il=Link()
p.savedMacPeers=[android];p.padSessions=[i:pad];p.macWifiPeers=[a:al,i:il]
p.directBLEVerified=[a,i];p.macPeerVerified=[a,i];p.macPeerAllowed=[a,i]
MacCredentials.fail=true;p.removePeer(a)
assert(p.savedMacPeers.count==1 && !al.stopped && p.peerLedger.removed.isEmpty && p.lastAction=="before")
MacCredentials.fail=false;p.removePeer(a)
assert(p.savedMacPeers.isEmpty && al.stopped && !il.stopped && p.padSessions[i] != nil)
assert(p.directBLEVerified == [i] && p.macPeerAllowed == [i] && p.peerLedger.removed == [a])
print("Mac peer removal boundaries passed")
'''
with tempfile.TemporaryDirectory() as td:
 p=Path(td);(p/'main.swift').write_text(source)
 subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'check')],check=True);subprocess.run([str(p/'check')],check=True)
