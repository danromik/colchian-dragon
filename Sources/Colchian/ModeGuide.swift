import AppKit

/// An explanation of the three modes that drops down from the "?" button next to the Mode heading while
/// the mouse is over the button. Like the tooltips, it's a window of its own: the menu reports where the
/// button is every frame while the mouse is over it.
final class ModeGuide {
    /// How long the mouse must be over the button before the guide drops down, so it doesn't flash up
    /// when the mouse only passes over the button.
    private static let delay: CFTimeInterval = 0.2

    private let panel = ModeGuidePanel()
    private var hoveredSince: CFTimeInterval?
    private var lastUpdate: CFTimeInterval = 0
    /// 0 when hidden, 1 when fully shown.
    private var visibility: CGFloat = 0

    var isShown: Bool { visibility > 0 }

    /// Called every frame while the menu is open, with the button's frame on screen while the mouse is over it.
    func update(button: CGRect?, now: CFTimeInterval) {
        let dt = CGFloat(min(now - lastUpdate, 0.1))
        lastUpdate = now
        hoveredSince = button == nil ? nil : hoveredSince ?? now
        let wanted = hoveredSince.map { now - $0 >= Self.delay } ?? false
        if wanted, visibility == 0, let button { panel.place(below: button) }
        // Drops down over 0.18 s, and fades away over 0.12 s.
        visibility = wanted ? min(1, visibility + dt / 0.18) : max(0, visibility - dt / 0.12)
        if visibility > 0 {
            panel.reveal(1 - pow(1 - visibility, 3))
        } else {
            panel.orderOut(nil)
        }
    }

    func hide() {
        hoveredSince = nil
        visibility = 0
        panel.orderOut(nil)
    }
}

/// A popover-like panel with an arrow at the top that points at the button.
private final class ModeGuidePanel: NSPanel {
    private static let arrow = CGSize(width: 18, height: 8)
    private static let radius: CGFloat = 10
    /// How far the arrow is from the panel's left edge, so the panel hangs over the rows below the button.
    private static let arrowInset: CGFloat = 28

