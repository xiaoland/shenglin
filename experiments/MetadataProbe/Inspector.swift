import SwiftUI
import AVFAudio
import MediaPlayer

@MainActor var systemVolumeView: MPVolumeView?
@MainActor func visibleSystemVolume() -> Float? {
    systemVolumeView?.subviews.compactMap { $0 as? UISlider }.first?.value
}
struct SystemVolumeControl: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        systemVolumeView = view
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

@MainActor final class VolumeObserver: ObservableObject {
    @Published var value: Float = 0
    private var observation: NSKeyValueObservation?
    init() {
        // 只读系统媒体音量；不设置 category，不激活会话。
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.initial, .new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in
                self?.value = value
                FileHandle.standardOutput.write(Data("VOLUME \(Date().timeIntervalSince1970) \(value)\n".utf8))
            }
        }
    }
}

@main struct MetadataProbeApp: App {
    @StateObject private var ble = BLEProbe()
    @StateObject private var network = LANProbe()
    @StateObject private var volume = VolumeObserver()
    @State private var report = "默认扫描不写音量；实验参数可启用 Wi-Fi 命令或一次音量降低与恢复。没有后台保活或录音。"
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("音量接口实验探针").font(.title)
                    Text("系统媒体音量（只读）：\(volume.value)")
                    SystemVolumeControl().frame(height: 44)
                    Text("系统：\(UIDevice.current.systemVersion)")
                    Button("检查当前系统的类与符号") { report = scan() }
                    Text(network.status).textSelection(.enabled)
                    Text(report).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    ShareLink("导出检查结果", item: report)
                }.padding()
                .task {
                    report = scan()
                    if CommandLine.arguments.contains("--listen") { network.start() }
                    if CommandLine.arguments.contains("--heartbeat") { network.startHeartbeat() }
                    FileHandle.standardOutput.write(Data(("SCAN_BEGIN\n" + report + "\nSCAN_END\n").utf8))
                    if CommandLine.arguments.contains("--test-volume") {
                        try? await Task.sleep(for: .seconds(2))
                        let result = await testPrivateVolume()
                        report += "\n" + result
                        FileHandle.standardOutput.write(Data((result + "\n").utf8))
                    }
                }
            }
        }
    }
}
