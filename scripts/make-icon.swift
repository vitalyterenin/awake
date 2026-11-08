import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.48, alpha: 1),
           ending: NSColor(calibratedRed: 0.055, green: 0.08, blue: 0.20, alpha: 1))!.draw(in: tile, angle: -90)
let ring = NSBezierPath()
ring.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 250, startAngle: -35, endAngle: 275)
ring.lineWidth = 45
ring.lineCapStyle = .round
NSColor(calibratedRed: 0.40, green: 0.90, blue: 0.80, alpha: 1).setStroke()
ring.stroke()
let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: 422, y: 685))
cursor.line(to: NSPoint(x: 422, y: 347))
cursor.line(to: NSPoint(x: 505, y: 424))
cursor.line(to: NSPoint(x: 566, y: 301))
cursor.line(to: NSPoint(x: 626, y: 330))
cursor.line(to: NSPoint(x: 565, y: 452))
cursor.line(to: NSPoint(x: 683, y: 452))
cursor.close()
NSColor.white.setFill()
cursor.fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
