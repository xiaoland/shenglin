import AVFAudio
import Foundation
import ObjectiveC.runtime
import Darwin

@MainActor final class VolumeCoordinator {
    private typealias Get = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>, NSString) -> Bool
    private typealias Set = @convention(c) (AnyObject, Selector, Float, NSString) -> Bool
    private let stateKey = "NearbyAudioQuietSnapshot"
    private let controller: AnyObject
    private let getter: Get
    private let setter: Set
    private let category: NSString = "Audio/Video"
    private var snapshot: QuietSnapshot?
    private var restoreTimer: Timer?
    private var restoreStepCount = 0
    private var restoreStart: Float = 0

    init?() {
        _ = dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_LAZY | RTLD_LOCAL)
        // Private Objective-C ABI: reject changed signatures before casting IMPs to C functions.
        guard let cls = NSClassFromString("AVSystemController"),
              let shared = class_getClassMethod(cls, NSSelectorFromString("sharedAVSystemController")),
              let get = class_getInstanceMethod(cls, NSSelectorFromString("getVolume:forCategory:")),
              let set = class_getInstanceMethod(cls, NSSelectorFromString("setVolumeTo:forCategory:")),
              method_getTypeEncoding(shared).map({ String(cString: $0) }) == "@16@0:8",
              method_getTypeEncoding(get).map({ String(cString: $0) }) == "B32@0:8^f16@24",
              method_getTypeEncoding(set).map({ String(cString: $0) }) == "B28@0:8f16@20" else { return nil }
        typealias Shared = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
        controller = unsafeBitCast(method_getImplementation(shared), to: Shared.self)(cls, NSSelectorFromString("sharedAVSystemController")).takeUnretainedValue()
        getter = unsafeBitCast(method_getImplementation(get), to: Get.self)
        setter = unsafeBitCast(method_getImplementation(set), to: Set.self)
        if let data = UserDefaults.standard.data(forKey: stateKey) {
            snapshot = try? JSONDecoder().decode(QuietSnapshot.self, from: data)
        }
    }

    private func route() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.map { "\($0.portType.rawValue):\($0.uid)" }.joined(separator: "|")
    }

    func current() -> Float? {
        var value: Float = -1
        return getter(controller, NSSelectorFromString("getVolume:forCategory:"), &value, category) && value.isFinite && (0...1).contains(value) ? value : nil
    }

    private func write(_ value: Float) -> Bool {
        setter(controller, NSSelectorFromString("setVolumeTo:forCategory:"), value, category)
    }

    private func save() {
        UserDefaults.standard.set(snapshot.flatMap { try? JSONEncoder().encode($0) }, forKey: stateKey)
        UserDefaults.standard.synchronize()
    }

    func manualOrRouteChanged() -> Bool {
        guard let saved = snapshot else { return false }
        guard let now = current() else { return false }
        return route() != saved.route || abs(now - saved.applied) > 0.005
    }

    func release(manual: Bool) -> (String, Int) {
        guard let saved = snapshot else { return ("alreadyRestored", Int(((current() ?? 0) * 1000).rounded())) }
        guard !manual, let now = current(), route() == saved.route,
              abs(now - saved.applied) <= 0.005 else {
            restoreTimer?.invalidate()
            restoreTimer = nil
            snapshot = nil
            save()
            return ("preservedManualOrRoute", Int(((current() ?? 0) * 1000).rounded()))
        }
        guard abs(saved.original - now) > 0.005 else {
            snapshot = nil
            save()
            return ("alreadyRestored", Int((now * 1000).rounded()))
        }
        restoreStart = now
        restoreStepCount = 0
        restoreTimer?.invalidate()
        restoreTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restoreStep() }
        }
        return ("restoring", Int((now * 1000).rounded()))
    }

    private func restoreStep() {
        guard let saved = snapshot, let now = current(), route() == saved.route,
              abs(now - saved.applied) <= 0.005 else {
            restoreTimer?.invalidate()
            restoreTimer = nil
            snapshot = nil
            save()
            return
        }
        restoreStepCount += 1
        let next = restoreStart + (saved.original - restoreStart) * Float(restoreStepCount) / 8
        guard write(next), let actual = current() else {
            restoreTimer?.invalidate()
            restoreTimer = nil
            return
        }
        snapshot = QuietSnapshot(original: saved.original, applied: actual, route: saved.route)
        save()
        if restoreStepCount == 8 {
            restoreTimer?.invalidate()
            restoreTimer = nil
            snapshot = nil
            save()
        }
    }

    func apply(quiet: Bool, target: Float) -> (String, Int) {
        guard let now = current() else { return ("readFailed", -1) }
        if quiet {
            if restoreTimer != nil {
                restoreTimer?.invalidate()
                restoreTimer = nil
                snapshot = nil
                save()
            }
            if snapshot != nil { return ("alreadyQuiet", Int((now * 1000).rounded())) }
            guard let wanted = VolumePolicy.target(current: now, configured: target) else {
                return ("alreadyBelowTarget", Int((now * 1000).rounded()))
            }
            snapshot = QuietSnapshot(original: now, applied: wanted, route: route())
            save() // Persist the old volume before changing it.
            guard write(wanted) else {
                snapshot = nil
                save()
                return ("setFailed", -1)
            }
            guard let actual = current() else { return ("readFailedAfterSet", -1) }
            snapshot = QuietSnapshot(original: now, applied: actual, route: route())
            save()
            return ("applied", Int((actual * 1000).rounded()))
        }
        guard let saved = snapshot else { return ("alreadyRestored", Int((now * 1000).rounded())) }
        guard let original = VolumePolicy.restore(current: now, route: route(), snapshot: saved) else {
            snapshot = nil
            save()
            return ("preservedManualOrRoute", Int((now * 1000).rounded()))
        }
        guard write(original), let actual = current() else { return ("restoreFailed", -1) }
        snapshot = nil
        save()
        return ("restored", Int((actual * 1000).rounded()))
    }
}
