import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

// AOA (Android Open Accessory) PoC-A:
// 接続中の Android 端末を開き、AOA プロトコル対応を確認し、accessory モードへ遷移させる。
// 成否は「端末が Google の VID 0x18D1 / PID 0x2D0x に再列挙されるか」で判定する。
// ※ 本体ヘルパーには一切触れない検証専用ツール。

// 通常モードの端末識別子（ioreg で確認した TCL Note A1 NXTPAPER）。
// 将来は VID/PID 固定ではなく AOA ハンドシェイクで動的検出する。
let NORMAL_VID = 0x1BBB
let NORMAL_PID = 0x0C01

// AOA 識別文字列のインデックス（AOAP 仕様）。
enum AoaString: UInt16 {
    case manufacturer = 0
    case model = 1
    case description = 2
    case version = 3
    case uri = 4
    case serial = 5
}

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

/// idVendor/idProduct に一致する IOUSBHostDevice の io_service_t を返す。
func findService(vid: Int, pid: Int) -> io_service_t? {
    guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return nil }
    matching["idVendor"] = vid
    matching["idProduct"] = pid
    var iter: io_iterator_t = 0
    let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
    guard kr == KERN_SUCCESS else { log("IOServiceGetMatchingServices 失敗: \(kr)"); return nil }
    defer { IOObjectRelease(iter) }
    let svc = IOIteratorNext(iter)
    return svc == 0 ? nil : svc
}

/// 現在 accessory(0x18D1/0x2D0x) として見えているか。
func accessoryPresent() -> Bool {
    for pid in [0x2D00, 0x2D01, 0x2D02, 0x2D03, 0x2D04, 0x2D05] {
        if let s = findService(vid: 0x18D1, pid: pid) {
            IOObjectRelease(s)
            log("→ accessory 検出: 0x18D1/\(String(format: "0x%04X", pid))")
            return true
        }
    }
    return false
}

func controlOut(_ device: IOUSBHostDevice, request: UInt8, value: UInt16, index: UInt16, data: Data?) throws {
    var req = IOUSBDeviceRequest()
    req.bmRequestType = 0x40 // host->device, vendor, device
    req.bRequest = request
    req.wValue = value
    req.wIndex = index
    req.wLength = UInt16(data?.count ?? 0)
    var transferred = 0
    if let data = data {
        let m = NSMutableData(data: data)
        try device.__send(req, data: m, bytesTransferred: &transferred, completionTimeout: 1.0)
    } else {
        try device.__send(req, data: nil, bytesTransferred: &transferred, completionTimeout: 1.0)
    }
}

func getProtocol(_ device: IOUSBHostDevice) throws -> UInt16 {
    var req = IOUSBDeviceRequest()
    req.bmRequestType = 0xC0 // device->host, vendor, device
    req.bRequest = 51
    req.wValue = 0
    req.wIndex = 0
    req.wLength = 2
    let buf = NSMutableData(length: 2)!
    var transferred = 0
    try device.__send(req, data: buf, bytesTransferred: &transferred, completionTimeout: 1.0)
    let bytes = [UInt8](Data(referencing: buf))
    guard transferred >= 2 else { return 0 }
    return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8) // LE
}

func sendString(_ device: IOUSBHostDevice, _ idx: AoaString, _ value: String) throws {
    var data = Data(value.utf8)
    data.append(0) // null 終端
    try controlOut(device, request: 52, value: 0, index: idx.rawValue, data: data)
}

/// io_service_t の整数プロパティを読む。
func intProp(_ svc: io_service_t, _ key: String) -> Int? {
    guard let cf = IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
    guard let num = cf as? NSNumber else { return nil }
    return num.intValue
}

