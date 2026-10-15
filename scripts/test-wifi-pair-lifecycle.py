#!/usr/bin/env python3
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1];s=(root/'Shared/WiFiPairing.swift').read_text()
helper=s[s.index('func isLocalPairAdvertisement'):s.index('@MainActor private final class PairSocket')]
source='''import Foundation
import Network
'''+helper+'''
assert(isLocalPairAdvertisement(.bonjour(NWTXTRecord(["instance":"this-device"])), localID:"this-device"))
assert(!isLocalPairAdvertisement(.bonjour(NWTXTRecord(["instance":"same-name-other-device"])), localID:"this-device"))
assert(!isLocalPairAdvertisement(.bonjour(NWTXTRecord()), localID:"this-device"))
assert(!isLocalPairAdvertisement(.none, localID:"this-device"))
final class Session {
 var stopped=false; var statuses=[String]()
 func stop(){stopped=true}
 func onStatus(_ s:String){statuses.append(s)}
 func expired(){
'''
start=s.index('guard let self, !self.stopped else { return }',s.index('timer = Timer.scheduledTimer'))
end=s.index('\n            }',start)
body=s[start:end].replace('guard let self, !self.stopped else { return }','guard !self.stopped else { return }')
source+=body+'''
 }
}
let cancelled=Session();cancelled.stop();cancelled.expired();assert(cancelled.statuses.isEmpty)
let active=Session();active.expired();assert(active.stopped && active.statuses == ["设备配对已超时"])
print("Pairing self-discovery and stale timeout boundaries passed")
'''
with tempfile.TemporaryDirectory() as td:
 p=Path(td);(p/'main.swift').write_text(source)
 subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'check')],check=True);subprocess.run([str(p/'check')],check=True)
