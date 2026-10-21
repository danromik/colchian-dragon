import AppKit

/// Text explaining the part of the menu under the mouse.
struct Tooltip: Equatable {
    /// Identifies the hovered region; moving to another region restarts the tooltip delay.
    let id: String
    let text: String
}

/// Shows tooltips for the status menu's custom views in a small window of its own.
/// Native tooltips aren't reliable inside menus, so the menu reports the tooltip under the
/// mouse every frame and this controller handles the delay, placement and fade-in.
final class TooltipController {
    /// How long the mouse must rest on an item before its tooltip appears.
    private static let delay: CFTimeInterval = 1.2
    /// Mouse movement (in points) that counts as moving on rather than resting.
    private static let restTolerance: CGFloat = 3

    private let panel = TooltipPanel()
    private var current: Tooltip?
    private var restingSince: CFTimeInterval = 0
    private var restingAt = CGPoint.zero
    private var shownAt: CFTimeInterval = 0
    /// Set by a click; the tooltip stays hidden until the mouse moves to another item.
    private var dismissed = false

    /// Called every frame while the menu is open, with the tooltip under the mouse (if any).
    func update(_ tooltip: Tooltip?, now: CFTimeInterval) {
        let mouse = NSEvent.mouseLocation
        if tooltip?.id != current?.id {
            panel.orderOut(nil)
            current = tooltip
            dismissed = false
            restingSince = now
            restingAt = mouse
        } else if !panel.isVisible, hypot(mouse.x - restingAt.x, mouse.y - restingAt.y) > Self.restTolerance {
            // Only a resting mouse brings up a tooltip; moving restarts the wait.
            restingSince = now
            restingAt = mouse
        }
        guard let tooltip, !dismissed else { return }

        if panel.isVisible {
            if tooltip.text != panel.text { panel.show(tooltip.text, below: panel.anchor) }  // the state changed
            panel.alphaValue = min(1, CGFloat((now - shownAt) / 0.15))
        } else if now - restingSince >= Self.delay {
            panel.alphaValue = 0
            panel.show(tooltip.text, below: mouse)
            shownAt = now
        }
    }

    /// Hides the tooltip until the mouse moves to another item, e.g. after a click.
    func dismiss() {
        panel.orderOut(nil)
        dismissed = true
    }

    func hide() {
        panel.orderOut(nil)
        current = nil
    }
}

private final class TooltipPanel: NSPanel {
    private static let maxTextWidth: CGFloat = 260
    private static let padding = NSSize(width: 6, height: 4)

    private let label = NSTextField(wrappingLabelWithString: "")
    private(set) var text = ""
    /// The mouse location the tooltip was placed below.
    private(set) var anchor = CGPoint.zero

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false  // Colchian is never the active app while its menu is open.
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.helpWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 5)
        label.font = .toolTipsFont(ofSize: 0)
        label.isSelectable = false
        background.addSubview(label)
        contentView = background
    }

    /// Shows `text` just below `point` (in screen coordinates), kept on screen.
    func show(_ text: String, below point: CGPoint) {
        self.text = text
        anchor = point
        label.stringValue = text
        let bounds = NSRect(x: 0, y: 0, width: Self.maxTextWidth, height: .greatestFiniteMagnitude)
        let textSize = label.cell?.cellSize(forBounds: bounds) ?? .zero
        let size = NSSize(width: ceil(min(textSize.width, Self.maxTextWidth)), height: ceil(textSize.height))
        label.frame = NSRect(origin: CGPoint(x: Self.padding.width, y: Self.padding.height), size: size)
        let frameSize = NSSize(width: size.width + 2 * Self.padding.width, height: size.height + 2 * Self.padding.height)

        // Like a native tooltip: below the cursor, or above it near the bottom of the screen.
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: frameSize)
        var origin = CGPoint(x: point.x, y: point.y - 22 - frameSize.height)
        if origin.y < visible.minY + 4 { origin.y = point.y + 10 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frameSize.width - 4)
        setFrame(NSRect(origin: origin, size: frameSize), display: true)
        invalidateShadow()
        orderFrontRegardless()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 2 * radius + 1, height: 2 * radius + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
