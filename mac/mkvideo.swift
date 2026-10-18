// Makes a few short H.264 clips so Photos has Videos for the Videos media type.
//
//   swiftc -swift-version 5 -O -o mkvideo mkvideo.swift && ./mkvideo <out-dir> [count]
//
// Each clip is two seconds of a colour sweep. Failure is not fatal: mac-tour.sh carries on without videos.
import AVFoundation
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "videos")
let clipCount = max(0, args.count > 2 ? (Int(args[2]) ?? 3) : 3)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func makeClip(_ url: URL, hue: Double) -> Bool {
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
    let width = 640, height = 480
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    guard writer.canAdd(input) else { return false }
    writer.add(input)
    guard writer.startWriting() else { return false }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<48 {
        var waited = 0
        while !input.isReadyForMoreMediaData && waited < 500 { Thread.sleep(forTimeInterval: 0.01); waited += 1 }
        guard let pool = adaptor.pixelBufferPool else { return false }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pixels = buffer else { return false }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
            let t = Double(frame) / 48.0
            context.setFillColor(CGColor(srgbRed: CGFloat((hue + t * 0.4).truncatingRemainder(dividingBy: 1)),
                                         green: CGFloat(0.3 + 0.5 * t), blue: CGFloat(0.8 - 0.5 * t), alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
            context.fill(CGRect(x: 40 + t * 480, y: 180, width: 80, height: 120))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        if !adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) { return false }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    return writer.status == .completed
}

var made = 0
for index in 1...max(1, clipCount) where clipCount > 0 {
    let url = outDir.appendingPathComponent(String(format: "TOUR_CLIP_%02ld.mp4", index))
    if makeClip(url, hue: Double(index) * 0.27) {
        // Photos dates a clip by its file dates, so spread them over three days.
        let date = Date(timeIntervalSinceNow: -Double(index) * 86400 * 9)
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        made += 1
    } else {
        print("clip \(index) failed")
    }
}
print("made \(made) clips in \(outDir.path)")
