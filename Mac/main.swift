import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard let action = arguments.first else {
    print("用法：nearby-audio control status|pair|enabled|exclude|mute|target ... | sources | exclude|mute ...")
    exit(2)
}

if action == "control" {
    let parts = Array(arguments.dropFirst())
    let request: ControlRequest
    if parts == ["status"] { request = ControlRequest(command: "status") }
    else if parts == ["driver", "install"] { request = ControlRequest(command: "driver.install") }
    else if parts == ["microphone", "agent", "stop"] { request = ControlRequest(command: "microphone.agent.stop") }
    else if parts == ["pair", "start"] { request = ControlRequest(command: "pair.start") }
    else if parts == ["pair", "cancel"] { request = ControlRequest(command: "pair.cancel") }
    else if parts == ["pair", "code"] {
        print("请输入 iPad 显示的 6 位验证码：", terminator: "")
        fflush(stdout)
        request = ControlRequest(command: "pair.code", value: readLine())
    }
    else if parts.count == 3, parts[0...1] == ["pair", "choose"] {
        request = ControlRequest(command: "pair.choose", value: parts[2])
    } else if parts == ["enabled", "on"] { request = ControlRequest(command: "enabled.on") }
    else if parts == ["enabled", "off"] { request = ControlRequest(command: "enabled.off") }
    else if parts.count == 3, parts[0...1] == ["exclude", "add"] {
        request = ControlRequest(command: "exclude.add", value: parts[2])
    } else if parts.count == 3, parts[0...1] == ["exclude", "remove"] {
        request = ControlRequest(command: "exclude.remove", value: parts[2])
    } else if parts.count == 3, parts[0...1] == ["mute", "add"] {
        request = ControlRequest(command: "mute.add", value: parts[2])
    } else if parts.count == 3, parts[0...1] == ["mute", "remove"] {
        request = ControlRequest(command: "mute.remove", value: parts[2])
    } else if parts.count == 3, parts[0] == "microphone", ["add", "remove"].contains(parts[1]) {
        request = ControlRequest(command: "microphone." + parts[1], value: parts[2])
    } else if parts.count == 3, parts[0] == "target" {
        request = ControlRequest(command: "target.set", value: "\(parts[1]):\(parts[2])")
    } else {
        print("用法：nearby-audio control status | driver install | pair start|choose <UUID>|code|cancel | enabled on|off | exclude|mute|microphone add|remove <标识> | target <设备 ID> <0...0.5>")
        exit(2)
    }
    do {
        let response = try ControlIPC.exchange(request)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(response), as: UTF8.self))
        exit(response.ok ? 0 : 1)
    } catch {
        print("本机控制失败：\(error.localizedDescription)")
        exit(1)
    }
}

if action == "sources" {
    do { try printSources() } catch { print("无法列出输入源：\(error)"); exit(1) }
    exit(0)
}

if action == "exclude" {
    do {
        switch arguments.dropFirst().first {
        case "list":
            let excluded = try ExclusionStore.load()
            print(excluded.isEmpty ? "无排除应用；所有活动录音进程默认参与。" : excluded.sorted().joined(separator: "\n"))
        case "add", "remove":
            guard arguments.count == 3, let selector = ExclusionStore.normalized(arguments[2]) else {
                print("请输入 bundle ID（如 nz.owo.koe）或 path:/可执行文件/绝对路径")
                exit(2)
            }
            try ExclusionStore.change(selector, add: arguments[1] == "add")
            print("已更新排除应用；运行中的程序将在 250 毫秒内重新检查。")
        default:
            print("用法：nearby-audio exclude list|add|remove [标识]")
            exit(2)
        }
    } catch { print("无法更新排除应用：\(error)"); exit(1) }
    exit(0)
}

if action == "mute" {
    do {
        switch arguments.dropFirst().first {
        case "list":
            let muted = try MuteStore.load()
            print(muted.isEmpty ? "无静音应用" : muted.sorted().joined(separator: "\n"))
        case "add", "remove":
            guard arguments.count == 3, let selector = ExclusionStore.normalized(arguments[2]) else {
                print("请输入 bundle ID 或 path:/可执行文件/绝对路径")
                exit(2)
            }
            try MuteStore.change(selector, add: arguments[1] == "add")
            print("已更新静音设置；运行中的程序将在 250 毫秒内重新检查。")
        default:
            print("用法：nearby-audio mute list|add|remove [标识]")
            exit(2)
        }
    } catch { print("无法更新静音应用：\(error)"); exit(1) }
    exit(0)
}

print("未知命令：\(action)")
exit(2)
