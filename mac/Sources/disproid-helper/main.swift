import Foundation
import CoreGraphics

// MARK: - 引数パース

let rawArgs = Array(CommandLine.arguments.dropFirst())
let options: Options
do {
    options = try Options.parse(rawArgs)
} catch let err as Options.ParseError {
    if case .help = err {
        print(err.description)
        exit(0)
    } else {
        FileHandle.standardError.write(Data("\(err.description)\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("引数の解析に失敗しました: \(error)\n".utf8))
    exit(2)
}

// USB(adb reverse) のポート。Android アプリは localhost:DEVICE_PORT に接続する。
let DEVICE_PORT: UInt16 = 27184
let HOST_PORT: UInt16 = 27184
let isH265 = false   // 当面 H.264（Android デコーダ互換重視）

let width = Int(options.width)
let height = Int(options.height)

// MARK: - 仮想ディスプレイ生成（拡張表示のキャプチャ元）

let virtualDisplay = VirtualDisplay(options: options)
print("""
[disproid-helper] 仮想ディスプレイを生成
  name      : \(options.name)
  mode      : \(width)x\(height) @ \(options.refreshRate)Hz
  displayID : \(virtualDisplay.displayID)
""")

// MARK: - 送信サーバ + USB トンネル

let server = FrameServer(port: HOST_PORT, isH265: isH265, width: width, height: height)
do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("[disproid-helper] サーバ起動失敗: \(error)\n".utf8))
    exit(1)
}
AdbBridge.reverse(devicePort: DEVICE_PORT, hostPort: HOST_PORT)

// MARK: - エンコーダ

let encoder = VideoEncoder(width: width, height: height, codec: isH265 ? .h265 : .h264)
encoder.onEncoded = { data, _ in
    server.sendAccessUnit(data)
}
do {
    try encoder.start()
} catch {
    FileHandle.standardError.write(Data("[disproid-helper] エンコーダ起動失敗: \(error)\n".utf8))
    exit(1)
}

// MARK: - キャプチャ（要・画面収録許可）

let capturer = ScreenCapturer(displayID: virtualDisplay.displayID, width: width, height: height, fps: Int(options.refreshRate))
capturer.onFrame = { imageBuffer, pts in
    encoder.encode(imageBuffer, pts: pts)
}
Task {
    do {
        try await capturer.start()
        FileHandle.standardError.write(Data("[disproid-helper] キャプチャ開始（Android アプリの USB 受信を待機）\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("[disproid-helper] キャプチャ開始失敗: \(error)\n（画面収録の許可を確認してください）\n".utf8))
        exit(1)
    }
}

print("""

USB ケーブルでタブレットを接続し、Android アプリの「USB で受信」を開始してください。
終了するには Ctrl-C を押してください。
""")

// MARK: - SIGINT ハンドリングと常駐

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    print("\n[disproid-helper] 終了処理中…")
    AdbBridge.removeReverse(devicePort: DEVICE_PORT)
    server.stop()
    encoder.stop()
    // 仮想ディスプレイはプロセス終了で破棄される
    exit(0)
}
sigintSource.resume()

dispatchMain()
