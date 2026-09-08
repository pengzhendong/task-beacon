import AppKit
import ImageIO
import UniformTypeIdentifiers

// Export a menu-bar-specific monochrome rendering of the approved app motif.
// The status item uses white linework and real transparency for clarity at 22 pt.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift scripts/export-status-icon.swift INPUT.png OUTPUT.png")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Unable to read approved icon")
}

let width = artwork.width
let height = artwork.height
guard width == height,
      let context = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Unable to create status icon canvas")
}

let scale = CGFloat(width) / 1024
context.scaleBy(x: scale, y: scale)
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.setStrokeColor(CGColor(gray: 1, alpha: 1))
context.setFillColor(CGColor(gray: 1, alpha: 1))

// Task/window boundary.
context.setLineWidth(44)
context.addPath(CGPath(roundedRect: CGRect(x: 126, y: 126, width: 772, height: 772),
                       cornerWidth: 128, cornerHeight: 128, transform: nil))
context.strokePath()

// Agent command prompt.
context.setLineWidth(64)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: 314, y: 664))
context.addLine(to: CGPoint(x: 442, y: 536))
context.addLine(to: CGPoint(x: 314, y: 408))
context.strokePath()

// Complete progress-track boundary plus a solid half-complete fill.
context.setLineWidth(36)
context.addPath(CGPath(roundedRect: CGRect(x: 222, y: 190, width: 580, height: 120),
                       cornerWidth: 60, cornerHeight: 60, transform: nil))
context.strokePath()
context.addPath(CGPath(roundedRect: CGRect(x: 248, y: 214, width: 264, height: 72),
                       cornerWidth: 36, cornerHeight: 36, transform: nil))
context.fillPath()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Unable to export status icon")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Unable to save PNG") }
print("Exported monochrome status icon to \(output.path)")
