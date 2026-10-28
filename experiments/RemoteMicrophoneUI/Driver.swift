import XCTest

final class RemoteMicUI: XCTestCase {
    func testDriver() throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let input = directory.appendingPathComponent("command.json")
        let output = directory.appendingPathComponent("result.json")
        try? FileManager.default.removeItem(at: input)
        let app = XCUIApplication(bundleIdentifier: "local.shenglin.pad")
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            if alert.debugDescription.contains("声邻"), alert.debugDescription.contains("麦克风"), alert.buttons["允许"].exists {
                alert.buttons["允许"].tap(); return true
            }
            return false
        }
        print("REMOTE_MIC_UI_READY")
        var previous = ""
        for _ in 0..<3600 {
            if let data = try? Data(contentsOf: input),
               let request = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let id = request["id"], id != previous, let action = request["action"] {
                previous = id
                var result: [String: Any] = ["id": id, "action": action]
                do {
                    switch action {
                    case "activate":
                        app.activate()
                        guard app.wait(for: .runningForeground, timeout: 5) else {
                            throw NSError(domain: "RemoteMicUI", code: 5, userInfo: [NSLocalizedDescriptionKey: "声邻未进入前台"])
                        }
                    case "sharing":
                        let control = app.switches["共享内置麦克风"]
                        guard app.state == .runningForeground, control.waitForExistence(timeout: 3),
                              let current = control.value as? String else {
                            throw NSError(domain: "RemoteMicUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "共享开关不可用"])
                        }
                        let desired = request["value"] == "true" ? "1" : "0"
                        if current != desired {
                            // SwiftUI exposes the whole row as a switch; tap the actual control at its right edge.
                            control.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
                        }
                        guard control.value as? String == desired else {
                            throw NSError(domain: "RemoteMicUI", code: 2, userInfo: [NSLocalizedDescriptionKey: "共享开关未达到期望值，请检查麦克风权限"])
                        }
                    case "lock":
                        guard SLPressLockButton() else {
                            throw NSError(domain: "RemoteMicUI", code: 3, userInfo: [NSLocalizedDescriptionKey: "当前XCTest不支持锁屏事件"])
                        }
                    case "status", "quit": break
                    default: throw NSError(domain: "RemoteMicUI", code: 4, userInfo: [NSLocalizedDescriptionKey: "未知UI命令"])
                    }
                } catch { result["error"] = error.localizedDescription }
                result["state"] = app.state.rawValue
                result["lockState"] = SLLockState()
                if app.state == .runningForeground {
                    let control = app.switches["共享内置麦克风"]
                    if control.exists { result["sharing"] = control.value as? String == "1" }
                    result["tree"] = app.debugDescription
                }
                try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                    .write(to: output, options: .atomic)
                print("REMOTE_MIC_UI_DONE \(id)")
                if action == "quit" { return }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("UI驱动等待命令超时")
    }
}
