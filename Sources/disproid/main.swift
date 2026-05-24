import Foundation
import CoreGraphics

// MARK: - 引数パース

let rawArgs = Array(CommandLine.arguments.dropFirst())
let options: Options
do {
    options = try Options.parse(rawArgs)
} catch let err as Options.ParseError {
    // --help は正常終了、それ以外はエラー終了
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

// MARK: - 仮想ディスプレイ生成

// プロセス生存中ずっと保持する（解放するとディスプレイが消えるため）。
let virtualDisplay = VirtualDisplay(options: options)

let pointInfo = options.hiDPI
    ? "  (HiDPI: 見かけ上 \(options.width / 2)x\(options.height / 2) 相当)"
    : ""
print("""
[disproid] 仮想ディスプレイを生成しました
  name        : \(options.name)
  mode        : \(options.width)x\(options.height) @ \(options.refreshRate)Hz\(options.hiDPI ? " (HiDPI)" : "")
  displayID   : \(virtualDisplay.displayID)\(pointInfo)

System Settings > Displays に追加ディスプレイとして表示されます。
終了するには Ctrl-C を押してください。
""")

// MARK: - SIGINT ハンドリングと常駐

// デフォルトの SIGINT 動作（即時終了）を無効化し、DispatchSource で捕捉する。
signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    print("\n[disproid] SIGINT を受信。仮想ディスプレイを破棄して終了します。")
    // virtualDisplay の解放（プロセス終了）で CGVirtualDisplay も破棄される。
    exit(0)
}
sigintSource.resume()

// メインディスパッチキューを回し続けて常駐する。
dispatchMain()
