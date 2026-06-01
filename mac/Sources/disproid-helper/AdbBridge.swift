import Foundation

/// `adb reverse` で USB トンネルを張る。
/// device の localhost:devicePort → Mac の localhost:hostPort へ転送される。
/// （Android アプリは localhost:devicePort へ接続すれば Mac の FrameServer に届く）
enum AdbBridge {

    /// Android 側 abstract socket 名（UsbVideoReceiver と一致させる）。
    /// tcp ループバックではなく abstract Unix domain socket を使う（scrcpy と同じ方式で
    /// 端末側 TCP スタックを経由させず adb トランスポートを安定させる狙い）。
    static let abstractName = "disproid"

    /// adb の実行パスを探す。
    static func adbPath() -> String? {
        let candidates: [String] = {
            var list: [String] = []
            if let home = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
                list.append("\(home)/platform-tools/adb")
            }
            if let root = ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] {
                list.append("\(root)/platform-tools/adb")
            }
            let home = NSHomeDirectory()
            list.append("\(home)/Library/Android/sdk/platform-tools/adb")
            list.append("/opt/homebrew/bin/adb")
            list.append("/usr/local/bin/adb")
            return list
        }()
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // PATH 上の adb
        return runWhich("adb")
    }

    @discardableResult
    static func reverse(devicePort: UInt16, hostPort: UInt16) -> Bool {
        guard let adb = adbPath() else {
            FileHandle.standardError.write(Data("[adb] adb が見つかりません（ANDROID_HOME/PATH を確認）\n".utf8))
            return false
        }
        let ok = run(adb, ["reverse", "localabstract:\(abstractName)", "tcp:\(hostPort)"])
        if ok {
            FileHandle.standardError.write(Data("[adb] reverse localabstract:\(abstractName) -> 127.0.0.1:\(hostPort) 設定\n".utf8))
        }
        return ok
    }

    static func removeReverse(devicePort: UInt16) {
        guard let adb = adbPath() else { return }
        _ = run(adb, ["reverse", "--remove", "localabstract:\(abstractName)"])
    }

    /// 指定ポートの reverse トンネルが既に張られているか。
    /// （reverse の再設定は進行中の接続を切るため、張り直す前の確認に使う）
    static func isReversed(devicePort: UInt16) -> Bool {
        guard let adb = adbPath() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["reverse", "--list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            // コマンドが失敗(adb: no devices 等)した時は状態不明。張り直すと進行中の
            // 接続を切る恐れがあるため「張られている」とみなして触らない（安全側）。
            guard p.terminationStatus == 0 else { return true }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(decoding: data, as: UTF8.self)
            return out.contains("localabstract:\(abstractName)")
        } catch {
            return true
        }
    }

    // MARK: - helpers

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            FileHandle.standardError.write(Data("[adb] 実行失敗: \(error)\n".utf8))
            return false
        }
    }

    private static func runWhich(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", name]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}
