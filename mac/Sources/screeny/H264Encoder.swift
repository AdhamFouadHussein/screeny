import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 tuned for latency. Packets are Annex-B, and the codec config is
/// sent once, ahead of the first frame.
final class H264Encoder {
    typealias Output = (_ type: UInt8, _ ptsMicros: UInt64, _ payload: Data) -> Void

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    private var session: VTCompressionSession?
    private let output: Output
    private var sentConfig = false

    init(width: Int, height: Int, fps: Int, bitrate: Int, output: @escaping Output) throws {
        self.output = output

        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw DisplayError(description: "could not create the H.264 encoder (\(status))")
        }

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 10,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(created, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
    }

    func encode(_ buffer: CVPixelBuffer) {
        guard let session else { return }
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: buffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.emit(sampleBuffer)
        }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let pts = UInt64(max(0, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds) * 1_000_000)

        if !sentConfig, let format = CMSampleBufferGetFormatDescription(sampleBuffer), let config = Self.parameterSets(format) {
            sentConfig = true
            output(0, pts, config)
        }
        guard sentConfig, let frame = Self.annexB(block) else { return }
        output(1, pts, frame)
    }

    private static func parameterSets(_ format: CMFormatDescription) -> Data? {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        ) == noErr else { return nil }

        var data = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return nil }
            data.append(contentsOf: startCode)
            data.append(pointer, count: size)
        }
        return data
    }

    /// VideoToolbox emits 4-byte length prefixes; Android wants start codes.
    private static func annexB(_ block: CMBlockBuffer) -> Data? {
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
        ) == noErr, let pointer else { return nil }

        return pointer.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
            var data = Data(capacity: length)
            var offset = 0
            while offset + 4 <= length {
                let size = (0..<4).reduce(0) { $0 << 8 | Int(bytes[offset + $1]) }
                guard offset + 4 + size <= length else { return nil }
                data.append(contentsOf: startCode)
                data.append(bytes + offset + 4, count: size)
                offset += 4 + size
            }
            return data
        }
    }
}
