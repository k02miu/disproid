import Foundation

/// `adb reverse` で USB トンネルを張る。
/// device の localhost:devicePort → Mac の localhost:hostPort へ転送される。
/// （Android アプリは localhost:devicePort へ接続すれば Mac の FrameServer に届く）
enum AdbBridge {

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
        let ok = run(adb, ["reverse", "tcp:\(devicePort)", "tcp:\(hostPort)"])
        if ok {
            FileHandle.standardError.write(Data("[adb] reverse tcp:\(devicePort) -> 127.0.0.1:\(hostPort) 設定\n".utf8))
        }
        return ok
    }

    static func removeReverse(devicePort: UInt16) {
        guard let adb = adbPath() else { return }
        _ = run(adb, ["reverse", "--remove", "tcp:\(devicePort)"])
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
