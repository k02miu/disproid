import Foundation

/// CLI 引数。外部依存ゼロのため自前で簡易パースする。
struct Options {
    var width: UInt32 = 1920
    var height: UInt32 = 1080
    var refreshRate: Double = 60.0
    var hiDPI: Bool = false
    var name: String = "Disproid Virtual Display"

    static let usage = """
    disproid - CGVirtualDisplay を使って macOS に仮想ディスプレイを 1 枚生成する CLI

    USAGE:
      disproid [--width W] [--height H] [--refresh HZ] [--hidpi] [--name NAME]

    OPTIONS:
      --width  W      モードのピクセル幅      (default: 1920)
      --height H      モードのピクセル高さ    (default: 1080)
      --refresh HZ    リフレッシュレート(Hz)  (default: 60)
      --hidpi         HiDPI(Retina) として登録する。
                      この場合 macOS は「見かけ上 幅/2 x 高さ/2」のスケール解像度を提供する。
                      例: 見かけ 1920x1080 の Retina にするには --width 3840 --height 2160 --hidpi
      --name   NAME   ディスプレイ名          (default: "Disproid Virtual Display")
      -h, --help      このヘルプを表示

    起動後はプロセスが常駐し、仮想ディスプレイはプロセス生存中のみ存在する。
    Ctrl-C (SIGINT) で仮想ディスプレイを破棄してクリーンに終了する。
    """

    /// 解析に失敗した場合は説明文字列を throw する。
    static func parse(_ args: [String]) throws -> Options {
        var opts = Options()
        var i = 0
        // 先頭の実行パスを除いた引数列を受け取る前提
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help":
                throw ParseError.help
            case "--width":
                opts.width = try Self.requireUInt32(args, &i, arg)
            case "--height":
                opts.height = try Self.requireUInt32(args, &i, arg)
            case "--refresh":
                opts.refreshRate = try Self.requireDouble(args, &i, arg)
            case "--hidpi":
                opts.hiDPI = true
            case "--name":
                opts.name = try Self.requireString(args, &i, arg)
            default:
                throw ParseError.message("不明な引数: \(arg)")
            }
            i += 1
        }

        guard opts.width > 0, opts.height > 0 else {
            throw ParseError.message("width / height は正の整数である必要があります")
        }
        guard opts.refreshRate > 0 else {
            throw ParseError.message("refresh は正の数である必要があります")
        }
        return opts
    }

    enum ParseError: Error, CustomStringConvertible {
        case help
        case message(String)
        var description: String {
            switch self {
            case .help: return Options.usage
            case .message(let m): return "\(m)\n\n\(Options.usage)"
            }
        }
    }

    private static func nextValue(_ args: [String], _ i: inout Int, _ flag: String) throws -> String {
        guard i + 1 < args.count else {
            throw ParseError.message("\(flag) に値が指定されていません")
        }
        i += 1
        return args[i]
    }

    private static func requireUInt32(_ args: [String], _ i: inout Int, _ flag: String) throws -> UInt32 {
        let v = try nextValue(args, &i, flag)
        guard let n = UInt32(v) else { throw ParseError.message("\(flag) の値が不正です: \(v)") }
        return n
    }

    private static func requireDouble(_ args: [String], _ i: inout Int, _ flag: String) throws -> Double {
        let v = try nextValue(args, &i, flag)
        guard let n = Double(v) else { throw ParseError.message("\(flag) の値が不正です: \(v)") }
        return n
    }

    private static func requireString(_ args: [String], _ i: inout Int, _ flag: String) throws -> String {
        return try nextValue(args, &i, flag)
    }
}
