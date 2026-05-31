import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

/// AOA(Android Open Accessory) でタブレットと直接 USB バルク通信する transport。
/// adb スタックを介さないため、継続的 USB OUT ストリームでの adb トランスポート切断
/// (kIOReturnNotResponding) を原理的に回避する。USB デバッグも不要になる。
///
/// 流れ:
///   1. Android 端末を検出し、AOA 制御転送(51/52/53)で accessory モードへ遷移させる。
///   2. accessory インターフェース(class255/sub255/proto0)を確保し、バルク IN/OUT を開く。
///   3. バルク IN から DPRQ(解像度要求) を読み、onClientResolution へ。
///   4. sendHeader(DPRD)/sendAccessUnit を バルク OUT へ送る（シリアルキュー＋in-flightでバックプレッシャ）。
///
/// プロトコル本体は FrameServer と共通（経路だけ差し替え）。
final class AoaTransport: VideoTransport {

    var onClientResolution: ((Int, Int) -> Void)?
    var onClientDisconnected: (() -> Void)?

    private let codecByte: UInt8

    private var device: IOUSBHostDevice?
    private var interface: IOUSBHostInterface?
    private var inPipe: IOUSBHostPipe?
    private var outPipe: IOUSBHostPipe?

    /// USB IO は全て単一シリアルキューで実行する（パイプ生成・読み・書きを同一スレッド文脈に揃える。
    /// 別スレッドから IO を投げると "Unable to send IO" になるため）。
    private let ioQueue = DispatchQueue(label: "io.disproid.aoa.io")
    private let lock = NSLock()
    private var inFlight = 0
    private let maxInFlight = 2
    private var headerSent = false
    private var running = false
    private var connected = false
    private var disconnectedNotified = false

    init(isH265: Bool) {
        self.codecByte = isH265 ? 1 : 0
    }

