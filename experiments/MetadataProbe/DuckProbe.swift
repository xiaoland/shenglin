import Foundation
import AVFAudio

@MainActor final class DuckProbe {
    private var expiry: Task<Void, Never>?
    private var active = false
    var log: (String) -> Void = { _ in }

    func start(seconds: Double) -> String {
        guard seconds == 3 || seconds == 20 else { return "DUCK_REJECT duration" }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: .duckOthers)
            try session.setActive(true)
            active = true
            expiry?.cancel()
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard let self else { return }
                self.log(self.stop())
            }
            return "DUCK_ACTIVE lease=\(seconds)；没有播放音频、没有采集麦克风"
        } catch { return "DUCK_ERROR \(error)" }
    }

    func stop() -> String {
        expiry?.cancel(); expiry = nil
        guard active else { return "DUCK_ALREADY_INACTIVE" }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            active = false
            return "DUCK_INACTIVE；其他 App 是否恢复需独立观察"
        } catch { return "DUCK_STOP_ERROR \(error)" }
    }
}
