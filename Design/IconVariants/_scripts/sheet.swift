// Usage: swift sheet.swift <out.png> <cols> <tile> <img1> [img2 ...]
import AppKit

let args = CommandLine.arguments
let out = args[1]
let cols = Int(args[2])!
let tile = CGFloat(Int(args[3])!)
let files = Array(args.dropFirst(4))
let pad: CGFloat = 24, labelH: CGFloat = 34
let rows = (files.count + cols - 1) / cols
let W = Int(CGFloat(cols) * (tile + pad) + pad)
let H = Int(CGFloat(rows) * (tile + labelH + pad) + pad)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = gc

let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: tile > 300 ? 20 : 15, weight: .semibold),
    .foregroundColor: NSColor.white,
]
for (i, f) in files.enumerated() {
    let c = i % cols, r = i / cols
    let x = pad + CGFloat(c) * (tile + pad)
    let yTop = pad + CGFloat(r) * (tile + labelH + pad)
    let y = CGFloat(H) - yTop - tile
    if let img = NSImage(contentsOfFile: f), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        ctx.draw(cg, in: CGRect(x: x, y: y, width: tile, height: tile))
    }
    var name = (f as NSString).lastPathComponent
    name = name.replacingOccurrences(of: "-default.png", with: "").replacingOccurrences(of: "-dark.png", with: "").replacingOccurrences(of: "-actool.png", with: " (actool)").replacingOccurrences(of: ".png", with: "")
    let s = NSAttributedString(string: name, attributes: attrs)
    let sz = s.size()
    s.draw(at: NSPoint(x: x + (tile - sz.width) / 2, y: y - labelH + 6))
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote", out, W, H)
