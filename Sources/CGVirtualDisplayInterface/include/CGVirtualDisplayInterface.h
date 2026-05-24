//
//  CGVirtualDisplayInterface.h
//
//  CoreGraphics の非公開 API CGVirtualDisplay 系クラスの Objective-C インターフェース宣言。
//
//  これらのクラスは公開 SDK のヘッダには存在しないため、ここで @interface を再現する。
//  実体は /System/Library/Frameworks/CoreGraphics.framework に存在し（実機 macOS 26.1 で確認）、
//  実行時に Objective-C ランタイムが解決する。SDK から import してはならない。
//
//  シグネチャは実行マシン（macOS 26.1 / arm64）上で objc ランタイムを introspection し、
//  実際のメソッド・プロパティ定義から再現したもの。macOS のバージョンによっては
//  プロパティの増減やシグネチャ差異がありうる。不確実な箇所には「要検証」と明示する。
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 仮想ディスプレイが提供する 1 つの表示モード（解像度 + リフレッシュレート）。
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@property (readonly, nonatomic) uint32_t width;
@property (readonly, nonatomic) uint32_t height;
@property (readonly, nonatomic) double refreshRate;
@end

/// 仮想ディスプレイ生成時に渡す記述子。EDID 相当のメタデータを保持する。
@interface CGVirtualDisplayDescriptor : NSObject
/// 終了ハンドラ等のコールバックが配送されるディスパッチキュー。生存している必要がある。
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy)   NSString *name;
/// フレームバッファの最大ピクセル幅／高さ。登録する全モードの最大値以上にする。
@property (nonatomic, assign) uint32_t maxPixelsWide;
@property (nonatomic, assign) uint32_t maxPixelsHigh;
/// 物理パネルサイズ（mm）。点密度（DPI）の算出に使われ、HiDPI 既定スケールに影響する。
@property (nonatomic, assign) CGSize   sizeInMillimeters;
@property (nonatomic, assign) uint32_t productID;
@property (nonatomic, assign) uint32_t vendorID;
@property (nonatomic, assign) uint32_t serialNum;
@property (nonatomic, assign) CGPoint  redPrimary;
@property (nonatomic, assign) CGPoint  greenPrimary;
@property (nonatomic, assign) CGPoint  bluePrimary;
@property (nonatomic, assign) CGPoint  whitePoint;
/// システムがディスプレイを破棄したときに queue 上で呼ばれる。
/// 要検証: ランタイム属性は単なる block (T@?)。引数の有無は不明なため (void) で宣言している。
///         実体が引数付きで呼んでも arm64 では余剰引数は無視されるため安全側。
@property (nonatomic, copy, nullable) void (^terminationHandler)(void);
@end

/// 仮想ディスプレイに適用する設定。提供する表示モード一覧と HiDPI 可否を持つ。
@interface CGVirtualDisplaySettings : NSObject
/// 1 で HiDPI（Retina）対応として登録される。
/// 要検証: HiDPI 時にモードの点解像度がピクセルの 1/2 になる挙動は macOS バージョン依存の可能性あり。
@property (nonatomic, assign) uint32_t hiDPI;
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic, assign) uint32_t rotation;
@end

/// 仮想ディスプレイ本体。このオブジェクトが生存している間だけディスプレイが存在する。
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
/// 生成された CGDirectDisplayID。他の CoreGraphics ディスプレイ API に渡せる。
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@end

NS_ASSUME_NONNULL_END
