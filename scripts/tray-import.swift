#!/usr/bin/env swift
// tray-import.swift — ручная иконка из GIMP (1024² прозрачный PNG) → иконки трея macOS.
//
//   swift scripts/tray-import.swift [--crop=x,y,w,h] <icon>.png [<icon>.png ...]
//
// Для каждого входного файла <name>.png:
//   Resources/tray/src/<name>.png      — исходник (копия, в git)
//   Resources/tray/<name>.png          — 18px @1x
//   Resources/tray/<name>@2x.png       — 36px @2x
//   Resources/tray/<name>-full.png     — 1024px нормализованный, контроль
//
// --crop=x,y,w,h — оставить только этот квадрат (GIMP-координаты, ЛВ-верхний
//   канвы 1024); он вписывается в 100% иконки: развилка крупно, прямая дорога
//   и нижний отрезок отсекаются. Без кропа контент вписывается в 92%.
//
// Нормализация (форма сохраняется, правится только рамка):
//   1) [опц.] кроп — всё вне квадрата обнуляется;
//   2) чистка connected-components мельче 400px² — GIMP-крапинки;
//   3) контент вписывается в 92% канвы по центру — варианты оптически равны;
//   4) любой цвет → чёрный, альфа сохраняется (template, меню-бар перекрасит).
//
// Пиксели правятся напрямую в bitmapData собственного изменяемого канваса:
// NSBitmapImageRep из PNG неизменяем, setColor на нём молча no-op.
// 8x суперсэмплинг при ужатии — субпиксельно гладкий край.

import AppKit

