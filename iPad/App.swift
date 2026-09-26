import MediaPlayer
import SwiftUI

struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView(frame: .zero) }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

@main struct NearbyAudioPadApp: App {
    @StateObject private var server = BLEServer()
    @AppStorage("targetVolume") private var targetVolume = 0.0

    var body: some Scene {
        WindowGroup {
            Form {
                Section("状态") {
                    Text(server.status)
                    Text(server.lastAction)
                    Button(server.enabled ? "停止监听并恢复音量" : "开始监听") {
                        server.setEnabled(!server.enabled)
                    }
                    Button("立即恢复音量") { server.restoreNow() }
                }
                Section("录音期间的媒体音量") {
                    Slider(value: $targetVolume, in: 0...0.5, step: 0.05)
                    Text("目标：\(Int((targetVolume * 100).rounded()))%")
                    SystemVolumeView().frame(height: 44)
                }
                Section("首次配对") {
                    Text("将此配对码输入 Mac 的 nearby-audio pair 命令。")
                    Text(server.pairingCode).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("复制配对码") { UIPasteboard.general.string = server.pairingCode }
                }
                Text("使用蓝牙接收 Mac 录音状态，只调整媒体音量；不采集 iPad 麦克风。")
                    .font(.footnote)
            }
        }
    }
}
