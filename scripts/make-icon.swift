#!/usr/bin/env swift
// make-icon.swift — squircle-маска по официальной сетке Apple и сборка AppIcon.icns
//
//   swift scripts/make-icon.swift path/to/src.png [--inset] [--shave 8]
//
// Apple иконки — НЕ скруглённые прямоугольники, а squircle (непрерывная
// кривизна, суперэллипс): corner-отношение 0.2237 от стороны, экспонента
// 5.28. Те же констаны в iOS-сетке и в macOS Big Sur-сетке (824 в 1024:
// 185/824 = 0.2245 — одно и то же).
//
// По умолчанию: картинка на всю холстину (full-bleed), углы отрезаются
// маской начисто — прозрачная альфа. --inset: контент вписывается в 824
// в канве 1024 (официальный отступ macOS-сетки).
//
// Выход: Resources/AppIcon.iconset/*.png (перемаскивается на КАЖДЫЙ
// размер — антиалиасинг корректный на 16px) + Resources/AppIcon.icns.

import AppKit

let args = CommandLine.arguments
guard args.count >= 2, FileManager.default.fileExists(atPath: args[1]) else {
    FileHandle.standardError.write("usage: make-icon.swift src.png [--inset]\n".data(using: .utf8)!)
    exit(2)
}
let src = URL(fileURLWithPath: args[1])
let inset = args.contains("--inset")

let canvas = 1024.0
let side = inset ? 824.0 : 1024.0          // сторона artwork на холстине
let ratio = 0.2237                          // corner/сторона (Apple squircle)
var exponent = 5.28                         // суперэллипс

// --shave N: отъесть N пикселей наискосок (в самой толстой точке угла),
// стороны остаются касательными к краю — суперэллипс касается середины
// стороны всегда, меняется только «подъём» угла:
// D = √2·a·0.5^(1/n) — расстояние от центра до угла на диагонали;
// решаем n под D' = D − shave
if let i = args.firstIndex(of: "--shave"), i + 1 < args.count,
   let shave = Double(args[i + 1]) {
    let a = side / 2
    let d = 2.0.squareRoot() * a * pow(0.5, 1.0 / exponent)
    let target = (d - shave) / (2.0.squareRoot() * a)
    exponent = log(0.5) / log(target)
}

// --rim PX: симметричный отступ маски по всему периметру — срезает
// нарисованный светлый кант artwork и полупрозрачный пиксель AA-края
var rim = 0.0
if let i = args.firstIndex(of: "--rim"), i + 1 < args.count, let v = Double(args[i + 1]) {
    rim = v
}

/// точка суперэллипса: |x/a|^n + |y/b|^n = 1 в параметрической форме
func superellipsePoint(_ t: Double, _ cx: Double, _ cy: Double,
                       _ rx: Double, _ ry: Double, _ n: Double) -> NSPoint {
    let ct = cos(t), st = sin(t)
    func f(_ u: Double) -> Double { (u < 0 ? -1 : 1) * pow(abs(u), 2.0 / n) }
    return NSPoint(x: cx + rx * f(ct), y: cy + ry * f(st))
}

func squirclePath(_ side: CGFloat, _ origin: CGPoint) -> NSBezierPath {
    let cx = origin.x + side / 2, cy = origin.y + side / 2
    let r = side / 2, n = exponent
    let p = NSBezierPath()
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let pt = superellipsePoint(t, Double(cx), Double(cy), Double(r), Double(r), n)
        if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
    }
    p.close()
    return p
}

/// отрисовать src в канву px с 4x суперсэмплингом; обрезать squircle-маской
/// (на rim меньше канвы); PNG с альфой на выход.
/// Суперсэмплинг принципиален: маска растеризуется на 4096 и ужимается с
/// интерполяцией — край субпиксельно гладкий на любом размере. Родной
/// raster-clip на 16px даёт зазубрины и белый кант (видели в доке).
func render(_ px: Int, to out: URL) {
    guard let img = NSImage(contentsOf: src) else {
        FileHandle.standardError.write("не читается: \(src.path)\n".data(using: .utf8)!)
        exit(1)
    }
    func canvasRep(_ dim: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dim, pixelsHigh: dim,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                        isPlanar: false, colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 0)!
    }
    let ss = px * 4
    let big = canvasRep(ss)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: big)
    let scale = Double(ss) / canvas
    let sidePx = side * scale
    let origin = (Double(ss) - sidePx) / 2
    // контент — в прежнем прямоугольнике (side×side по центру); маска —
    // на rim меньше: только тогда кант artwork РЕЖЕТСЯ, а не уезжает внутрь
    let mSidePx = (side - rim * 2) * scale
    let mOrigin = (Double(ss) - mSidePx) / 2
    squirclePath(CGFloat(mSidePx), CGPoint(x: CGFloat(mOrigin), y: CGFloat(mOrigin))).addClip()
    img.draw(in: NSRect(x: origin, y: origin, width: sidePx, height: sidePx),
             from: .zero, operation: .sourceOver, fraction: 1.0,
             respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSGraphicsContext.restoreGraphicsState()

    // даунсэмпл в финальный размер — гладкий субпиксельный край
    let rep = canvasRep(px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    big.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero,
             operation: .copy, fraction: 1.0, respectFlipped: false,
             hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out)
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = repo.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    render(px, to: iconset.appendingPathComponent(name))
}
// превью full-size для ручного контроля
render(1024, to: repo.appendingPathComponent("Resources/AppIcon-1024.png"))

let icns = repo.appendingPathComponent("Resources/AppIcon.icns")
try? FileManager.default.removeItem(at: icns)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("AppIcon.icns готов (\(inset ? "inset 824" : "full-bleed"), squircle \(ratio), n=\(exponent))")
