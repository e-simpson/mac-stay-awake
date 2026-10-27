import AppKit
import Combine
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
    static let awakeSymbol = NSImage(systemSymbolName: "eye.half.closed.fill", accessibilityDescription: "Stay Awake")

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

    static func menuBarImage(for mode: Mode, countdown: String) -> NSImage {
        let icon = menuBarImage(for: mode)
        guard !countdown.isEmpty else { return icon }
        let text = NSAttributedString(string: countdown, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: awakeColor,
        ])
        let size = NSSize(width: icon.size.width + 5 + ceil(text.size().width), height: 18)
        return NSImage(size: size, flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: (size.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            text.draw(at: NSPoint(x: icon.size.width + 5, y: (size.height - text.size().height) / 2))
            return true
        }
    }

    private static let menuBarImages = Dictionary(uniqueKeysWithValues: Mode.allCases.map { ($0, image(for: $0, size: 18)) })

    private static func image(for mode: Mode, size: CGFloat) -> NSImage {
        if mode == .lidClosed,
           let image = awakeSymbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [awakeColor])) {
            let scale = size / max(image.size.width, image.size.height)
            image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.isTemplate = false
            image.accessibilityDescription = "Stay Awake"
            return image
        }
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

@MainActor
final class MenuBarCountdown: ObservableObject {
    @Published private(set) var clock = ""
    private weak var controller: ModeController?
    private var observation: AnyCancellable?
    private var timer: Timer?

    init(controller: ModeController) {
        self.controller = controller
        observation = controller.objectWillChange
            .merge(with: controller.preferences.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        timer?.invalidate()
        guard let controller, controller.mode != .off, let remaining = controller.timerRemaining() else {
            clock = ""
            return
        }
        let value = DurationFormat.clock(Int(remaining.rounded(.up)))
        if clock != value { clock = value }
        guard remaining > 0 else { return }
        // Wake only when the displayed minute changes.
        let delay = remaining.truncatingRemainder(dividingBy: 60)
        timer = Timer.scheduledTimer(withTimeInterval: max(delay, 0.1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }
}

struct MenuBarIcon: View {
    @ObservedObject var controller: ModeController
    @ObservedObject var countdown: MenuBarCountdown

    var body: some View {
        Image(nsImage: ModeIcon.menuBarImage(for: controller.mode, countdown: countdown.clock))
            .renderingMode(controller.mode == .lidClosed ? .original : .template)
            .accessibilityLabel(Text(verbatim: "MacStayAwake"))
            .help(controller.mode == .lidClosed ? Text("Right-click to turn Stay Awake off") : Text("Right-click to turn Stay Awake on"))
    }
}
