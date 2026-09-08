import AppKit
import ImageIO
import UniformTypeIdentifiers

// Derive the menu-bar asset from the approved artwork, without redrawing it.
// The app's white tile is useful in Finder, but should let the menu bar show through.
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
let rowBytes = width * 4
guard let context = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: rowBytes,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.byteOrder32Big.rawValue),
      let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
    fatalError("Unable to create alpha mask")
}
context.draw(artwork, in: CGRect(x: 0, y: 0, width: width, height: height))

var transparentPixels = 0
for offset in stride(from: 0, to: rowBytes * height, by: 4) {
    let alpha = Double(pixels[offset + 3]) / 255
    guard alpha > 0 else {
        transparentPixels += 1
        continue
    }
    let channels = (0..<3).map { Double(pixels[offset + $0]) / 255 / alpha }
    let darkest = channels.min()!
    // Knock out white and near-white entirely; feather gray edges to avoid halos.
    // Graphite and sage-green pixels remain unchanged at full mask coverage.
    let coverage = min(1, max(0, (0.70 - darkest) / 0.15))
    let green = min(1, max(0, (min(channels[1] - channels[0], channels[1] - channels[2]) - 0.01) / 0.025))
    let mask = max(coverage * coverage * (3 - 2 * coverage), green * green * (3 - 2 * green))
    for channel in 0..<4 {
        pixels[offset + channel] = UInt8((Double(pixels[offset + channel]) * mask).rounded())
    }
    if pixels[offset + 3] == 0 { transparentPixels += 1 }
}

// White surfaces leave a few disconnected cast-shadow fragments. Keep the two
// substantive connected details (the command mark and green progress fill).
var visited = [Bool](repeating: false, count: width * height)
var components: [[Int]] = []
for seed in 0..<(width * height) where !visited[seed] && pixels[seed * 4 + 3] > 0 {
    var component = [seed]
    visited[seed] = true
    var cursor = 0
    while cursor < component.count {
        let point = component[cursor]
        cursor += 1
        let x = point % width
        let y = point / width
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nx = x + dx
            let ny = y + dy
            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
            let neighbor = ny * width + nx
            if !visited[neighbor] && pixels[neighbor * 4 + 3] > 0 {
                visited[neighbor] = true
                component.append(neighbor)
            }
        }
    }
    components.append(component)
}
components.sort { $0.count > $1.count }
guard components.count >= 2 else { fatalError("Expected command and progress components") }
for component in components.dropFirst(2) {
    for point in component {
        for channel in 0..<4 { pixels[point * 4 + channel] = 0 }
    }
}

// The status item is strictly monochrome: every retained non-white pixel is
// white, and everything removed from the white artwork stays transparent.
for point in 0..<(width * height) {
    let offset = point * 4
    let alpha = pixels[offset + 3]
    pixels[offset] = alpha
    pixels[offset + 1] = alpha
    pixels[offset + 2] = alpha
}

let kept = components.prefix(2).flatMap { $0 }
let minX = kept.map { $0 % width }.min()!
let maxX = kept.map { $0 % width }.max()!
let minY = kept.map { $0 / width }.min()!
let maxY = kept.map { $0 / width }.max()!
// Remove now-empty tile margins so the remaining mark is readable at 22 pt.
let side = min(min(width, height), Int(ceil(Double(max(maxX - minX + 1, maxY - minY + 1)) * 1.2)))
let crop = CGRect(x: max(0, min(width - side, (minX + maxX - side) / 2)),
                  y: max(0, min(height - side, (minY + maxY - side) / 2)),
                  width: side, height: side)
guard let image = context.makeImage(),
      let cropped = image.cropping(to: crop),
      let destination = CGImageDestinationCreateWithURL(output as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Unable to export status icon")
}
CGImageDestinationAddImage(destination, cropped, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Unable to save PNG") }
print("Exported \(output.path); \(transparentPixels) / \(width * height) pixels fully transparent")
