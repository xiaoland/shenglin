#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$repo" "$work" <<'PY'
from pathlib import Path
import sys
root,work=map(Path,sys.argv[1:]);source=(root/'scripts/test-mac-capture-format.sh').read_text()
stubs=source.split('cat > "$work/stubs.swift" <<\'SWIFT\'\n',1)[1].split('\nSWIFT',1)[0]
p=(root/'Shared/Protocol.swift').read_text();gain=p[p.index('public enum MicrophoneGain {'):p.index('public enum DedicatedInputPolicy {')]
stubs=stubs.replace('enum MicrophoneGain { static func apply(_ samples: [Float], gain: Float) -> [Float] { samples } }',gain)
stubs=stubs.replace('        lock.lock()\n        frames[selector', '        delivered[selector] = samples\n        lock.lock()\n        frames[selector')
(work/'stubs.swift').write_text(stubs)
(work/'main.swift').write_text((root/'Mac/VirtualMicrophone.swift').read_text())
PY
cat >> "$work/main.swift" <<'SWIFT'

var delivered = [String: [Float]]()
var writes = [AudioObjectID: Data]()
var failing: AudioObjectID?
func AudioObjectSetPropertyData(_ object: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UInt32, _ value: UnsafeRawPointer) -> OSStatus {
    precondition(address.pointee.mSelector == 0x4e414d50)
    if object == failing { return -50 }
    writes[object] = value.assumingMemoryBound(to: CFData.self).pointee as Data
    return noErr
}
extension VirtualMicrophone {
    static func verifyRemoteGain() throws {
        let capture = VirtualMicrophone(sampleRate: 48000, channels: 1)
        capture.generation = 2
        capture.destinations = [101, 102]
        capture.destinationSelectors = [101: "original", 102: "amplified"]
        capture.destinationGains = ["original": 1, "amplified": 8]
        var input = [Float](repeating: 0, count: 960)
        input.replaceSubrange(0..<5, with: [-0.25, -0.01, 0, 0.01, 0.25])
        let pcm = input.withUnsafeBytes { Data($0) }
        try capture.receiveRemotePCM(pcm, epoch: 2)
        precondition(writes[101] == pcm, "1倍必须逐字节保留原始PCM")
        let expected = MicrophoneGain.apply(input, gain: 8)
        precondition(writes[102] == expected.withUnsafeBytes { Data($0) }, "实际写入HAL的PCM必须应用该挂载增益")
        precondition(delivered["original"] == input && delivered["amplified"] == expected,
                     "取证必须记录实际送入HAL的样本")
        capture.destinationGains["amplified"] = 2
        try capture.receiveRemotePCM(pcm, epoch: 2)
        precondition(delivered["amplified"]?[4] == 0.5, "增益改变不能等待采集重启")
        let before = writes
        try capture.receiveRemotePCM(pcm, epoch: 1)
        precondition(writes == before && capture.diagnostics().tappedFrames == 1920,
                     "旧会话不得写入或增加供音计数")
        failing = 102
        do { try capture.receiveRemotePCM(pcm, epoch: 2); preconditionFailure("HAL失败必须上报") }
        catch { precondition(capture.diagnostics().pushFailedFrames == 960) }
        print("通过：真实远程供音边界的独立增益、峰值限制、取证一致、热更新、旧会话拒绝及HAL失败。")
    }
}
try VirtualMicrophone.verifyRemoteGain()
SWIFT
xcrun swiftc "$work/stubs.swift" "$work/main.swift" -o "$work/check"
"$work/check"
