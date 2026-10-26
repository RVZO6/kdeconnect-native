import AppKit
let img = NSImage(contentsOfFile: CommandLine.arguments[1])!
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let W = rep.pixelsWide, H = rep.pixelsHigh
func a(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)!.alphaComponent }
print("size", W, H)
// first opaque (alpha>=0.5) x on several rows
for y in [0,1,2,5,10,20,40,60,80,100,120,150,180,200,230,260,300,400,512] {
  var fx = -1; for x in 0..<W { if a(x,y) >= 0.5 { fx = x; break } }
  print("row", y, "firstx", fx)
}
// diagonal
var d = -1; for i in 0..<W { if a(i,i) >= 0.5 { d = i; break } }
print("diag", d)
// first opaque y at middle column
var my = -1; for y in 0..<H { if a(W/2,y) >= 0.5 { my = y; break } }
print("midcol firsty", my)