/// 親(IOService plane)を辿って idVendor を得る。
func parentVendor(_ svc: io_service_t) -> Int? {
    var cur = svc
    var depth = 0
    var owned = false
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

/// AOA accessory インターフェース(class255/sub255/proto0, 親VID=0x18D1)を探す。
func findAccessoryInterface() -> io_service_t? {
    guard let matching = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary? else { return nil }
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    var result: io_service_t = 0
    while case let svc = IOIteratorNext(iter), svc != 0 {
        let num = intProp(svc, "bInterfaceNumber") ?? -1
        let cls = intProp(svc, "bInterfaceClass") ?? -1
        let sub = intProp(svc, "bInterfaceSubClass") ?? -1
        let proto = intProp(svc, "bInterfaceProtocol") ?? -1
        let vid = parentVendor(svc) ?? -1
        if vid == 0x18D1 {
            log("  IF num=\(num) class=\(cls) sub=\(sub) proto=\(proto) parentVID=0x\(String(vid, radix: 16))")
        }
        if result == 0 && vid == 0x18D1 && cls == 255 && sub == 255 && proto == 0 {
            result = svc // 採用（解放しない）
        } else {
            IOObjectRelease(svc)
        }
    }
    return result == 0 ? nil : result
}

/// バルク IN/OUT エンドポイントのアドレスを interface descriptor から探す。
func findBulkEndpoints(_ iface: IOUSBHostInterface) -> (inAddr: Int, outAddr: Int)? {
    let cfg = iface.configurationDescriptor
    let intf = iface.interfaceDescriptor
    var inAddr = -1, outAddr = -1
    var current = UnsafeRawPointer(intf).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
    while let ep = IOUSBGetNextEndpointDescriptor(cfg, intf, current) {
        let addr = Int(IOUSBGetEndpointAddress(ep))
        let type = IOUSBGetEndpointType(ep)
        let isBulk = (UInt32(type) == kIOUSBEndpointTypeBulk.rawValue)
        if isBulk {
            if (addr & 0x80) != 0 { inAddr = addr } else { outAddr = addr }
            log("  bulk EP 検出: addr=\(String(format: "0x%02X", addr))")
        }
        current = UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
    }
    guard inAddr >= 0, outAddr >= 0 else { return nil }
    return (inAddr, outAddr)
}

/// accessory のバルクで往復(エコー)テストする。Android 側 AoaProbeActivity が受信→送り返す。
func bulkEcho() {
    log("accessory interface を待機…")
    var ifaceSvc: io_service_t = 0
    for _ in 0..<100 { // 最大10秒。Android アプリ起動/権限付与を待つ
        if let s = findAccessoryInterface() { ifaceSvc = s; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard ifaceSvc != 0 else { log("accessory interface が見つからない"); return }

    do {
        let iface = try IOUSBHostInterface(__ioService: ifaceSvc, options: [], queue: nil, interestHandler: nil)
        log("interface を開いた。バルク EP を探索…")
        guard let (inAddr, outAddr) = findBulkEndpoints(iface) else {
            log("バルク EP が見つからない"); return
        }
        log("バルク IN=\(String(format:"0x%02X",inAddr)) OUT=\(String(format:"0x%02X",outAddr))")
        let outPipe = try iface.copyPipe(withAddress: outAddr)
        let inPipe = try iface.copyPipe(withAddress: inAddr)

        // === AoaTransport と同じ順序の再現テスト ===
        // 1. IN から DPRQ(12B) を読む（MirrorActivity が送ってくる）
        log("DPRQ 待ち…")
        var dprq = Data()
        let dl = Date().addingTimeInterval(15)
        while dprq.count < 12 && Date() < dl {
            let b = NSMutableData(length: 512)!
            var n = 0
            do { try inPipe.__sendIORequest(with: b, bytesTransferred: &n, completionTimeout: 2.0); if n > 0 { dprq.append(Data(referencing: b).prefix(n)) } }
            catch { Thread.sleep(forTimeInterval: 0.2) }
        }
        guard dprq.count >= 12 else { log("DPRQ 読めず"); return }
        let bb = [UInt8](dprq.prefix(12))
        let w = (Int(bb[4])<<24)|(Int(bb[5])<<16)|(Int(bb[6])<<8)|Int(bb[7])
        let h = (Int(bb[8])<<24)|(Int(bb[9])<<16)|(Int(bb[10])<<8)|Int(bb[11])
        log("DPRQ 受信 magic=\(String(decoding: bb[0..<4], as: UTF8.self)) \(w)x\(h)")

        // 2. DPRD(14B) を OUT へ書く
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v>>24 & 0xff), UInt8(v>>16 & 0xff), UInt8(v>>8 & 0xff), UInt8(v & 0xff)] }
        var dprd: [UInt8] = Array("DPRD".utf8) + [1, 0] + be(UInt32(w)) + be(UInt32(h))
        do {
            let m = NSMutableData(bytes: &dprd, length: dprd.count)
            var sent = 0
            try outPipe.__sendIORequest(with: m, bytesTransferred: &sent, completionTimeout: 2.0)
            log("✅ DPRD 送信成功 \(sent)B")
        } catch {
            let ns = error as NSError
            log("❌ DPRD 送信失敗: \(ns.domain) code=\(ns.code) (\(ns.localizedDescription))")
            return
        }

        // 3. ダミーフレームを連続送出して OUT が継続するか
        var success = 0
        for i in 0..<60 {
            let payloadLen = 8192
            var frame = be(UInt32(payloadLen))
            frame.append(contentsOf: [UInt8](repeating: UInt8(i & 0xff), count: payloadLen))
            do {
                let m = NSMutableData(bytes: frame, length: frame.count)
                var sent = 0
                try outPipe.__sendIORequest(with: m, bytesTransferred: &sent, completionTimeout: 2.0)
                success += 1
            } catch {
                let ns = error as NSError
                log("❌ フレーム\(i) 送信失敗: code=\(ns.code) (\(ns.localizedDescription))")
                break
            }
        }
        log(success == 60 ? "✅✅ ダミー60フレーム全送出成功＝CLIではOUT安定" : "⚠️ \(success)/60 で停止")
    } catch {
        log("interface/パイプ操作エラー: \(error)")
    }
}