    private let background = NSVisualEffectView()
    private let guide = ModeGuideView()
    /// Where the panel comes to rest; it slides down into place as it appears.
    private var restingOrigin = CGPoint.zero

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false  // Colchian Dragon is never the active app while its menu is open.
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.helpWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        background.material = .popover
        background.state = .active
        background.addSubview(guide)
        contentView = background
    }

    /// Places the panel below `button` (in screen coordinates), with its arrow pointing at it, kept on screen.
    func place(below button: CGRect) {
        let size = CGSize(width: ModeGuideView.width, height: ModeGuideView.height + Self.arrow.height)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: button.midX, y: button.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        let x = min(max(button.midX - Self.arrowInset, visible.minX + 4), visible.maxX - size.width - 4)
        let margin = Self.radius + Self.arrow.width / 2
        let arrowX = min(max(button.midX - x, margin), size.width - margin)
        restingOrigin = CGPoint(x: x, y: button.minY - size.height)
        setFrame(CGRect(origin: restingOrigin, size: size), display: false)

        let outline = Self.outline(size: size, arrowX: arrowX)
        background.maskImage = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            outline.fill()
            return true
        }
        guide.frame = CGRect(origin: .zero, size: size)
        guide.outline = outline
        guide.needsDisplay = true
        invalidateShadow()
    }

    /// Shows the panel `progress` of the way through its drop-down: fading in as it slides into place.
    func reveal(_ progress: CGFloat) {
        alphaValue = progress
        setFrameOrigin(CGPoint(x: restingOrigin.x, y: restingOrigin.y + 3 * (1 - progress)))
        if !isVisible { orderFrontRegardless() }
    }

    /// A rounded rectangle with an arrow at `arrowX` on its top edge.
    private static func outline(size: CGSize, arrowX: CGFloat) -> NSBezierPath {
        let top = size.height - arrow.height, r = radius
        let path = NSBezierPath()
        path.move(to: CGPoint(x: arrowX - arrow.width / 2, y: top))
        path.line(to: CGPoint(x: arrowX, y: size.height))
        path.line(to: CGPoint(x: arrowX + arrow.width / 2, y: top))
        path.appendArc(withCenter: CGPoint(x: size.width - r, y: top - r), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        path.appendArc(withCenter: CGPoint(x: size.width - r, y: r), radius: r, startAngle: 0, endAngle: -90, clockwise: true)
        path.appendArc(withCenter: CGPoint(x: r, y: r), radius: r, startAngle: -90, endAngle: -180, clockwise: true)
        path.appendArc(withCenter: CGPoint(x: r, y: top - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        path.close()
        return path
    }
}

/// The guide's contents: a title over a hairline, then each mode's badge, name and explanation.
private final class ModeGuideView: NSView {
    static let width: CGFloat = 290
    private static let inset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 14)
    private static let badgeSize: CGFloat = 20
    private static let textX = inset.left + badgeSize + 9

    private struct Piece {
        let text: NSAttributedString
        let x: CGFloat                      // the text column, or the badges' left edge for the title
        let top: CGFloat, height: CGFloat   // down from the top of the guide's body
        let firstLine: CGFloat              // the height of its first line, which the badge is centered on
        let badge: Mode?
    }

    /// The text, laid out once, from the top of the guide's body down.
    private static let pieces: [Piece] = {
        var pieces = [Piece]()
        var y = inset.top
        func add(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, x: CGFloat = textX,
                 badge: Mode? = nil, gap: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
            let text = NSAttributedString(string: string, attributes: attributes)
            let textWidth = width - x - inset.right
            let bounds = text.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin)
            let firstLine = NSAttributedString(string: " ", attributes: attributes).size().height
            pieces.append(Piece(text: text, x: x, top: y, height: ceil(bounds.height), firstLine: firstLine, badge: badge))
            y += ceil(bounds.height) + gap
        }
        // The title leaves room for the 1 pt hairline below it, 7 pt under the title and 12 pt above the modes.
        add("Sleep Override Modes", size: 13, weight: .bold, color: .labelColor, x: inset.left, gap: 7 + 1 + 12)
        for mode in Mode.allCases {
            add(mode.title, size: 13, weight: .semibold, color: .labelColor, badge: mode, gap: 1)
            add(mode.explanation, size: 12, color: .labelColor, gap: 10)
        }
        return pieces
    }()

    /// The top of the hairline under the title, down from the top of the guide's body.
    private static let ruleTop = pieces[0].top + pieces[0].height + 7

    /// The height of the guide's body.
    static let height = (pieces.last.map { $0.top + $0.height } ?? 0) + inset.bottom

    var outline: NSBezierPath?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for piece in Self.pieces {
            let textWidth = bounds.width - piece.x - Self.inset.right
            let rect = CGRect(x: piece.x, y: Self.height - piece.top - piece.height, width: textWidth, height: piece.height)
            piece.text.draw(with: rect, options: .usesLineFragmentOrigin)
            if let mode = piece.badge {
                let badge = CGRect(x: Self.inset.left, y: rect.maxY - piece.firstLine / 2 - Self.badgeSize / 2,
                                   width: Self.badgeSize, height: Self.badgeSize)
                Drawing.badge(mode.glyph, fill: mode.color, glyphColor: .white, in: badge, context: ctx)
            }
        }
        // The hairline under the title, like a menu separator: 1 pt thick, with equal margins at both ends.
        NSColor.separatorColor.setFill()
        ctx.fill(CGRect(x: Self.inset.left, y: Self.height - Self.ruleTop - 1, width: bounds.width - 2 * Self.inset.left, height: 1))
        // A hairline edge, which the window's mask trims to half its width.
        if let outline {
            NSColor.labelColor.withAlphaComponent(0.12).setStroke()
            outline.lineWidth = 1
            outline.stroke()
        }
    }
}
