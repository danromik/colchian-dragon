import AppKit

/// The look of the Claude Code activity box, chosen in Settings.
enum ActivityStyle: String, CaseIterable, Identifiable {
    case dragonEye
    case dragonScales
    case activityStream

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dragonEye: return "Dragon Eye"
        case .dragonScales: return "Dragon Scales"
        case .activityStream: return "Activity Stream"
        }
    }

    /// The height of the design's box, without making one.
    var boxHeight: CGFloat { makeDesign().boxHeight }

    func makeDesign() -> ActivityDesign {
        switch self {
        case .dragonEye: return DragonEyeDesign()
        case .dragonScales: return DragonScalesDesign()
        case .activityStream: return ActivityStreamDesign()
        }
    }
}

/// A visual design for the activity box in the menu and the detail panel that opens beside it.
///
/// One instance keeps the animation state for both. Drawing happens in a flipped context
/// (origin at the top left, y pointing down) with `NSGraphicsContext.current` set and the
/// view's appearance current, so semantic colors such as `NSColor.labelColor` resolve correctly.
protocol ActivityDesign: AnyObject {
    /// The height of the box's tile. Its width is the menu's width less 10 pt on each side.
    var boxHeight: CGFloat { get }
    /// Advances animations; called once per frame while the box is shown.
    func tick(dt: Double, now: Date, snapshot: ActivitySnapshot)
    /// Draws the box's contents over its tile background, which is already drawn.
    func drawBox(size: CGSize, context: CGContext, now: Date, snapshot: ActivitySnapshot, mouse: CGPoint?)
    /// The detail panel's size; the panel follows it when it changes.
    func panelSize(for snapshot: ActivitySnapshot) -> CGSize
    /// Draws the detail panel's contents over its menu-like background.
    func drawPanel(size: CGSize, context: CGContext, now: Date, snapshot: ActivitySnapshot, mouse: CGPoint?)
    /// Forgets transient state when the menu closes.
    func reset()
}

/// Renders a view's contents into a bitmap of its own, for the view's layer.
///
/// Views in a menu that draw in draw(_:) every frame are replayed into the menu's deep-color
/// (16-bit float) backing store on the CPU, which for glows and many small shapes keeps a core busy
/// (see `AboutView`). An 8-bit bitmap in the window's color space avoids that.
final class LayerBitmap {
    private var context: CGContext?

    /// Draws with `draw` into a flipped context of `size` points and returns the image.
    func render(size: CGSize, view: NSView, draw: (CGContext) -> Void) -> CGImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        let space = view.window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if context?.width != width || context?.height != height || context?.colorSpace != space {
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            // Flipped, so designs (ported from web prototypes) can lay things out from the top.
            context?.translateBy(x: 0, y: CGFloat(height))
            context?.scaleBy(x: scale, y: -scale)
        }
        guard let context else { return nil }
        context.clear(CGRect(origin: .zero, size: size))
        context.saveGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { draw(context) }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        return context.makeImage()
    }
}

/// The full-width box under the dashboard's tiles that shows Claude Code activity. While the mouse is
/// over it, the menu shows the detail panel beside the menu (see `ActivityPanelController`).
final class ActivityBoxView: MenuItemView {
    /// Space under the tile, matching the space under the dashboard's tiles.
    static let bottomPadding: CGFloat = 7
    static let inset: CGFloat = 10

    private(set) var design: ActivityDesign
    private(set) var style: ActivityStyle
    private let bitmap = LayerBitmap()
    private var now = Date()
    /// The box drives itself with a timer of its own, for the preview in Settings.
    private var previewTimer: Timer?
    private var retainsMonitor = false

    init(style: ActivityStyle) {
        self.style = style
        design = style.makeDesign()
        super.init(height: design.boxHeight + Self.bottomPadding)
        wantsLayer = true
    }

    var snapshot: ActivitySnapshot { ClaudeActivityMonitor.shared.snapshot }

