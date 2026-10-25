// 產生 App 圖標：swift scripts/make_icon.swift <輸出的 .icns 路徑>
// 圖案是藍紫漸層的圓角方塊，中間一個人的剪影，右下角有綠色的「＋」徽章（建立使用者）。
import AppKit

func drawIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels) / 1024
    // 以 1024 的座標系作畫，macOS 圖標的主體是 824 見方，四周留白放陰影
    let art = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let body = NSBezierPath(roundedRect: art, xRadius: 185 * s, yRadius: 185 * s)

    // 陰影
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    NSColor(calibratedRed: 0.24, green: 0.29, blue: 0.86, alpha: 1).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 漸層底色
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.58, blue: 0.97, alpha: 1),
        NSColor(calibratedRed: 0.27, green: 0.25, blue: 0.84, alpha: 1),
    ])!.draw(in: art, angle: -90)
    // 上緣一道淡淡的高光
    NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
        .draw(in: NSRect(x: art.minX, y: art.midY, width: art.width, height: art.height / 2), angle: -90)

    // 人的剪影：頭 + 平底的肩膀，整體略偏左上，讓出右下角給徽章
    NSColor.white.setFill()
    let headR = 108 * s
    NSBezierPath(ovalIn: NSRect(x: 455 * s - headR, y: 590 * s - headR, width: headR * 2, height: headR * 2)).fill()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: 0, y: 232 * s, width: 1024 * s, height: 400 * s)).addClip()
    NSBezierPath(ovalIn: NSRect(x: 455 * s - 185 * s, y: 232 * s - 230 * s, width: 370 * s, height: 460 * s)).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    // 右下角的綠色「＋」徽章
    let center = NSPoint(x: 735 * s, y: 285 * s)
    let radius = 125 * s
    NSGraphicsContext.saveGraphicsState()
    let badgeShadow = NSShadow()
    badgeShadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    badgeShadow.shadowBlurRadius = 14 * s
    badgeShadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    badgeShadow.set()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - radius - 14 * s, y: center.y - radius - 14 * s,
                                width: (radius + 14 * s) * 2, height: (radius + 14 * s) * 2)).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.40, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
    NSColor.white.setFill()
    let arm = 20 * s, length = 120 * s
    NSBezierPath(roundedRect: NSRect(x: center.x - length / 2, y: center.y - arm, width: length, height: arm * 2),
                 xRadius: arm, yRadius: arm).fill()
    NSBezierPath(roundedRect: NSRect(x: center.x - arm, y: center.y - length / 2, width: arm * 2, height: length),
                 xRadius: arm, yRadius: arm).fill()

    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("用法: swift make_icon.swift <輸出的 .icns 路徑>\n".utf8))
    exit(2)
}
let output = CommandLine.arguments[1]
let iconset = NSTemporaryDirectory() + "UserForge-\(UUID().uuidString).iconset"
try FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(atPath: iconset) }

// (檔名, 像素)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    try drawIcon(pixels: pixels).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", output]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