// MARK: - main

log("=== AOA PoC-A 開始 ===")
if accessoryPresent() {
    log("既に accessory モードです → 遷移をスキップしてバルク往復のみ実行します。")
    bulkEcho()
    log("=== 完了 ===")
    exit(0)
}

guard let svc = findService(vid: NORMAL_VID, pid: NORMAL_PID) else {
    log("端末(0x\(String(NORMAL_VID, radix:16))/0x\(String(NORMAL_PID, radix:16)))が見つかりません。USB接続を確認してください。")
    exit(1)
}
log("端末を検出。IOUSBHostDevice を開きます…")

do {
    let device = try IOUSBHostDevice(__ioService: svc, options: [], queue: nil, interestHandler: nil)
    log("デバイスを開きました。")

    let ver = try getProtocol(device)
    log("AOA GET_PROTOCOL = \(ver)")
    guard ver >= 1 else {
        log("この端末は AOA 非対応のようです（version=\(ver)）。")
        exit(2)
    }

    log("識別文字列を送信…")
    try sendString(device, .manufacturer, "Disproid")
    try sendString(device, .model, "Disproid Display")
    try sendString(device, .description, "Disproid USB extended display")
    try sendString(device, .version, "1.0")
    try sendString(device, .uri, "https://github.com/k02miu/disproid")
    try sendString(device, .serial, "0000000012345678")

    log("START(req53) 送信 → accessory モードへ遷移要求…")
    try controlOut(device, request: 53, value: 0, index: 0, data: nil)

    log("遷移待ち（最大5秒、再列挙を監視）…")
    var switched = false
    for _ in 0..<50 {
        Thread.sleep(forTimeInterval: 0.1)
        if accessoryPresent() { switched = true; break }
    }
    if switched {
        log("✅ accessory モードへの遷移に成功しました（Mac→USBホスト経路が成立）。")
        bulkEcho()
    } else {
        log("⚠️ 5秒以内に accessory 再列挙を検出できませんでした。端末側のダイアログ/権限要求を確認してください。")
    }
} catch {
    log("USB操作でエラー: \(error)")
    exit(3)
}
log("=== 完了 ===")
