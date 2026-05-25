import SwiftUI

@main
struct DisproidHelperApp: App {
    @StateObject private var engine = StreamEngine()

    var body: some Scene {
        MenuBarExtra {
            ControlView(engine: engine)
        } label: {
            Image(nsImage: Self.menubarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    /// メニューバー用アイコン（disproid グリフ）。template 指定で light/dark に追従。
    private static let menubarIcon: NSImage = {
        let img: NSImage
        if let url = Bundle.module.url(forResource: "menubar", withExtension: "png"),
           let loaded = NSImage(contentsOf: url) {
            img = loaded
        } else {
            img = NSImage(systemSymbolName: "display", accessibilityDescription: "Disproid") ?? NSImage()
        }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }()
}

struct ControlView: View {
    @ObservedObject var engine: StreamEngine

    private let autoLabel = "自動（タブレットに合わせる）"
    private let resolutions: [(String, Int, Int)] = [
        ("1280 × 720", 1280, 720),
        ("1920 × 1080", 1920, 1080),
        ("1920 × 1200", 1920, 1200),
        ("2560 × 1600", 2560, 1600),
    ]
    private let bitrates = [5, 10, 20, 40, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "display")
                Text("Disproid Helper").font(.headline)
            }

            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(statusText).font(.subheadline)
            }

            if engine.state == .streaming, !engine.statsText.isEmpty {
                Text(engine.statsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // 解像度（停止中のみ変更可）
            Picker("解像度", selection: resolutionBinding) {
                Text(autoLabel).tag(autoLabel)
                ForEach(resolutions, id: \.0) { item in
                    Text(item.0).tag(item.0)
                }
            }
            .disabled(engine.isRunning)
            .pickerStyle(.menu)

            if engine.state == .streaming, !engine.activeResolution.isEmpty {
                Text("送出: \(engine.activeResolution)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // ビットレート（稼働中でも変更可＝ライブ反映）
            Picker("画質(ビットレート)", selection: $engine.bitrateMbps) {
                ForEach(bitrates, id: \.self) { mbps in
                    Text("\(mbps) Mbps").tag(mbps)
                }
            }
            .pickerStyle(.menu)

            // 開始/停止
            if engine.isRunning {
                Button {
                    engine.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button {
                    engine.start()
                } label: {
                    Label("開始", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if case .error(let msg) = engine.state {
                Text(msg).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("タブレットを USB 接続し、アプリで「USB で受信」を押してください。\n（USB デバッグ ON が必要）")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("終了") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 280)
    }

    private var resolutionBinding: Binding<String> {
        Binding(
            get: {
                if engine.autoResolution { return autoLabel }
                return resolutions.first { $0.1 == engine.width && $0.2 == engine.height }?.0 ?? autoLabel
            },
            set: { label in
                if label == autoLabel {
                    engine.autoResolution = true
                } else if let item = resolutions.first(where: { $0.0 == label }) {
                    engine.autoResolution = false
                    engine.width = item.1
                    engine.height = item.2
                }
            }
        )
    }

    private var statusText: String {
        switch engine.state {
        case .stopped: return "停止中"
        case .starting: return "起動中…"
        case .waitingForClient: return "待機中（タブレット接続待ち）"
        case .streaming: return "ストリーミング中"
        case .error: return "エラー"
        }
    }

    private var statusColor: Color {
        switch engine.state {
        case .streaming: return .green
        case .waitingForClient, .starting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }
}
