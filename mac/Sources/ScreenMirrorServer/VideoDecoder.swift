import Foundation
import CoreMedia
import VideoToolbox
import AVFoundation

protocol VideoDecoderDelegate: AnyObject {
    func videoDecoder(_ d: VideoDecoder, didProduceSampleBuffer sb: CMSampleBuffer)
}

final class VideoDecoder {
    weak var delegate: VideoDecoderDelegate?

    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    /// Configura el decoder a partir del payload VIDEO_CONFIG.
    func configure(spsLen: UInt32, sps: Data, ppsLen: UInt32, pps: Data) {
        self.sps = sps
        self.pps = pps
        var formatDesc: CMVideoFormatDescription?
        sps.withUnsafeBytes { (spsRaw: UnsafeRawBufferPointer) in
            pps.withUnsafeBytes { (ppsRaw: UnsafeRawBufferPointer) in
                guard let spsBase = spsRaw.baseAddress, let ppsBase = ppsRaw.baseAddress else { return }
                let parameterSetPointers: [UnsafePointer<UInt8>] = [
                    spsBase.assumingMemoryBound(to: UInt8.self),
                    ppsBase.assumingMemoryBound(to: UInt8.self),
                ]
                let parameterSetSizes: [Int] = [sps.count, pps.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc)
                if status != noErr {
                    NSLog("[VideoDecoder] CMVideoFormatDescriptionCreateFromH264ParameterSets err=%d", status)
                }
            }
        }
        self.formatDesc = formatDesc
    }

    /// Procesa un frame en Annex-B. Detecta SPS/PPS embebidos por si llegan inline.
    func decodeAnnexB(_ data: Data, pts: UInt64) {
        var spsBuf: Data?, ppsBuf: Data?
        var pictureNALUs: [Data] = []

        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let n = rawBuffer.count
            var i = 0
            while i < n {
                var sc = -1
                var scLen = 0
                var j = i
                while j + 2 < n {
                    if bytes[j] == 0 && bytes[j+1] == 0 {
                        if bytes[j+2] == 1 { sc = j; scLen = 3; break }
                        if j + 3 < n && bytes[j+2] == 0 && bytes[j+3] == 1 { sc = j; scLen = 4; break }
                    }
                    j += 1
                }
                if sc < 0 { break }
                let startPayload = sc + scLen
                var k = startPayload
                var next = -1
                while k + 2 < n {
                    if bytes[k] == 0 && bytes[k+1] == 0 && (bytes[k+2] == 1 || (k+3 < n && bytes[k+2] == 0 && bytes[k+3] == 1)) {
                        next = k; break
                    }
                    k += 1
                }
                let end = next < 0 ? n : next
                if end > startPayload {
                    let nalu = data.subdata(in: startPayload..<end)
                    let type = bytes[startPayload] & 0x1F
                    switch type {
                    case 7: spsBuf = nalu
                    case 8: ppsBuf = nalu
                    default: pictureNALUs.append(nalu)
                    }
                }
                i = end
            }
        }

        if let s = spsBuf, let p = ppsBuf {
            self.configure(spsLen: UInt32(s.count), sps: s, ppsLen: UInt32(p.count), pps: p)
        }

        guard let fmt = formatDesc else { return }

        // Construir AVCC: cada NALU prefijada por longitud de 4 bytes.
        var avcc = Data()
        for nalu in pictureNALUs {
            let len = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: len) { avcc.append(contentsOf: $0) }
            avcc.append(nalu)
        }
        if avcc.isEmpty { return }

        var blockBuffer: CMBlockBuffer?
        let avccLen = avcc.count
        let dataPtr = UnsafeMutableRawPointer.allocate(byteCount: avccLen, alignment: 1)
        avcc.copyBytes(to: dataPtr.assumingMemoryBound(to: UInt8.self), count: avccLen)
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: dataPtr, blockLength: avccLen,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avccLen,
            flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let bb = blockBuffer else {
            NSLog("[VideoDecoder] CMBlockBufferCreate err=%d", status)
            dataPtr.deallocate()
            return
        }

        let sampleSizes = [avccLen]
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000),
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: fmt,
            sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: [timing],
            sampleSizeEntryCount: 1, sampleSizeArray: sampleSizes,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sb = sampleBuffer else {
            NSLog("[VideoDecoder] CMSampleBufferCreateReady err=%d", status)
            return
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        delegate?.videoDecoder(self, didProduceSampleBuffer: sb)
    }
}
