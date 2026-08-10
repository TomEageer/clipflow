import AppKit
import Foundation

// 程序化生成图标：无外部素材，零版权问题，可商用。
// 母题 = 剪贴板 + 层叠的历史条目（Clipflow 的核心：不是一张纸，是一叠流动的记录）

func makeIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size

    // macOS 图标的标准安全区：内容占 ~80%，四周留白
    let inset = s * 0.10
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = rect.width * 0.2237   // Big Sur 圆角比例

    // 底板：深靛蓝到青的渐变，冷色显得像系统工具而非玩具
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.44, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.10, green: 0.44, blue: 0.62, alpha: 1).cgColor,
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()

    // 顶部高光，模拟 macOS 图标的材质感
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.10).cgColor)
    ctx.fill(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2))
    ctx.restoreGState()

    // 三层"卡片"，越往后越淡越窄 —— 表达"历史记录一叠"
    let cardW = rect.width * 0.52
    let cardH = rect.height * 0.44
    let cx = rect.midX
    let baseY = rect.minY + rect.height * 0.26
    for i in (0..<3).reversed() {
        let shrink = CGFloat(i) * cardW * 0.09
        let r = CGRect(x: cx - (cardW - shrink) / 2,
                       y: baseY + CGFloat(i) * cardH * 0.20,
                       width: cardW - shrink,
                       height: cardH)
        let cr = r.width * 0.14
        let p = CGPath(roundedRect: r, cornerWidth: cr, cornerHeight: cr, transform: nil)
        ctx.addPath(p)
        ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: i == 0 ? 0.97 : (i == 1 ? 0.42 : 0.20)).cgColor)
        ctx.fillPath()
    }

    // 最前面那张卡片上画三条"文本行"，最后一条短 —— 一眼看出是内容不是空白纸
    let front = CGRect(x: cx - cardW / 2, y: baseY, width: cardW, height: cardH)
    ctx.setFillColor(NSColor(calibratedRed: 0.13, green: 0.30, blue: 0.52, alpha: 0.85).cgColor)
    let lineH = front.height * 0.085
    let padX = front.width * 0.16
    for (i, wRatio) in [0.68, 0.68, 0.40].enumerated() {
        let y = front.maxY - front.height * (0.30 + Double(i) * 0.22)
        let r = CGRect(x: front.minX + padX, y: y,
                       width: front.width * wRatio, height: lineH)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
        ctx.fillPath()
    }

    // 顶部夹子：剪贴板的识别符号
    let clipW = cardW * 0.42, clipH = cardH * 0.20
    let clipR = CGRect(x: cx - clipW / 2, y: front.maxY - clipH * 0.45, width: clipW, height: clipH)
    ctx.addPath(CGPath(roundedRect: clipR, cornerWidth: clipH * 0.35, cornerHeight: clipH * 0.35, transform: nil))
    ctx.setFillColor(NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.20, alpha: 1).cgColor)
    ctx.fillPath()

    img.unlockFocus()
    return img
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets"
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let specs: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in specs {
    let img = makeIcon(size: CGFloat(px))
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
// 单独导一张 1024 给 README 用
if let tiff = makeIcon(size: 1024).tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/icon_1024.png"))
}
print("iconset 生成完毕：\(iconset)")
