import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// VideoToolbox で CVImageBuffer を H.264 / H.265 にエンコードし、Annex-B のアクセスユニットを出力する。
/// キーフレームには SPS/PPS(H.265 は VPS も) を先頭に付与する。
final class VideoEncoder {

    enum Codec {
        case h264
        case h265
        var vtCodecType: CMVideoCodecType {
            switch self {
            case .h264: return kCMVideoCodecType_H264
            case .h265: return kCMVideoCodecType_HEVC
            }
        }
    }

    private var session: VTCompressionSession?
    private let codec: Codec
    private let width: Int32
    private let height: Int32

    /// Annex-B のアクセスユニット（NAL 列）を受け取るコールバック。
    var onEncoded: ((Data, _ isKeyframe: Bool) -> Void)?

    private var bitrate: Int

    init(width: Int, height: Int, codec: Codec, bitrate: Int = 20_000_000) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.codec = codec
        self.bitrate = bitrate
    }

    func start() throws {
        // 低遅延レート制御を有効化（macOS 11.3+）。エンコーダの溜め込みを抑える。
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codec.vtCodecType,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session = session else {
            throw NSError(domain: "VideoEncoder", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate 失敗 (\(status))"])
        }
        self.session = session

        // 低遅延・リアルタイム設定
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // フレームを溜めない（出力遅延 0）
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        applyBitrate(session, bitrate)
        if codec == .h264 {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_High_AutoLevel)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// ビットレートを変更する（稼働中でも反映される）。
    func setBitrate(_ bps: Int) {
        bitrate = bps
        if let session = session {
            applyBitrate(session, bps)
        }
    }

    private func applyBitrate(_ session: VTCompressionSession, _ bps: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        // 瞬間スパイクを抑えて遅延の暴れを防ぐ（1秒あたり平均の約1.5倍を上限）。
        let bytesPerSec = bps / 8
        let limits: [Any] = [(bytesPerSec * 3 / 2) as CFNumber, 1 as CFNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
    }

    func encode(_ imageBuffer: CVImageBuffer, pts: CMTime) {
        guard let session = session else { return }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer else { return }
            self?.handleEncoded(sampleBuffer)
        }
    }

    func stop() {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    // MARK: - Annex-B 変換

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let isKeyframe = Self.isKeyframe(sampleBuffer)

        var out = Data()
        // キーフレームならパラメータセット(VPS/SPS/PPS)を Annex-B で先頭に付与
        if isKeyframe, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for ps in Self.parameterSets(fmt, codec: codec) {
                out.append(contentsOf: [0, 0, 0, 1])
                out.append(ps)
            }
        }

        // AVCC(4バイト長前置) → Annex-B(00 00 00 01)
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let base = dataPointer else { return }

        var offset = 0
        while offset < totalLength - 4 {
            var naluLen: UInt32 = 0
            memcpy(&naluLen, base + offset, 4)
            naluLen = CFSwapInt32BigToHost(naluLen)
            out.append(contentsOf: [0, 0, 0, 1])
            let start = base + offset + 4
            out.append(UnsafeRawPointer(start).assumingMemoryBound(to: UInt8.self), count: Int(naluLen))
            offset += 4 + Int(naluLen)
        }

        onEncoded?(out, isKeyframe)
    }

    private static func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return true }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        // NotSync が無い/false ならキーフレーム
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        if CFDictionaryContainsKey(dict, key) {
            let val = unsafeBitCast(CFDictionaryGetValue(dict, key), to: CFBoolean?.self)
            if let val = val { return !CFBooleanGetValue(val) }
        }
        return true
    }

    private static func parameterSets(_ fmt: CMFormatDescription, codec: Codec) -> [Data] {
        var sets: [Data] = []
        var count = 0
        // まずセット数を取得
        if codec == .h264 {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let ok: OSStatus
            if codec == .h264 {
                ok = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                ok = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            if ok == noErr, let ptr = ptr {
                sets.append(Data(bytes: ptr, count: size))
            }
        }
        return sets
    }
}
