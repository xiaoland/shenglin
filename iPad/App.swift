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
                    Picker("空间条件", selection: Binding(get: { server.spaceMode }, set: server.setSpaceMode)) {
                        Text("蓝牙或 Wi-Fi").tag(SpaceMode.nearbyOrWiFi)
                        Text("蓝牙且 Wi-Fi").tag(SpaceMode.nearbyAndWiFi)
                    }
                    Text(server.spaceStatus).font(.footnote)
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
                Section("Mac 配对") {
                    Text(server.pairingPendingActivation ? "新配对已验证，等待 Mac 连接。"
                         : server.isPaired ? "已有 Mac 配对。新配对成功连接后会替换旧 Mac。" : "尚未配对 Mac。")
                    Text(server.pairingStatus).font(.footnote)
                    if let code = server.shortCode {
                        Text(code).font(.system(size: 34, weight: .bold, design: .monospaced))
                            .accessibilityLabel("配对验证码 \(code)")
                        Text("在 Mac 输入这 6 位数字。验证码仅在本次配对中有效。")
                            .font(.footnote)
                        Button("取消配对") { server.rejectPairing() }
                    } else if server.pairingMode {
                        Button("取消配对") { server.rejectPairing() }
                    } else {
                        Button("开始 2 分钟配对") { server.beginPairing() }
                    }
                }
                Text("通过蓝牙或已认证的 Wi-Fi 局域网接收 Mac 录音状态；不采集 iPad 麦克风，也尚未检测其他 iPad App 的录音。")
                    .font(.footnote)
            }
        }
    }
}
