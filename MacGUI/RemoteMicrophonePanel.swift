import SwiftUI

struct RemoteMicrophonePanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var peers = [PairedPeer]()
    @State private var selected = ""
    @State private var microphones = [PeerMicrophone]()
    @State private var loading = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("挂载远端麦克风").font(.title2)
            Picker("已配对设备", selection: $selected) {
                Text("选择设备").tag("")
                ForEach(peers, id: \.key) { peer in
                    Text("\(peer.name)（\(peer.platform.displayName)）").tag(MicrophoneProtocol.peerID(peer))
                }
            }.disabled(loading)
            Button(loading ? "正在连接…" : "读取已授权麦克风", action: loadSources)
                .disabled(loading || selected.isEmpty)
            List(microphones) { microphone in
                HStack {
                    Text(microphone.name)
                    Spacer()
                    Button("挂载") {
                        do {
                            let device = try RemoteMicrophoneMount.add(peerID: selected, microphone: microphone)
                            model.refreshSources()
                            message = "已挂载“\(device.deviceName)”，请在录音应用中选择这个输入。"
                        } catch { message = error.localizedDescription }
                    }
                }
            }.frame(minHeight: 140)
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 520, height: 390)
        .task { do { peers = try MacCredentials.peers() } catch { message = error.localizedDescription } }
        .onChange(of: selected) { _, _ in microphones = [] }
    }
    private func loadSources() {
        guard let peer = peers.first(where: { MicrophoneProtocol.peerID($0) == selected }) else { return }
        loading = true
        Task {
            do {
                let values = try await Task.detached { try PeerMicrophoneConnection.sources(peer: peer) }.value
                microphones = values
                message = values.isEmpty ? "对端尚未向本机授权麦克风。" : ""
            } catch { message = error.localizedDescription }
            loading = false
        }
    }
}
