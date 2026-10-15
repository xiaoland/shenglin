#!/usr/bin/env python3
"""Check actual input policy expressions across the poll/UI-delivery boundary without audio hardware."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
model = (root / 'MacGUI/AppModel.swift').read_text()
activity = (root / 'Mac/InputActivity.swift').read_text()
props = model[model.index('    var inputCount:'):model.index('    var localInputActive:')]
props = props.replace('private var needsQuiet', 'var needsQuiet').replace('private var inputKnown', 'var inputKnown')
observation = activity[activity.index('enum InputObservation'):activity.index('final class InputActivity')]
unavailable = activity[activity.index('    private func unavailable'):activity.index('    func poll()')]
unavailable = unavailable.replace('private func unavailable', 'func unavailable')
output = model[model.index('inputKnown: ', model.index('localOutput?.update')):model.index('manualOverride:', model.index('localOutput?.update'))]
output = output.removeprefix('inputKnown: ').rstrip().removesuffix(',')
source = '''import Foundation
'''+observation+r'''
final class Capture { func suspend() {} }
final class InputActivity {
 var protectedPIDs: Set<Int32> = [42]
 var protectedIdentities: Set<String> = ["reader"]
 var participatingPIDs: Set<Int32> = [42]
 var localDemandPIDs: Set<Int32> = [42]
 var previous: Set<Int32>? = [42]
 var previousLocalRecording = true
 var lastError: String?
 var captures: [Int:Capture] = [:]
 var lastObservation = InputObservation.active(1,true)
 var changed: (InputObservation) -> Void = { _ in }
'''+unavailable+r'''
}
struct Page { let role: String; let input: String }
struct Browser { let pages: [Page] = []; let known = true }
func sourceIdentities(pid: Int32) -> Set<String> { ["reader"] }
@MainActor final class Model {
 var input: InputActivity? = InputActivity()
 var inputState = InputObservation.active(1,true)
 let browser = Browser()
 func nativePIDs(_ pids: Set<Int32>) -> Set<Int32> { pids }
'''+props+'\n var outputInputKnown: Bool { '+output+r''' }
 init() {
  input?.changed = { [weak self] observation in
   Task { @MainActor [weak self] in self?.inputState = observation }
  }
 }
}
@main struct Check {
 @MainActor static func main() async {
  let model = Model()
  assert(model.needsQuiet && model.inputKnown && model.outputInputKnown)
  model.input?.unavailable("Core Audio 输入状态查询失败")
  // The timer publishes immediately after poll, before the queued UI callback runs.
  assert(model.inputState.error == nil)
  assert(!model.needsQuiet && !model.inputKnown && !model.outputInputKnown)
  await Task.yield()
  assert(!model.inputKnown && !model.outputInputKnown)
  // A successful idle observation must likewise ignore the stale UI error.
  model.input?.lastObservation = .active(0,false)
  assert(model.inputState.error != nil)
  assert(!model.needsQuiet && model.inputKnown && model.outputInputKnown)
  model.input?.participatingPIDs = [42]
  model.input?.protectedPIDs = [42]
  model.input?.lastObservation = .active(1,true)
  assert(model.needsQuiet && model.inputKnown && model.outputInputKnown)
  print("Mac 输入快照一致性通过：未知查询不发布已知 idle，恢复不受滞后 UI 状态影响。")
 }
}
'''
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp)
    (path / 'main.swift').write_text(source)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