    func setStyle(_ style: ActivityStyle) {
        guard style != self.style else { return }
        self.style = style
        design = style.makeDesign()
        setFrameSize(NSSize(width: frame.width, height: design.boxHeight + Self.bottomPadding))
        // Re-attaching the view makes the menu measure its row again (see AboutView).
        if let item = enclosingMenuItem {
            item.view = nil
            item.view = self
        }
        needsDisplay = true
    }

    /// The tile, in view coordinates.
    var tileRect: CGRect {
        CGRect(x: Self.inset, y: Self.bottomPadding, width: bounds.width - 2 * Self.inset, height: design.boxHeight)
    }

    /// The tile's frame on screen.
    var tileScreenRect: CGRect? {
        window.map { $0.convertToScreen(convert(tileRect, to: nil)) }
    }

    /// Whether the mouse is over the tile.
    var isHovered: Bool { mouseLocation.map(tileRect.contains) ?? false }

    override func tick(dt: Double) {
        if enclosingMenuItem?.isHidden == true { return }
        now = Date()
        design.tick(dt: dt, now: now, snapshot: snapshot)
        needsDisplay = true
    }

    override func reset() {
        design.reset()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let tile = tileRect
        // The mouse in the tile's flipped coordinates.
        let mouse = mouseLocation.flatMap { point -> CGPoint? in
            tile.contains(point) ? CGPoint(x: point.x - tile.minX, y: tile.maxY - point.y) : nil
        }
        let snapshot = self.snapshot
        layer?.contents = bitmap.render(size: bounds.size, view: self) { ctx in
            // Flipped: the tile's top is `bounds.height - tile.maxY` from the top.
            let top = bounds.height - tile.maxY
            let rect = CGRect(x: tile.minX, y: top, width: tile.width, height: tile.height)
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.minY)
            ctx.clip(to: CGRect(origin: .zero, size: rect.size))
            design.drawBox(size: rect.size, context: ctx, now: now, snapshot: snapshot, mouse: mouse)
            ctx.restoreGState()
        }
    }

    // MARK: Preview

    /// Animates the box on its own, for the preview in Settings: a timer runs, and the activity monitor
    /// reads every second, only while the window is visible on screen.
    func startPreview() {
        isPreview = true
        updatePreview()
    }

    private var isPreview = false
    private var occlusionObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard isPreview else { return }
        occlusionObserver.map(NotificationCenter.default.removeObserver)
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                   queue: .main) { [weak self] _ in self?.updatePreview() }
        }
        updatePreview()
    }

    private func updatePreview() {
        let visible = isPreview && window?.occlusionState.contains(.visible) == true
        if visible != retainsMonitor {
            retainsMonitor = visible
            if visible { ClaudeActivityMonitor.shared.retain() } else { ClaudeActivityMonitor.shared.release() }
        }
        if visible, previewTimer == nil {
            var last = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                let t = CACurrentMediaTime()
                self?.tick(dt: min(t - last, 0.1))
                last = t
            }
            RunLoop.main.add(timer, forMode: .common)
            previewTimer = timer
        } else if !visible {
            previewTimer?.invalidate()
            previewTimer = nil
        }
    }

    deinit {
        previewTimer?.invalidate()
        occlusionObserver.map(NotificationCenter.default.removeObserver)
        if retainsMonitor { ClaudeActivityMonitor.shared.release() }
    }
}

/// Shows the detail panel to the left of the menu while the mouse is over the activity box or the panel
/// itself. Like the mode guide, the panel is a window of its own, updated every frame while the menu is open.
final class ActivityPanelController {
    /// How long the mouse must rest on the box before the panel opens, and how long it may be away
    /// from both before it closes (so it survives the trip from the box to the panel).
    private static let openDelay: CFTimeInterval = 0.15
    private static let closeDelay: CFTimeInterval = 0.22

    private let panel = ActivityPanel()
    private var hoveredSince: CFTimeInterval?
    private var awaySince: CFTimeInterval?
    private var lastUpdate: CFTimeInterval = 0
    private var visibility: CGFloat = 0

    var isShown: Bool { visibility > 0 }