    var isBacklogged: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight >= maxInFlight
    }

    // MARK: - VideoTransport

    func start() throws {
        running = true
        ioQueue.async { [weak self] in self?.establishLoop() }
    }

    func stop() {
        running = false
        connected = false
        ioQueue.sync {}  // 進行中の送信完了を待つ
        closeUSB()
    }

    func dropConnection() {
        // AOA は accessory 単一接続。完全停止は stop() のみ。ここでは状態リセットのみ。
        lock.lock(); headerSent = false; inFlight = 0; lock.unlock()
    }

    func sendHeader(width: Int, height: Int) {
        guard let pipe = outPipe else { return }
        var h = Data()
        h.append(contentsOf: Array("DPRD".utf8))
        h.append(1) // version
        h.append(codecByte)
        h.append(beData(UInt32(width)))
        h.append(beData(UInt32(height)))
        ioQueue.async { [weak self] in
            self?.writeAll(pipe, h)
            self?.lock.lock(); self?.headerSent = true; self?.lock.unlock()
        }
    }

    func sendAccessUnit(_ data: Data) {
        guard let pipe = outPipe else { return }
        lock.lock(); let ready = headerSent; lock.unlock()
        guard ready else { return }  // ヘッダ前のフレームは捨てる（境界誤読防止）
        var framed = Data()
        framed.append(beData(UInt32(data.count)))
        framed.append(data)
        lock.lock(); inFlight += 1; lock.unlock()
        ioQueue.async { [weak self] in
            self?.writeAll(pipe, framed)
            self?.lock.lock(); self?.inFlight -= 1; self?.lock.unlock()
        }
    }

    // MARK: - 接続確立（ioQueue 上）

    /// 接続を確立する。確立できるまで(while running) バックオフ付きでリトライする。
    /// 切断時(handleDisconnect)からも再呼び出しされ、端末の抜き差し/再遷移を吸収して自動復帰する。
    private func establishLoop() {
        guard running, !connected else { return }
        while running && !connected {
            if establishOnce() {
                connected = true
                lock.lock(); disconnectedNotified = false; lock.unlock()
                return
            }
            Thread.sleep(forTimeInterval: 0.5) // バックオフ（抜き差し・再遷移待ち）
        }
    }

    /// 1 回ぶんの確立: 検出→accessory遷移→interface/パイプ→DPRQ→onClientResolution。成功で true。
    private func establishOnce() -> Bool {
        closeUSB()
        lock.lock(); headerSent = false; inFlight = 0; lock.unlock()
        do {
            // 1. accessory モードへ（既に accessory なら遷移をスキップ）
            if !AoaUSB.accessoryPresent() {
                guard let cand = AoaUSB.findAndroidCandidate() else { return false }
                try AoaUSB.switchToAccessory(cand.service)
                IOObjectRelease(cand.service)
                var ok = false
                for _ in 0..<50 { Thread.sleep(forTimeInterval: 0.1); if AoaUSB.accessoryPresent() { ok = true; break } }
                guard ok else { return false }
            }

            // 2. accessory インターフェース + バルクパイプ
            var ifaceSvc: io_service_t = 0
            for _ in 0..<50 { if let s = AoaUSB.findAccessoryInterface() { ifaceSvc = s; break }; Thread.sleep(forTimeInterval: 0.1) }
            guard ifaceSvc != 0 else { return false }
            let iface = try IOUSBHostInterface(__ioService: ifaceSvc, options: [], queue: nil, interestHandler: nil)
            IOObjectRelease(ifaceSvc)
            guard let (inAddr, outAddr) = AoaUSB.findBulkEndpoints(iface) else { return false }
            let outP = try iface.copyPipe(withAddress: outAddr)
            let inP = try iface.copyPipe(withAddress: inAddr)
            self.interface = iface
            self.outPipe = outP
            self.inPipe = inP
            log("AOA: バルク確立 IN=\(String(format:"0x%02X",inAddr)) OUT=\(String(format:"0x%02X",outAddr))")

            // 3. DPRQ(12B) を読む（Android アプリ起動→FD オープン→送信を待つ）
            guard let (w, h) = readDPRQ(inP) else { return false }
            log("AOA: DPRQ 受信 \(w)x\(h)")
            onClientResolution?(w, h)
            return true
        } catch {
            log("AOA: 確立失敗: \(error.localizedDescription)")
            return false
        }
    }

    /// 切断検知（バルク送信失敗）。パイプを畳んで再確立ループへ。
    private func handleDisconnect() {
        guard running, connected else { return }
        connected = false
        closeUSB()
        notifyDisconnected()  // StreamEngine は waitingForClient（パイプライン維持）
        ioQueue.async { [weak self] in self?.establishLoop() }
    }

    /// DPRQ(4)+w(4,BE)+h(4,BE)=12B を読む。Android 起動待ちのため長めにリトライ。
    private func readDPRQ(_ pipe: IOUSBHostPipe) -> (Int, Int)? {
        var acc = Data()
        let deadline = Date().addingTimeInterval(20)
        while running && acc.count < 12 && Date() < deadline {
            let buf = NSMutableData(length: 512)!
            var n = 0
            do {
                try pipe.__sendIORequest(with: buf, bytesTransferred: &n, completionTimeout: 2.0)
                if n > 0 { acc.append(Data(referencing: buf).prefix(n)) }
            } catch {
                Thread.sleep(forTimeInterval: 0.2) // タイムアウト（まだ来ていない）→再試行
            }
        }
        guard acc.count >= 12 else { return nil }
        let b = [UInt8](acc.prefix(12))
        guard String(decoding: b[0..<4], as: UTF8.self) == "DPRQ" else { log("AOA: 不正なDPRQ"); return nil }
        let w = Int(beUInt32(b, 4)); let h = Int(beUInt32(b, 8))
        return (w, h)
    }

    /// バルク OUT へ全量書く。失敗したら切断扱い。
    private func writeAll(_ pipe: IOUSBHostPipe, _ data: Data) {
        guard running else { return }
        let m = NSMutableData(data: data)
        var sent = 0
        do {
            try pipe.__sendIORequest(with: m, bytesTransferred: &sent, completionTimeout: 2.0)
        } catch {
            let ns = error as NSError
            if running && connected { log("AOA: バルク送信失敗: \(ns.domain) code=\(ns.code) (\(ns.localizedDescription)) → 再接続") }
            handleDisconnect()
        }
    }

    private func notifyDisconnected() {
        lock.lock()
        let first = !disconnectedNotified
        disconnectedNotified = true
        lock.unlock()
        if first { onClientDisconnected?() }
    }

    private func closeUSB() {
        inPipe = nil; outPipe = nil
        interface = nil
        device = nil
    }

    // MARK: - helpers
    private func beData(_ v: UInt32) -> Data { var be = v.bigEndian; return Data(bytes: &be, count: 4) }
    private func beUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o+1]) << 16) | (UInt32(b[o+2]) << 8) | UInt32(b[o+3])
    }
}

private func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// AOA 用の IOKit/IOUSBHost ユーティリティ（PoC で実証したロジック）。
enum AoaUSB {
    static func intProp(_ svc: io_service_t, _ key: String) -> Int? {
        guard let cf = IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let num = cf as? NSNumber else { return nil }
        return num.intValue
    }

    static func parentVendor(_ svc: io_service_t) -> Int? {
        var cur = svc; var depth = 0; var owned = false
        while depth < 4 {
            if let v = intProp(cur, "idVendor") { if owned { IOObjectRelease(cur) }; return v }
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else {
                if owned { IOObjectRelease(cur) }; return nil
            }
            if owned { IOObjectRelease(cur) }
            cur = parent; owned = true; depth += 1
        }
        if owned { IOObjectRelease(cur) }
        return nil
    }

