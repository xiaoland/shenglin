#!/usr/bin/env python3
"""用实际 Mac 展示与关闭配对代码检查状态边界；不启动音频、网络或 Keychain。"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
model = (root / 'MacGUI/AppModel.swift').read_text()
views = (root / 'MacGUI/App.swift').read_text()

def member(source, start, end):
    return source[source.index(start):source.index(end)]

peers = member(model, 'struct MacPeerDisplay:', '@MainActor private final class PadPeerSession')
status = member(model, '    var coordinationStatus:', '    var inputError:')
close = member(model, '    func endDevicePairingPresentation()', '    func offerDevicePairingCode()')
stop = member(model, '    func cancelMacPairing()', '    private func restorePreviousPairing()')
code = member(views, '    private var code: String', '    private func findDevices()')
volume = member(views, 'private struct VolumeTargetControl:', 'private struct MainPanel:')
volume_range = member(volume, '    private var sliderRange:', '    var body:')
output = member(model, '    @discardableResult private func updateOutputQuiet(', '    func installBrowserAdapter()')
notice = member(output, '        switch result {', '        let protectedNames')

source = r'''import Foundation
final class Session {
 var rejected = false
 var stopped = false
 func reject() { rejected = true }
 func stop() { stopped = true }
}
final class Presentation {
 var enabled = true
 var localDuckingEnabled = true
 var peerDisplays = [PeerDisplay]()
 var pendingKey: Data? = Data([1])
 var pendingMacIDs: Set<String> = ["pending"]
 var pairingPendingActivation: Bool { pendingKey != nil || !pendingMacIDs.isEmpty }
 var pairingGeneration = 0
 var pairClient: Session? = Session()
 var macPairClient: Session? = Session()
 var macPairServer: Session? = Session()
 var pairingActive = true
 var pairingCodeInput = "123456"
 var pairingAwaitingCode = true
 var showPairing = true
 var macPairCode: String? = "654321"
 var macPairCodeInput = "654321"
 var macPairAwaitingCode = true
 var macPairBrowsing = true
 var nearbyMacs = ["fixture"]
'''+status+close+stop+r'''}
struct CodeProbe {
 let model: Presentation
'''+code+r'''
 var acceptsCode: Bool { validCode }
}
struct VolumeRangeProbe {
 var relative: Bool
'''+volume_range+r'''
 var range: ClosedRange<Double> { sliderRange }
}
final class OutputNoticeProbe {
 var outputNotice: String?
 func apply(_ result: String) {
'''+notice+r'''
 }
}
assert(VolumeRangeProbe(relative: true).range == 0...1)
assert(VolumeRangeProbe(relative: false).range == 0...0.5)
let notice = OutputNoticeProbe()
notice.apply("preservedManual"); assert(notice.outputNotice?.contains("手动音量") == true)
notice.apply("outputUnsupported"); assert(notice.outputNotice?.contains("无法降低音量") == true)
notice.apply("unknown"); assert(notice.outputNotice?.contains("状态未知") == true)
for result in ["selectiveApplied", "alreadyQuiet", "restored", "alreadyRestored"] {
 notice.apply(result); assert(notice.outputNotice == nil)
}
func peer(_ id: String, connected: Bool, allowed: Bool, pending: Bool = false) -> PeerDisplay {
 PeerDisplay(id: id, name: "设备", status: "", link: "", connected: connected, spaceAllowed: allowed, pending: pending)
}
let state = Presentation()
state.pendingKey = nil; state.pendingMacIDs = []
assert(state.coordinationStatus == "本机协同已开启")
state.localDuckingEnabled = false
assert(state.coordinationStatus == "尚未添加设备")
state.peerDisplays = [peer("1", connected: true, allowed: false)]
assert(state.coordinationStatus == "等待空间条件")
state.peerDisplays = [peer("1", connected: false, allowed: false)]
assert(state.coordinationStatus == "等待设备连接")
state.peerDisplays = [peer("1", connected: false, allowed: true)]
assert(state.coordinationStatus == "设备短断连宽限")
assert(state.peerDisplays[0].summary == "短断连宽限")
state.peerDisplays += [peer("2", connected: true, allowed: true), peer("3", connected: true, allowed: true, pending: true)]
assert(state.coordinationStatus == "1 台设备可协同")
assert(state.peerDisplays[2].summary == "正在验证配对")
state.enabled = false
assert(state.coordinationStatus == "自动协同已暂停")
state.enabled = true; state.peerDisplays = []; state.pendingKey = Data([1])
assert(state.coordinationStatus == "正在验证新配对")
let probe = CodeProbe(model: state)
for value in ["123456", " 123456\n"] { state.pairingCodeInput = value; assert(probe.acceptsCode) }
for value in ["", "12345", "1234567", "12345a", "１２３４５６"] {
 state.pairingCodeInput = value; assert(!probe.acceptsCode)
}
state.pairingAwaitingCode = false; state.macPairCodeInput = "654321"
assert(probe.acceptsCode)
state.pendingMacIDs = ["pending"]
let client = state.pairClient!; let macClient = state.macPairClient!; let server = state.macPairServer!
state.endDevicePairingPresentation()
assert(client.rejected && macClient.stopped && server.stopped)
assert(!state.showPairing && !state.pairingActive && !state.macPairBrowsing)
assert(state.pairingCodeInput.isEmpty && state.macPairCodeInput.isEmpty && state.macPairCode == nil)
assert(!state.pairingAwaitingCode && !state.macPairAwaitingCode)
assert(state.pendingKey == Data([1]) && state.pendingMacIDs == ["pending"])
state.endDevicePairingPresentation()
assert(state.pendingKey == Data([1]) && state.pendingMacIDs == ["pending"])
print("Mac 展示状态、验证码边界及配对弹窗关闭检查通过。")
'''
with tempfile.TemporaryDirectory(prefix='shenglin-mac-presentation-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text('import Foundation\n' + peers + source)
    subprocess.run(['swiftc', str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