    /// Called every frame while the menu is open, with the box's tile on screen and whether the mouse is over it.
    func update(box: ActivityBoxView, now: CFTimeInterval) {
        let dt = CGFloat(min(now - lastUpdate, 0.1))
        lastUpdate = now
        let overBox = box.isHovered && !box.isHiddenOrHasHiddenAncestor
        let overPanel = isShown && panel.frame.contains(NSEvent.mouseLocation)
        hoveredSince = overBox ? hoveredSince ?? now : (overPanel ? hoveredSince : nil)
        awaySince = overBox || overPanel ? nil : awaySince ?? now

        let wanted: Bool
        if isShown {
            wanted = awaySince.map { now - $0 < Self.closeDelay } ?? true
        } else {
            wanted = hoveredSince.map { now - $0 >= Self.openDelay } ?? false
        }
        guard let tile = box.tileScreenRect, let menuFrame = box.window?.frame else { return }
        let snapshot = box.snapshot
        panel.design = box.design
        panel.snapshot = snapshot
        if wanted { panel.place(size: box.design.panelSize(for: snapshot), menu: menuFrame, tile: tile) }
        visibility = wanted ? min(1, visibility + dt / 0.15) : max(0, visibility - dt / 0.12)
        if visibility > 0 {
            panel.alphaValue = 1 - pow(1 - visibility, 3)
            if !panel.isVisible { panel.orderFrontRegardless() }
            panel.redraw()
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func hide() {
        hoveredSince = nil
        awaySince = nil
        visibility = 0
        panel.orderOut(nil)
    }
}

/// A borderless panel that looks like a submenu: the menu's material, rounded corners and a shadow.
private final class ActivityPanel: NSPanel {
    private static let radius: CGFloat = 10

    private let background = NSVisualEffectView()
    private let canvas = ActivityPanelCanvas()

    weak var design: ActivityDesign? {
        didSet { canvas.design = design }
    }
    var snapshot = ActivitySnapshot.empty {
        didSet { canvas.snapshot = snapshot }
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true  // the menu keeps tracking the mouse; hover is read from its position
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)  // above the menu, below tooltips
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        background.material = .menu
        background.state = .active
        canvas.autoresizingMask = [.width, .height]
        background.addSubview(canvas)
        contentView = background
    }

    /// Places the panel to the left of the menu with its top a little above the tile's, kept on screen.
    /// If there's no room on the left, it goes to the right of the menu.
    func place(size: CGSize, menu: CGRect, tile: CGRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(menu) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? menu
        var x = menu.minX - size.width
        if x < visible.minX + 4 { x = min(menu.maxX, visible.maxX - size.width - 4) }
        let top = min(tile.maxY + 5, visible.maxY)
        let y = max(visible.minY + 4, top - size.height)
        let frame = CGRect(x: x, y: y, width: size.width, height: size.height).integral
        guard frame != self.frame else { return }
        let resized = frame.size != self.frame.size
        setFrame(frame, display: false)
        if resized {
            background.maskImage = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: Self.radius, yRadius: Self.radius).fill()
                return true
            }
            invalidateShadow()
        }
    }

    func redraw() {
        canvas.needsDisplay = true
    }
}

/// The panel's contents, drawn by the design into a bitmap for the layer.
private final class ActivityPanelCanvas: NSView {
    weak var design: ActivityDesign?
    var snapshot = ActivitySnapshot.empty
    private let bitmap = LayerBitmap()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let design else { return }
        var mouse: CGPoint?
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { mouse = CGPoint(x: point.x, y: bounds.height - point.y) }
        }
        let snapshot = self.snapshot, size = bounds.size, now = Date()
        layer?.contents = bitmap.render(size: size, view: self) { ctx in
            design.drawPanel(size: size, context: ctx, now: now, snapshot: snapshot, mouse: mouse)
            // A hairline edge, like the mode guide's.
            NSColor.labelColor.withAlphaComponent(0.12).setStroke()
            let edge = NSBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            edge.lineWidth = 1
            edge.stroke()
        }
    }
}
