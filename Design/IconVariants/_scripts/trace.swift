// Trace the tile edge (alpha 0.5) of a 1024px render; write an SVG path inset by INSET px.
import AppKit
let img = NSImage(contentsOfFile: CommandLine.arguments[1])!
let inset = Double(CommandLine.arguments[3])!
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let W = rep.pixelsWide
func a(_ x: Double, _ y: Double) -> Double {
  let xi = min(max(Int(x), 0), W-1), yi = min(max(Int(y), 0), W-1)
  return Double(rep.colorAt(x: xi, y: yi)!.alphaComponent)
}
let c = Double(W) / 2.0
var quarter: [(Double, Double)] = []   // angle 0 = right, going to 90 = down (y-down)
let steps = 720
for i in 0...steps {
  let t = Double(i) / Double(steps) * Double.pi / 2
  let dx = cos(t), dy = sin(t)
  var lo = 0.0, hi = c * 1.5
  // find edge: largest r with alpha >= 0.5 (pixel centres)
  var r = 0.0
  while r < hi { let x = c + dx * r, y = c + dy * r
    if x < 0 || y < 0 || x >= Double(W) || y >= Double(W) || a(x, y) < 0.5 { break }; r += 1 }
  lo = r - 1; hi = r
  // refine with alpha interpolation between lo and hi
  let al = a(c + dx*lo, c + dy*lo), ah = (c+dx*hi < Double(W) && c+dy*hi < Double(W)) ? a(c + dx*hi, c + dy*hi) : 0
  let f = al == ah ? 0 : (al - 0.5) / (al - ah)
  let edge = lo + f + 0.5 - inset
  quarter.append((dx * edge, dy * edge))
}
var pts: [(Double, Double)] = []
for (x, y) in quarter { pts.append((x, y)) }                       // bottom-right
for (x, y) in quarter.reversed() { pts.append((-x, y)) }           // bottom-left
for (x, y) in quarter { pts.append((-x, -y)) }                     // top-left
for (x, y) in quarter.reversed() { pts.append((x, -y)) }           // top-right
var d = ""
var last = ""
for (i, (x, y)) in pts.enumerated() {
  let s = String(format: "%.1f %.1f", c + x, c + y)
  if s == last { continue }; last = s
  d += (i == 0 ? "M " : " L ") + s
}
d += " Z"
try! d.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
print("points", pts.count, "edge at 0deg", quarter[0].0 + c, "at 45deg", c + quarter[steps/2].0)
