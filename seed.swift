// Makes dated, located test photos for the Photos tour, so Years, Months, Days, Places and the screenshot
// filter have something real to show. No downloads and no extra tools: CoreGraphics draws, ImageIO writes EXIF.
//
//   swift seed.swift <out-dir> [events]
//
// Each "event" is one day, 47 days after the last, starting January 2022 (30 events reach late 2025), with
// 6 to 10 photos a few minutes apart, mostly portrait, at one of four places. Event photo 1 is followed by
// two near-identical frames (Days hides near-duplicates), and every fourth event adds a screenshot.
import CoreGraphics
import CoreText
import Foundation
import ImageIO

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "seed")
let events = max(0, args.count > 2 ? (Int(args[2]) ?? 30) : 30)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let places: [(name: String, lat: Double, lon: Double)] = [
    ("Oxford", 51.7520, -1.2577), ("Cardiff", 51.4816, -3.1791),
    ("Barcelona", 41.3874, 2.1686), ("London", 51.5072, -0.1276)]

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Europe/London")!
let start = calendar.date(from: DateComponents(year: 2022, month: 1, day: 8, hour: 10, minute: 5))!

func formatter(_ pattern: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = calendar.timeZone
    f.dateFormat = pattern
    return f
}
let exifStamp = formatter("yyyy:MM:dd HH:mm:ss")
let caption = formatter("d MMM yyyy HH:mm")

func offset(_ date: Date) -> String {
    let seconds = calendar.timeZone.secondsFromGMT(for: date)
    return (seconds >= 0 ? "+" : "-") + String(format: "%02ld:%02ld", abs(seconds) / 3600, (abs(seconds) % 3600) / 60)
}

func hsb(_ h: Double, _ s: Double, _ v: Double) -> CGColor {
    let v = max(0, min(1, v))
    let h6 = (h - floor(h)) * 6
    let i = Int(h6) % 6
    let f = h6 - Double(Int(h6))
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    let rgb: [(Double, Double, Double)] = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)]
    let (r, g, b) = rgb[i]
    return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

func draw(width: Int, height: Int, hue: Double, shade: Double, text: String) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let colours = [hsb(hue, 0.55, 0.95 - shade), hsb(hue + 0.12, 0.75, 0.55 - shade / 2)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    let w = CGFloat(width), h = CGFloat(height)
    ctx.setFillColor(hsb(hue + 0.5, 0.45, 0.92))
    ctx.fillEllipse(in: CGRect(x: w * 0.18, y: h * 0.35, width: w * 0.36, height: w * 0.36))
    ctx.setFillColor(hsb(hue + 0.3, 0.6, 0.35))
    ctx.fill(CGRect(x: w * 0.55, y: h * 0.15, width: w * 0.3, height: h * 0.25))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, w / 14, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.95)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
    ctx.textPosition = CGPoint(x: w / 16, y: h / 12)
    CTLineDraw(line, ctx)
    return ctx.makeImage()!
}

// `type` is a UTI string ("public.jpeg", "public.png"); UTType would need macOS 11 as the script's deployment target.
func write(_ image: CGImage, to url: URL, type: String, date: Date, place: (name: String, lat: Double, lon: Double)?,
           screenshot: Bool) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    let stamp = exifStamp.string(from: date)
    var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: stamp,
                                 kCGImagePropertyExifDateTimeDigitized: stamp,
                                 kCGImagePropertyExifOffsetTimeOriginal: offset(date)]
    if screenshot { exif[kCGImagePropertyExifUserComment] = "Screenshot" }
    var tiff: [CFString: Any] = [kCGImagePropertyTIFFDateTime: stamp]
    if !screenshot {
        tiff[kCGImagePropertyTIFFMake] = "Apple"
        tiff[kCGImagePropertyTIFFModel] = "iPhone 15 Pro"
    }
    var properties: [CFString: Any] = [kCGImagePropertyExifDictionary: exif,
                                       kCGImagePropertyTIFFDictionary: tiff,
                                       kCGImageDestinationLossyCompressionQuality: 0.82]
    if let place = place, !screenshot {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(place.lat), kCGImagePropertyGPSLatitudeRef: place.lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(place.lon), kCGImagePropertyGPSLongitudeRef: place.lon >= 0 ? "E" : "W"]
        properties[kCGImagePropertyGPSDictionary] = gps
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot finish \(url.path)") }
}

var made = 0
for e in 0..<events {
    let day = calendar.date(byAdding: .day, value: e * 47, to: start)!
    let place = places[e % places.count]
    let hue = Double((e * 37) % 100) / 100
    let count = 6 + (e % 5)
    for k in 0..<count {
        let date = calendar.date(byAdding: .minute, value: k * 9, to: day)!
        let portrait = k % 4 != 3
        let (w, h) = portrait ? (1512, 2016) : (2016, 1512)
        let text = "\(place.name)  \(caption.string(from: date))"
        let image = draw(width: w, height: h, hue: hue + Double(k) * 0.03, shade: Double(k % 3) * 0.08, text: text)
        let name = String(format: "TOUR_%03ld_%02ld.JPG", e, k)
        write(image, to: out.appendingPathComponent(name), type: "public.jpeg", date: date, place: place, screenshot: false)
        made += 1
        if k == 1 {
            for b in 1...2 {
                let burst = calendar.date(byAdding: .second, value: b, to: date)!
                let near = draw(width: w, height: h, hue: hue + Double(k) * 0.03, shade: Double(k % 3) * 0.08 + Double(b) * 0.01,
                                text: text)
                write(near, to: out.appendingPathComponent(String(format: "TOUR_%03ld_%02ld_B%ld.JPG", e, k, b)),
                      type: "public.jpeg", date: burst, place: place, screenshot: false)
                made += 1
            }
        }
    }
    if e % 4 == 0 {
        let date = calendar.date(byAdding: .hour, value: 6, to: day)!
        let shot = draw(width: 1179, height: 2556, hue: 0.6, shade: 0.3, text: "Screenshot \(caption.string(from: date))")
        write(shot, to: out.appendingPathComponent(String(format: "TOUR_SHOT_%03ld.PNG", e)), type: "public.png", date: date,
              place: nil, screenshot: true)
        made += 1
    }
}
print("made \(made) images in \(out.path)")
