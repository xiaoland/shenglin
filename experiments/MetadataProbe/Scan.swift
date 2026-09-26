import Foundation
import ObjectiveC.runtime
import Darwin

func methodReport(_ name: String, selectors: [String]) -> [String] {
    guard let cls = NSClassFromString(name) else { return ["\(name): 类不存在"] }
    return ["\(name): 类存在"] + selectors.map { name in
        let selector = NSSelectorFromString(name)
        let method = class_getInstanceMethod(cls, selector) ?? class_getClassMethod(cls, selector)
        guard let method, let encoding = method_getTypeEncoding(method) else {
            return "  \(name): 未找到"
        }
        return "  \(name): \(String(cString: encoding))"
    }
}

func scan() -> String {
    var lines = ["只检查库、符号和方法签名；不创建私有控制器、不调用音量函数。"]
    let libraries = [
        "/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer",
        "/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience",
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    ]
    for path in libraries {
        // 不卸载 Objective-C 库：类注册可能在进程生命期内保留。
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            lines.append("加载失败：\(path)，\(dlerror().map { String(cString: $0) } ?? "未知错误")")
            continue
        }
        lines.append("加载成功：\(path)")
        if path.hasSuffix("/MediaRemote") {
            for symbol in ["MRMediaRemoteGetMediaPlaybackVolume", "MRMediaRemoteSetMediaPlaybackVolume", "MRMediaRemoteGetSystemVolumeMuted", "MRMediaRemoteMuteSystemVolume"] {
                lines.append("\(symbol): \(dlsym(handle, symbol) == nil ? "未找到" : "存在，未调用")")
            }
        }
    }
    lines += methodReport("MPVolumeController", selectors: ["init", "setVolumeValue:", "setVolume:withNotificationDelay:", "volumeValue", "setVolumeAudioCategory:"])
    lines += methodReport("AVSystemController", selectors: ["sharedAVSystemController", "getVolume:forCategory:", "setVolumeTo:forCategory:", "setVolumeTo:forCategory:retainFullMute:"])
    return lines.joined(separator: "\n")
}

#if os(iOS)
import AVFAudio

@MainActor func testPrivateVolume() async -> String {
    guard let cls = NSClassFromString("AVSystemController"),
          let shared = class_getClassMethod(cls, NSSelectorFromString("sharedAVSystemController")),
          let get = class_getInstanceMethod(cls, NSSelectorFromString("getVolume:forCategory:")),
          let set = class_getInstanceMethod(cls, NSSelectorFromString("setVolumeTo:forCategory:")),
          String(cString: method_getTypeEncoding(shared)!) == "@16@0:8",
          String(cString: method_getTypeEncoding(get)!) == "B32@0:8^f16@24",
          String(cString: method_getTypeEncoding(set)!) == "B28@0:8f16@20" else {
        return "TEST_ABORT 方法缺失或 ABI 与本机 27 探测结果不同"
    }
    typealias Shared = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
    typealias Get = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>, NSString) -> Bool
    typealias Set = @convention(c) (AnyObject, Selector, Float, NSString) -> Bool
    let object = unsafeBitCast(method_getImplementation(shared), to: Shared.self)(cls, NSSelectorFromString("sharedAVSystemController")).takeUnretainedValue()
    let getVolume = unsafeBitCast(method_getImplementation(get), to: Get.self)
    let setVolume = unsafeBitCast(method_getImplementation(set), to: Set.self)
    let category: NSString = "Audio/Video"
    var original: Float = -1
    guard getVolume(object, NSSelectorFromString("getVolume:forCategory:"), &original, category),
          original.isFinite, original >= 0.0625, original <= 1 else {
        return "TEST_ABORT 私有 getter 失败或音量超出实验范围：\(original)"
    }
    let target = original - 0.0625
    var events = ["TEST_BASELINE \(original) TARGET \(target) systemSlider=\(String(describing: visibleSystemVolume()))"]
    FileHandle.standardOutput.write(Data((events[0] + "\n").utf8))
    let changed = setVolume(object, NSSelectorFromString("setVolumeTo:forCategory:"), target, category)
    events.append("TEST_SET_RETURN \(changed)")
    do { try await Task.sleep(for: .seconds(2)) } catch { return events.joined(separator: "\n") + "\nTEST_CANCELED 未自动恢复" }
    var current: Float = -1
    let read = getVolume(object, NSSelectorFromString("getVolume:forCategory:"), &current, category)
    let publicValue = AVAudioSession.sharedInstance().outputVolume
    events.append("TEST_AFTER private=\(current) public=\(publicValue) systemSlider=\(String(describing: visibleSystemVolume())) read=\(read)")
    // 只恢复同一分类 getter 确认仍等于测试值的已知原值；公开读数独立记录。
    guard changed, read, abs(current-target) < 0.005 else {
        return events.joined(separator: "\n") + "\nTEST_NO_RESTORE 当前值不满足恢复条件"
    }
    events.append("TEST_RESTORE_RETURN \(setVolume(object, NSSelectorFromString("setVolumeTo:forCategory:"), original, category))")
    do { try await Task.sleep(for: .seconds(1)) } catch { return events.joined(separator: "\n") }
    var restored: Float = -1
    let restoredRead = getVolume(object, NSSelectorFromString("getVolume:forCategory:"), &restored, category)
    events.append("TEST_RESTORED private=\(restored) public=\(AVAudioSession.sharedInstance().outputVolume) systemSlider=\(String(describing: visibleSystemVolume())) read=\(restoredRead)")
    return events.joined(separator: "\n")
}
#endif

func experimentCommand(_ data: Data, token: String, now: Double) -> String? {
    guard data.count <= 192, let text = String(data: data, encoding: .utf8) else { return nil }
    let parts = text.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == token,
          ["ping", "volume", "duck", "hold", "stop"].contains(String(parts[1])),
          let deadline = Double(parts[2]), deadline.isFinite,
          deadline > now, deadline <= now + 10 else { return nil }
    return String(parts[1])
}