    static func findService(vid: Int, pid: Int) -> io_service_t? {
        guard let m = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return nil }
        m["idVendor"] = vid; m["idProduct"] = pid
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, m, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        let s = IOIteratorNext(iter)
        return s == 0 ? nil : s
    }

    /// AOA で扱える Android 端末が接続されているか（accessory 済み or 候補あり）。
    static func androidAvailable() -> Bool {
        if accessoryPresent() { return true }
        if let c = findAndroidCandidate() { IOObjectRelease(c.service); return true }
        return false
    }

    static func accessoryPresent() -> Bool {
        for pid in [0x2D00, 0x2D01, 0x2D02, 0x2D03, 0x2D04, 0x2D05] {
            if let s = findService(vid: 0x18D1, pid: pid) { IOObjectRelease(s); return true }
        }
        return false
    }

    /// Android 候補(非Apple・非ハブ・複合デバイス class0)を探し AOA 対応を確認する。
    static func findAndroidCandidate() -> (service: io_service_t, version: UInt16)? {
        guard let m = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return nil }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, m, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        while case let svc = IOIteratorNext(iter), svc != 0 {
            let vid = intProp(svc, "idVendor") ?? 0
            let cls = intProp(svc, "bDeviceClass") ?? -1
            // Apple(0x05AC)/ハブ(class9)を除外。複合デバイス(class0)のみ AOA 試行。
            if vid == 0x05AC || cls == 9 || cls != 0 { IOObjectRelease(svc); continue }
            if let dev = try? IOUSBHostDevice(__ioService: svc, options: [], queue: nil, interestHandler: nil),
               let ver = try? getProtocol(dev), ver >= 1 {
                return (svc, ver)  // svc は呼び出し側で release
            }
            IOObjectRelease(svc)
        }
        return nil
    }

    static func getProtocol(_ device: IOUSBHostDevice) throws -> UInt16 {
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0xC0; req.bRequest = 51; req.wValue = 0; req.wIndex = 0; req.wLength = 2
        let buf = NSMutableData(length: 2)!
        var n = 0
        try device.__send(req, data: buf, bytesTransferred: &n, completionTimeout: 1.0)
        guard n >= 2 else { return 0 }
        let b = [UInt8](Data(referencing: buf))
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    static func switchToAccessory(_ svc: io_service_t) throws {
        let device = try IOUSBHostDevice(__ioService: svc, options: [], queue: nil, interestHandler: nil)
        func sendString(_ idx: UInt16, _ v: String) throws {
            var req = IOUSBDeviceRequest()
            req.bmRequestType = 0x40; req.bRequest = 52; req.wValue = 0; req.wIndex = idx
            var d = Data(v.utf8); d.append(0)
            req.wLength = UInt16(d.count)
            var n = 0
            try device.__send(req, data: NSMutableData(data: d), bytesTransferred: &n, completionTimeout: 1.0)
        }
        try sendString(0, "Disproid")
        try sendString(1, "Disproid Display")
        try sendString(2, "Disproid USB extended display")
        try sendString(3, "1.0")
        try sendString(4, "https://github.com/k02miu/disproid")
        try sendString(5, "0000000012345678")
        var start = IOUSBDeviceRequest()
        start.bmRequestType = 0x40; start.bRequest = 53; start.wValue = 0; start.wIndex = 0; start.wLength = 0
        var n = 0
        try device.__send(start, data: nil, bytesTransferred: &n, completionTimeout: 1.0)
    }

    static func findAccessoryInterface() -> io_service_t? {
        guard let m = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else { return nil }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, m, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var result: io_service_t = 0
        while case let svc = IOIteratorNext(iter), svc != 0 {
            let cls = intProp(svc, "bInterfaceClass") ?? -1
            let sub = intProp(svc, "bInterfaceSubClass") ?? -1
            let proto = intProp(svc, "bInterfaceProtocol") ?? -1
            let vid = parentVendor(svc) ?? -1
            if result == 0 && vid == 0x18D1 && cls == 255 && sub == 255 && proto == 0 {
                result = svc
            } else {
                IOObjectRelease(svc)
            }
        }
        return result == 0 ? nil : result
    }

    static func findBulkEndpoints(_ iface: IOUSBHostInterface) -> (inAddr: Int, outAddr: Int)? {
        let cfg = iface.configurationDescriptor
        let intf = iface.interfaceDescriptor
        var inAddr = -1, outAddr = -1
        var current = UnsafeRawPointer(intf).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let ep = IOUSBGetNextEndpointDescriptor(cfg, intf, current) {
            let addr = Int(IOUSBGetEndpointAddress(ep))
            if UInt32(IOUSBGetEndpointType(ep)) == kIOUSBEndpointTypeBulk.rawValue {
                if (addr & 0x80) != 0 { inAddr = addr } else { outAddr = addr }
            }
            current = UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        guard inAddr >= 0, outAddr >= 0 else { return nil }
        return (inAddr, outAddr)
    }
}
