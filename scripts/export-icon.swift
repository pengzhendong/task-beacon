import AppKit
import ImageIO
import UniformTypeIdentifiers

// Export the approved artwork without redrawing it. Only the outer macOS
// tile's alpha mask and resolution are prepared for the icon bundle.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift scripts/export-icon.swift INPUT.png OUTPUT.png")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(data: nil, width: 1024, height: 1024,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("Unable to read icon artwork") }

// Continuous rounded-square silhouette, matching the artwork's white tile.
// Supersampled path edges are antialiased by CoreGraphics.
let tile = CGMutablePath()
let radius = 420.0
for step in 0...1024 {
    let angle = Double(step) * 2 * Double.pi / 1024
    let c = cos(angle)
    let s = sin(angle)
    let point = CGPoint(x: 512 + radius * copysign(sqrt(abs(c)), c),
                        y: 512 + radius * copysign(sqrt(abs(s)), s))
    if step == 0 { tile.move(to: point) } else { tile.addLine(to: point) }
}
tile.closeSubpath()
context.addPath(tile)
context.clip()
context.interpolationQuality = .high
context.draw(artwork, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil)
else { fatalError("Unable to export icon") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Unable to save PNG") }
print("Exported \(output.path)")
