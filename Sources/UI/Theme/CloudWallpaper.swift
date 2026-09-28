import AppKit
import SwiftUI

/// The pane's backdrop: a teal sky with cream pixel-textured clouds along the bottom. Drawn
/// in a 1600 × 1000 space and scaled to fill (cropping, like `preserveAspectRatio slice`).
/// It stays bright in dark mode too: only the cards on top are dark.
struct CloudWallpaper: View {
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let scale = max(size.width / 1600, size.height / 1000)
            context.translateBy(x: (size.width - 1600 * scale) / 2, y: (size.height - 1000 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            Self.draw(in: &context)
        }
        .accessibilityHidden(true)
    }

    private static func draw(in context: inout GraphicsContext) {
        let canvas = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        context.fill(Path(canvas), with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(rgb: 0x718B8E), location: 0),
                .init(color: Color(rgb: 0xA4B9B7), location: 0.52),
                .init(color: Color(rgb: 0x557B7D), location: 1),
            ]),
            startPoint: .zero, endPoint: CGPoint(x: 320, y: 1000)
        ))
        context.fill(Path(canvas), with: .tiledImage(skyPixels))

        // Far cloud, half transparent.
        var far = context
        far.opacity = 0.5
        far.drawLayer { layer in
            let shape = union(rect: CGRect(x: 1115, y: 720, width: 570, height: 310),
                              circles: [(1168, 733, 73), (1257, 687, 83), (1356, 731, 91), (1476, 662, 105)])
            layer.fill(shape, with: .color(Color(rgb: 0xE3D6AE)))
            layer.clip(to: shape)
            layer.fill(Path(canvas), with: .tiledImage(cloudPixels))
        }

        cloud(in: &context, bounds: CGRect(x: 0, y: 430, width: 700, height: 570), texture: 0.8,
              shape: union(rect: CGRect(x: -80, y: 675, width: 750, height: 400),
                           circles: [(-12, 639, 132), (132, 573, 125), (257, 636, 121), (372, 698, 137), (515, 767, 118), (72, 828, 190)]))
        cloud(in: &context, bounds: CGRect(x: 540, y: 660, width: 1000, height: 340), texture: 0.72,
              shape: union(rect: CGRect(x: 575, y: 835, width: 925, height: 180),
                           circles: [(642, 820, 99), (760, 769, 90), (860, 795, 82), (936, 856, 104), (1111, 923, 98), (1230, 899, 86)]))
    }

    private static func cloud(in context: inout GraphicsContext, bounds: CGRect, texture: Double, shape: Path) {
        var layer = context
        layer.clip(to: shape)
        layer.fill(Path(bounds), with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(rgb: 0xF1DFB7), location: 0),
                .init(color: Color(rgb: 0xDBC49A), location: 0.65),
                .init(color: Color(rgb: 0xBFAE88), location: 1),
            ]),
            startPoint: bounds.origin,
            endPoint: CGPoint(x: bounds.minX + bounds.width * 0.2, y: bounds.maxY)
        ))
        layer.opacity = texture
        layer.fill(Path(bounds), with: .tiledImage(cloudPixels))
    }

    /// One outline for a cloud: its base rectangle plus its puffs.
    private static func union(rect: CGRect, circles: [(CGFloat, CGFloat, CGFloat)]) -> Path {
        circles.reduce(Path(rect)) { shape, circle in
            let (x, y, r) = circle
            return shape.union(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)))
        }
    }

    // MARK: Pixel textures (tiles from the concept's SVG patterns)

    private static let skyPixels = tile(size: 23, pixels: [
        (2, 4, 2, 2, 0xE5D4AC, 0.18), (15, 9, 3, 2, 0x284D56, 0.12), (7, 17, 2, 3, 0xE9D7AC, 0.11),
    ])

    private static let cloudPixels = tile(size: 19, pixels: [
        (1, 2, 3, 2, 0x496F72, 0.46), (8, 1, 2, 4, 0x607D76, 0.33), (14, 5, 3, 2, 0x426568, 0.36),
        (4, 10, 2, 3, 0x486966, 0.38), (11, 13, 4, 2, 0x71817A, 0.4), (17, 16, 2, 2, 0x4E6F6D, 0.4),
    ])

    private static func tile(size: Int, pixels: [(Int, Int, Int, Int, Int, Double)]) -> Image {
        let scale = 2
        guard let bitmap = CGContext(
            data: nil, width: size * scale, height: size * scale, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Image(nsImage: NSImage()) }
        bitmap.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        for (x, y, w, h, rgb, alpha) in pixels {
            bitmap.setFillColor(CGColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha))
            // Core Graphics counts y from the bottom.
            bitmap.fill(CGRect(x: x, y: size - y - h, width: w, height: h))
        }
        guard let image = bitmap.makeImage() else { return Image(nsImage: NSImage()) }
        return Image(decorative: image, scale: CGFloat(scale))
    }
}
