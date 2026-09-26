import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard let action = arguments.first else {
    print("用法：nearby-audio pair | sources | select list|add|remove [标识] | run")
    exit(2)
}

if action == "sources" {
    do { try printSources() } catch { print("无法列出输入源：\(error)"); exit(1) }
    exit(0)
}

if action == "select" {
    do {
        switch arguments.dropFirst().first {
        case "list":
            let selected = try SelectionStore.load()
            print(selected.isEmpty ? "尚未选择输入源；自动音量控制保持空闲。" : selected.sorted().joined(separator: "\n"))
        case "add", "remove":
            guard arguments.count == 3, let selector = SelectionStore.normalized(arguments[2]) else {
                print("请输入 bundle ID（如 nz.owo.koe）或 path:/可执行文件/绝对路径")
                exit(2)
            }
            try SelectionStore.change(selector, add: arguments[1] == "add")
            print("已更新输入源；运行中的程序将在 250 毫秒内重新检查。")
        default:
            print("用法：nearby-audio select list|add|remove [标识]")
            exit(2)
        }
    } catch { print("无法更新输入源：\(error)"); exit(1) }
    exit(0)
}

if action == "pair" {
    print("粘贴 iPad 上显示的配对码，然后按回车：")
    guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
          let key = Data(base64Encoded: input), key.count == 32 else {
        print("配对码无效")
        exit(2)
    }
    do {
        try MacCredentials.save(key, account: "pairingKey")
        print("已配对。运行：nearby-audio run")
    } catch {
        print("无法保存配对信息：\(error)")
        exit(1)
    }
    exit(0)
}

guard action == "run", arguments.count == 1 else {
    print("未知命令：\(action)")
    exit(2)
}

let key: Data
do {
    guard let saved = try MacCredentials.read("pairingKey"), saved.count == 32 else {
        print("尚未配对。打开 iPad 上的 Nearby Audio，然后运行：nearby-audio pair")
        exit(2)
    }
    key = saved
} catch {
    print("无法读取配对信息：\(error)")
    exit(1)
}

guard let runLock = RunLock() else {
    print("另一个 Nearby Audio 控制程序正在运行；请先退出菜单栏 App 或旧命令行进程。")
    exit(2)
}

let client = BLEClient(key: key)
let input = InputActivity { active, count in
    print("\(Date().timeIntervalSince1970) INPUT active=\(active) count=\(count)")
    fflush(stdout)
    client.setDesired(active)
}
input.poll() // Synchronize a recording that started before this process.
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in input.poll() }

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let stopSignals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        client.setDesired(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }
    source.resume()
    return source
}
withExtendedLifetime((stopSignals, runLock)) { RunLoop.main.run() }