let a0 = CommandLine.arguments.dropFirst()
var cropRect: NSRect? = nil
var files: [String] = []
for a in a0 {
    if a.hasPrefix("--crop=") {
        let n = a.dropFirst("--crop=".count).split(separator: ",").compactMap { Double($0) }
        guard n.count == 4, n[2] > 0, n[3] > 0 else {
            FileHandle.standardError.write("--crop=x,y,w,h (ЛВ-верхний, канва 1024)\n".data(using: .utf8)!)
            exit(2)
        }
        cropRect = NSRect(x: n[0], y: n[1], width: n[2], height: n[3])
    } else { files.append(a) }
}
guard !files.isEmpty else {
    FileHandle.standardError.write("usage: tray-import.swift [--crop=x,y,w,h] <icon>.png [...]\n".data(using: .utf8)!)
    exit(2)
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = repo.appendingPathComponent("Resources/tray")
let srcDir = outDir.appendingPathComponent("src")
try! FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

let A = 3   // смещение альфы в premultiplied RGBA-байте

func canvas(_ dim: Int) -> NSBitmapImageRep {
    let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dim, pixelsHigh: dim,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
    // очистить: new-канвас не гарантированно занулён
    memset(r.bitmapData, 0, r.bytesPerRow * dim)
    return r
}
// нарисовать rep на чистом канвасе того же размера → изменяемая копия
func mutableCopy(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
    let out = canvas(rep.pixelsWide)
    let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    img.addRepresentation(rep)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    img.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    NSGraphicsContext.restoreGraphicsState()
    return out
}

let alphaThresh: UInt8 = 12   // ~0.05

for arg in files {
    let inURL = URL(fileURLWithPath: arg)
    let name = inURL.deletingPathExtension().lastPathComponent

    // GIMP пишет PNG в своём профиле — прибиваем к sRGB, иначе NSBitmap гукает
    let srgb = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ti-\(UUID().uuidString).png")
    let sips = Process()
    sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    sips.arguments = ["--matchTo", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", inURL.path, "--out", srgb.path]
    sips.standardOutput = FileHandle.nullDevice; sips.standardError = FileHandle.nullDevice
    try? sips.run(); sips.waitUntilExit()
    let loadURL = FileManager.default.fileExists(atPath: srgb.path) ? srgb : inURL
    defer { try? FileManager.default.removeItem(at: srgb) }
    guard let data = try? Data(contentsOf: loadURL), let raw = NSBitmapImageRep(data: data) else {
        FileHandle.standardError.write("не читается: \(arg)\n".data(using: .utf8)!); exit(1)
    }

    // исходник в git (если кладут не из src/)
    let srcCopy = srcDir.appendingPathComponent(inURL.lastPathComponent)
    if srcCopy.path != inURL.path {
        try? FileManager.default.removeItem(at: srcCopy)
        try! FileManager.default.copyItem(at: inURL, to: srcCopy)
    }

    let rep = mutableCopy(raw)
    let W = rep.pixelsWide, H = rep.pixelsHigh
    let bpr = rep.bytesPerRow
    guard let px = rep.bitmapData else { FileHandle.standardError.write("нет bitmapData\n".data(using: .utf8)!); exit(1) }
    func al(_ x: Int, _ y: Int) -> UInt8 { px[y * bpr + x * 4 + A] }
    func zero(_ x: Int, _ y: Int) { let o = y * bpr + x * 4; px[o] = 0; px[o+1] = 0; px[o+2] = 0; px[o+3] = 0 }

    // 1) кроп: обнулить всё вне квадрата
    if let c = cropRect {
        let x0 = max(0, Int(c.minX.rounded())), x1 = min(W, Int(c.maxX.rounded()))
        let y0 = max(0, Int(c.minY.rounded())), y1 = min(H, Int(c.maxY.rounded()))
        var cut = 0
        for y in 0..<H { for x in 0..<W {
            if (x < x0 || x >= x1 || y < y0 || y >= y1), al(x, y) > 0 { zero(x, y); cut += 1 }
        } }
        print("\(name): кроп \(x1-x0)×\(y1-y0)@(\(x0),\(y0)) — убрано \(cut)px")
    }

    // 2) connected-components: убрать крапинки мельче 400px²
    let n = W * H
    let mask = UnsafeMutablePointer<UInt8>.allocate(capacity: n); defer { mask.deallocate() }
    let comp = UnsafeMutablePointer<Int32>.allocate(capacity: n); defer { comp.deallocate() }
    for i in 0..<n { mask[i] = 0; comp[i] = -1 }
    for y in 0..<H { for x in 0..<W { mask[y * W + x] = al(x, y) > alphaThresh ? 1 : 0 } }
    var sizes: [Int] = []; var stack: [Int] = []
    for i in 0..<n where mask[i] == 1 && comp[i] == -1 {
        let id = sizes.count; var sz = 0
        stack.removeAll(keepingCapacity: true); stack.append(i); comp[i] = Int32(id)
        while let p = stack.popLast() {
            sz += 1; let cx = p % W, cy = p / W
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = cx + dx, ny = cy + dy
                guard nx >= 0, nx < W, ny >= 0, ny < H else { continue }
                let q = ny * W + nx
                if mask[q] == 1 && comp[q] == -1 { comp[q] = Int32(id); stack.append(q) }
            } }
        }
        sizes.append(sz)
    }
    var removed = 0
    for i in 0..<n where mask[i] == 1 && sizes[Int(comp[i])] < 400 {
        zero(i % W, i / W); removed += 1
    }
    if removed > 0 { print("\(name): вычищено шумов \(removed)px") }

    // 3) bbox контента
    var minX = W, maxX = -1, minY = H, maxY = -1
    for y in 0..<H { for x in 0..<W where al(x, y) > alphaThresh {
        if x < minX { minX = x }; if x > maxX { maxX = x }
        if y < minY { minY = y }; if y > maxY { maxY = y }
    } }
    guard maxX >= minX else { FileHandle.standardError.write("пустой: \(arg)\n".data(using: .utf8)!); exit(1) }
    let contentBBox = NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)

    // 4) нормализовать в 1024: по центру, чёрный. С кропом квадрат заполняет
    //    канву на 100% (развилка крупно), без кропа — 92% (оптический запас).
    //    Рамка вписывания — сам квадрат кропа, а не tight bbox: все три варианта
    //    одного масштаба и не «пляшут» в тре при смене состояния.
    let side = 1024.0
    let fitBox = cropRect ?? contentBBox
    let fillRatio = cropRect != nil ? 1.0 : 0.92
    let fit = (side * fillRatio) / max(Double(fitBox.width), Double(fitBox.height))
    let dw = Double(fitBox.width) * fit, dh = Double(fitBox.height) * fit
    let norm = canvas(1024)
    let normCtx = NSGraphicsContext(bitmapImageRep: norm)!
    let srcImg = NSImage(size: NSSize(width: W, height: H)); srcImg.addRepresentation(rep)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = normCtx
    let fromRect = NSRect(x: fitBox.minX, y: Double(H) - Double(fitBox.maxY),
                          width: fitBox.width, height: fitBox.height)
    srcImg.draw(in: NSRect(x: (side - dw) / 2, y: (side - dh) / 2, width: dw, height: dh),
                from: fromRect, operation: .copy, fraction: 1.0, respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high.rawValue])
    NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()

    func downscale(_ out: Int, to url: URL) {
        let ss = out * 8
        let big = canvas(ss)
        let normImg = NSImage(size: NSSize(width: 1024, height: 1024)); normImg.addRepresentation(norm)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: big)
        normImg.draw(in: NSRect(x: 0, y: 0, width: ss, height: ss), from: .zero,
                     operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        let fin = canvas(out)
        let bigImg = NSImage(size: NSSize(width: ss, height: ss)); bigImg.addRepresentation(big)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: fin)
        bigImg.draw(in: NSRect(x: 0, y: 0, width: out, height: out), from: .zero,
                    operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        try! fin.representation(using: .png, properties: [:])!.write(to: url)
    }
    try! norm.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("\(name)-full.png"))
    downscale(18, to: outDir.appendingPathComponent("\(name).png"))
    downscale(36, to: outDir.appendingPathComponent("\(name)@2x.png"))
    print("\(name): контент \(Int(contentBBox.width))×\(Int(contentBBox.height)) → 18/36 ✓")
}
print("готово → Resources/tray/  (в бандл кладёт build-app.sh)")
