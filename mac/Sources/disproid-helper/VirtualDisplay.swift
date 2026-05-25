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

        // 任意の識別子。実機の他ディスプレイと衝突しない適当な値。
        descriptor.vendorID = 0x1AF1   // "disproid" 由来の任意値
        descriptor.productID = 0x0001
        descriptor.serialNum = 0x0001

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
