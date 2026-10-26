import AppKit
import LidAwakeCore
import SwiftUI

/// The mode shapes, drawn on a 24 × 24 grid with y pointing down.
enum ModeIcon {
    struct Glyph {
        let filled: CGPath
        let stroked: CGPath
    }

    static let gridSize: CGFloat = 24
    static let strokeStyle = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
    static let awakeColor = NSColor(srgbRed: 0.62745, green: 0.51765, blue: 0.90980, alpha: 1)

    static func glyph(for mode: Mode) -> Glyph {
        switch mode {
        case .off: return Glyph(filled: CGMutablePath(), stroked: combined(screen, stand))
        case .keepScreenOn: return Glyph(filled: screen, stroked: combined(screen, stand))
        case .lidClosed: return Glyph(filled: awakeBolt, stroked: awakeRing)
        }
    }

    /// Stay Awake keeps its lavender color; other modes follow the menu-bar appearance.
    static func menuBarImage(for mode: Mode) -> NSImage {
        menuBarImages[mode] ?? NSImage()
    }

    private static let menuBarImages = Dictionary(uniqueKeysWithValues: Mode.allCases.map { ($0, image(for: $0, size: 18)) })

    private static func image(for mode: Mode, size: CGFloat) -> NSImage {
        let glyph = glyph(for: mode)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / gridSize, y: rect.height / gridSize)
            let color = mode == .lidClosed ? awakeColor.cgColor : NSColor.black.cgColor
            context.setFillColor(color)
            context.addPath(glyph.filled)
            context.fillPath()
            context.setStrokeColor(color)
            context.setLineWidth(strokeStyle.lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(glyph.stroked)
            context.strokePath()
            return true
        }
        image.isTemplate = mode != .lidClosed
        image.accessibilityDescription = "MacStayAwake"
        return image
    }

    private static let screen = CGPath(
        roundedRect: CGRect(x: 5, y: 5.5, width: 14, height: 9.5),
        cornerWidth: 1.6,
        cornerHeight: 1.6,
        transform: nil
    )

    private static let stand = lines([(CGPoint(x: 2.5, y: 18.5), CGPoint(x: 21.5, y: 18.5))])

    // Coordinates match the original vector mark in AppIcon.icon/Assets/Logo.svg.
    private static let awakeRing: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 16.6, y: 3.5))
        path.addCurve(to: CGPoint(x: 4.2, y: 6.8), control1: CGPoint(x: 12.3, y: 1), control2: CGPoint(x: 6.7, y: 2.4))
        path.addCurve(to: CGPoint(x: 7.7, y: 20), control1: CGPoint(x: 1.4, y: 11.7), control2: CGPoint(x: 3.5, y: 17.5))
        path.addLine(to: CGPoint(x: 18.8, y: 20))
        return path
    }()

    private static let awakeBolt: CGPath = {
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: 15.2, y: 5.2), CGPoint(x: 9.5, y: 12), CGPoint(x: 13.3, y: 12),
            CGPoint(x: 11.7, y: 17.6), CGPoint(x: 20.5, y: 9.3), CGPoint(x: 16.4, y: 9.3),
            CGPoint(x: 18.4, y: 5.2),
        ])
        path.closeSubpath()
        return path
    }()

    private static func lines(_ segments: [(CGPoint, CGPoint)]) -> CGPath {
        let path = CGMutablePath()
        for (start, end) in segments {
            path.move(to: start)
            path.addLine(to: end)
        }
        return path
    }

    private static func combined(_ paths: CGPath...) -> CGPath {
        let path = CGMutablePath()
        paths.forEach { path.addPath($0) }
        return path
    }
}

/// The mode shape in the current foreground style.
struct ModeIconView: View {
    let mode: Mode

    var body: some View {
        Canvas { context, size in
            let glyph = ModeIcon.glyph(for: mode)
            context.scaleBy(x: size.width / ModeIcon.gridSize, y: size.height / ModeIcon.gridSize)
            context.fill(Path(glyph.filled), with: .foreground)
            context.stroke(Path(glyph.stroked), with: .foreground, style: ModeIcon.strokeStyle)
        }
        .accessibilityHidden(true)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var controller: ModeController

    var body: some View {
        Image(nsImage: ModeIcon.menuBarImage(for: controller.mode))
            .renderingMode(controller.mode == .lidClosed ? .original : .template)
            .accessibilityLabel(Text(verbatim: "MacStayAwake"))
            .help(controller.mode == .lidClosed ? Text("Right-click to turn Stay Awake off") : Text("Right-click to turn Stay Awake on"))
    }
}
