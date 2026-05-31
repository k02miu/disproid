import Foundation
import CoreGraphics
import CGVirtualDisplayInterface

/// CGVirtualDisplay を 1 枚生成・保持するラッパー。
/// インスタンスが解放されると仮想ディスプレイも消滅するため、呼び出し側で強参照を保持すること。
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    /// terminationHandler 等が配送されるキュー。生存させ続ける必要がある。
    private let callbackQueue: DispatchQueue

    let displayID: CGDirectDisplayID
    let options: Options

    /// 作成毎にユニークな EDID serialNum を採番するためのカウンタ。
    /// 起動毎に乱数を基点にし、生成のたびに増やす。下の説明を参照。
    private static var serialSeed: UInt32 = UInt32.random(in: 1...0x7FFF_FFFF)
    private static func nextSerial() -> UInt32 {
        serialSeed &+= 1
        return serialSeed
    }

    init(options: Options) {
        self.options = options
        self.callbackQueue = DispatchQueue(label: "io.disproid.virtualdisplay.callback")

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = callbackQueue
        descriptor.name = options.name

        // 物理サイズ(mm)は DPI 算出に使われる。
        // 非 HiDPI では点解像度＝ピクセル、HiDPI では点解像度＝ピクセル/2 として
        // 妥当な点密度（約 109ppi）になるよう逆算する。
        // 要検証: 既定スケールの選択挙動は macOS バージョン依存の可能性あり。
        let pointDPI = 109.0
        let pointWidth = options.hiDPI ? Double(options.width) / 2.0 : Double(options.width)
        let pointHeight = options.hiDPI ? Double(options.height) / 2.0 : Double(options.height)
        descriptor.sizeInMillimeters = CGSize(
            width: pointWidth / pointDPI * 25.4,
            height: pointHeight / pointDPI * 25.4
        )

        descriptor.maxPixelsWide = options.width
        descriptor.maxPixelsHigh = options.height

        // EDID 識別子。
        // 重要: macOS は仮想ディスプレイを EDID identity(vendorID/productID/serialNum)で
        // 同定し、その identity ごとに「最後に使った解像度」をシステム設定に永続保存する。
        // 一度ある identity が誤った解像度(例: 1344x1008)で記録されると、以後その identity で
        // 仮想ディスプレイを作っても要求モード(縦 1440x2200 など)が無視され、記録値に固着する。
        // これがタブレットを縦にしても横のまま(上下黒帯)になる真因だった。
        // 対策: 作成毎に serialNum を変え、常に「新品の未知ディスプレイ」として登録する。
        // こうすれば過去に汚染された identity を二度と踏まず、要求モードが確実に適用される。
        descriptor.vendorID = 0x1AF1   // "disproid" 由来の任意値
        descriptor.productID = 0x0001
        descriptor.serialNum = Self.nextSerial()

        // sRGB 相当の色域プライマリ。EDID として妥当な値を入れておく。
        descriptor.redPrimary   = CGPoint(x: 0.640, y: 0.330)
        descriptor.greenPrimary = CGPoint(x: 0.300, y: 0.600)
        descriptor.bluePrimary  = CGPoint(x: 0.150, y: 0.060)
        descriptor.whitePoint   = CGPoint(x: 0.3127, y: 0.3290) // D65

        descriptor.terminationHandler = {
            // システム側からディスプレイが破棄された場合に呼ばれる想定。
            // 要検証: 呼び出しタイミング・スレッドは未確認。
            FileHandle.standardError.write(Data("[disproid] terminationHandler が呼ばれました（システムがディスプレイを破棄）\n".utf8))
        }

        let display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = options.hiDPI ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(
                width: options.width,
                height: options.height,
                refreshRate: options.refreshRate
            )
        ]

        let applied = display.apply(settings)
        if !applied {
            FileHandle.standardError.write(Data("[disproid] 警告: applySettings が false を返しました（モード適用に失敗の可能性）\n".utf8))
        }

        self.display = display
        self.displayID = display.displayID
    }
}
