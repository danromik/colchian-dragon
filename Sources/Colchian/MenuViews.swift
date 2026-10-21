import AppKit

extension Mode {
    var color: NSColor {
        switch self {
        case .normal: return .systemIndigo
        case .alwaysAwake: return .systemTeal
        case .claudeCode: return .claude
        }
    }

    var glyph: Glyph {
        switch self {
        case .normal: return .laptopEye
        case .alwaysAwake: return .dragonEye(claude: false)
        case .claudeCode: return .dragonEye(claude: true)
        }
    }

    var explanation: String {
        switch self {
        case .normal:
            return "Your Mac sleeps when you close the lid, as usual."
        case .alwaysAwake:
            return "Your Mac keeps running when you close the lid."
        case .claudeCode:
            return "Your Mac keeps running with the lid closed while a Claude Code session is active, and sleeps as usual otherwise."
        }
    }
}

/// Calls `tick` on the menu's custom views every frame while the menu is open, for hover
/// effects and animations.
final class MenuAnimator {
    var views: [MenuItemView] = []
    /// Called after the views have ticked, with the current media time.
    var onFrame: ((CFTimeInterval) -> Void)?
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    func start() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        // .common includes the event-tracking mode the run loop is in while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        views.forEach { $0.reset() }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        views.forEach { $0.tick(dt: dt) }
        onFrame?(now)
    }
}

/// Base class for the custom views in the status menu. Menu items with views don't get the
/// standard highlight or click handling, so these views draw their own hover state and handle
/// mouse-up themselves.
class MenuItemView: NSView {
    init(height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: StatusMenu.width, height: height))
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Updates hover state and animations; called every frame while the menu is open.
    func tick(dt: Double) {}

    /// Clears hover state when the menu closes.
    func reset() {}

    /// The tooltip for the part of the view at `point` (in view coordinates).
    func tooltip(at point: CGPoint) -> Tooltip? { nil }

    var isMenuItemHighlighted: Bool { enclosingMenuItem?.isHighlighted ?? false }

    /// The mouse location in view coordinates, or nil when the mouse is outside the view.
    var mouseLocation: CGPoint? {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) ? point : nil
    }

    /// Closes the menu, then runs `action` once menu tracking has finished.
    func closeMenu(then action: (() -> Void)?) {
        enclosingMenuItem?.menu?.cancelTracking()
        if let action { DispatchQueue.main.async(execute: action) }
    }

    func drawHighlight(in rect: CGRect) {
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }
}

/// The top of the menu: the app name above two status tiles, for how hot the Mac is running and for
/// Claude Code activity. Either tile, or both, can be turned off in Settings.
final class DashboardView: MenuItemView {
    /// Which tiles are shown.
    struct Tiles: Equatable {
        var thermal = true
        var claude = true
        var any: Bool { thermal || claude }
    }

    struct Status: Equatable {
        var mode = Mode.normal
        var overheated = false
        var hooksInstalled = false
        var activeTurns = 0
        var openSessions = 0
        var thermalState = ProcessInfo.ThermalState.nominal
        var thermalLimit = ProcessInfo.ThermalState.serious
        var temperatures = Temperatures()
    }

    var status = Status() {
        didSet { if status != oldValue { needsDisplay = true } }
    }
    var tiles = Tiles() {
        didSet { if tiles != oldValue { resize() } }
    }

    /// The height for `tiles`: with none, only the app name is shown.
    static func height(for tiles: Tiles) -> CGFloat { tiles.any ? 82 : 30 }

    init() {
        super.init(height: Self.height(for: Tiles()))
    }

    private func resize() {
        setFrameSize(NSSize(width: frame.width, height: Self.height(for: tiles)))
        // Re-attaching the view makes the menu measure its row again (see AboutView).
        if let item = enclosingMenuItem {
            item.view = nil
            item.view = self
        }
        needsDisplay = true
    }

    private struct Tile {
        let caption: String
        let value: String
        /// A third line under the value, if any.
        var detail: String?
        let glyph: Glyph
        let color: NSColor
        var glyphColor: NSColor = .white
    }

    private var shownTiles: [Tile] {
        let turns = status.activeTurns, sessions = status.openSessions
        let sessionsText = sessions == 0 ? "No sessions open" : sessions == 1 ? "1 session open" : "\(sessions) sessions open"
        let turnsText = !status.hooksInstalled ? "No hooks"
            : turns == 0 ? "No sessions active" : turns == 1 ? "1 session active" : "\(turns) sessions active"
        let claude = Tile(caption: "Claude Code", value: turnsText, detail: sessionsText, glyph: .asterisk(rotation: 0), color: .claude)

        let thermalGlyph: String, thermalColor: NSColor
        switch status.thermalState {
        case .nominal: (thermalGlyph, thermalColor) = ("thermometer.low", .systemGreen)
        case .fair: (thermalGlyph, thermalColor) = ("thermometer.medium", .systemYellow)
        case .serious: (thermalGlyph, thermalColor) = ("thermometer.high", .systemOrange)
        default: (thermalGlyph, thermalColor) = ("thermometer.high", .systemRed)
        }
        let temperatures = status.temperatures
        // With a CPU reading, the state moves up into the caption to make room for it.
        let caption = temperatures.cpu == nil ? "Thermal" : "Thermal: \(status.thermalState.label)"
        let value = temperatures.cpu.map { "CPU \(Self.degrees($0))" } ?? status.thermalState.label
        let others = [temperatures.battery.map { "Battery \(Self.degrees($0))" }, temperatures.ssd.map { "SSD \(Self.degrees($0))" }]
            .compactMap { $0 }
        let thermal = Tile(caption: caption, value: value, detail: others.isEmpty ? nil : others.joined(separator: " · "),
                           glyph: .symbol(status.overheated && status.mode != .normal ? "flame.fill" : thermalGlyph),
                           color: status.overheated && status.mode != .normal ? .systemRed : thermalColor,
                           glyphColor: status.thermalState == .fair ? NSColor(white: 0, alpha: 0.7) : .white)
        return (tiles.thermal ? [thermal] : []) + (tiles.claude ? [claude] : [])
    }

    private static func degrees(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°"
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Drawing.text("Colchian Dragon", font: .systemFont(ofSize: 13, weight: .bold), color: .labelColor,
                     x: 14, midY: bounds.maxY - 15)

        let shown = shownTiles
        for (index, tile) in shown.enumerated() {
            draw(tile, in: tileRect(index, of: shown.count), context: ctx)
        }
    }

    /// The thermal tile, which has more to say, on the left, and the Claude Code tile on the right.
    /// A tile shown on its own takes the full width.
    private func tileRect(_ index: Int, of count: Int) -> CGRect {
        let inset: CGFloat = 10, gap: CGFloat = 6, claudeWidth: CGFloat = 140
        guard count == 2 else { return CGRect(x: inset, y: 7, width: bounds.width - 2 * inset, height: 50) }
        let thermalWidth = bounds.width - 2 * inset - claudeWidth - gap
        return index == 0 ? CGRect(x: inset, y: 7, width: thermalWidth, height: 50)
                          : CGRect(x: inset + thermalWidth + gap, y: 7, width: claudeWidth, height: 50)
    }

    private func draw(_ tile: Tile, in rect: CGRect, context ctx: CGContext) {
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()

        let badge = CGRect(x: rect.minX + 6, y: rect.midY - 12, width: 24, height: 24)
        Drawing.badge(tile.glyph, fill: tile.color, glyphColor: tile.glyphColor, in: badge, context: ctx)

        // Three lines, or two centered in the tile when there's no detail.
        let x = badge.maxX + 6, maxWidth = rect.maxX - 3 - x
        let step: CGFloat = tile.detail == nil ? 6.5 : 13
        Drawing.text(tile.caption, font: .systemFont(ofSize: 12, weight: .bold), color: .labelColor,
                     x: x, midY: rect.midY + step, maxWidth: maxWidth)
        Drawing.text(tile.value, font: .systemFont(ofSize: 11), color: .labelColor,
                     x: x, midY: tile.detail == nil ? rect.midY - 6 : rect.midY, maxWidth: maxWidth)
        if let detail = tile.detail {
            Drawing.text(detail, font: .systemFont(ofSize: 11), color: .labelColor, x: x, midY: rect.midY - step, maxWidth: maxWidth)
        }
    }
}

/// A warning under the dashboard, e.g. when passwordless control isn't set up. Clicking it opens Settings.
final class NoticeRowView: MenuItemView {
    var message = "" {
        didSet { if message != oldValue { needsDisplay = true } }
    }
    var onClick: (() -> Void)?
    private var highlighted = false

    init() {
        super.init(height: 26)
    }

    override func tick(dt: Double) {
        if isMenuItemHighlighted != highlighted {
            highlighted.toggle()
            needsDisplay = true
        }
    }

    override func reset() { highlighted = false }

    override func tooltip(at point: CGPoint) -> Tooltip? {
        Tooltip(id: "notice", text: "Open Settings to fix this.")
    }

    override func mouseUp(with event: NSEvent) {
        closeMenu(then: onClick)
    }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted { drawHighlight(in: bounds.insetBy(dx: 5, dy: 1)) }
        Drawing.symbol("exclamationmark.triangle.fill", pointSize: 12, color: .systemOrange,
                       in: CGRect(x: 14, y: bounds.midY - 8, width: 18, height: 16))
        Drawing.text(message, font: .menuFont(ofSize: 0), color: .labelColor, x: 38, midY: bounds.midY,
                     maxWidth: bounds.width - 38 - 30)
        Drawing.symbol("chevron.right", pointSize: 11, color: .secondaryLabelColor,
                       in: CGRect(x: bounds.maxX - 28, y: bounds.midY - 8, width: 14, height: 16))
    }
}

/// A small heading above a group of rows, optionally followed by a "?" button. The button isn't clicked:
/// while the mouse is over it, the menu shows an explanation of the group.
final class SectionHeaderView: MenuItemView {
    private static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private let title: String
    private let hasHelp: Bool
    /// Whether the mouse is over the "?" button.
    private(set) var helpHovered = false
    /// Whether the explanation is showing; the button is drawn filled while it is.
    var helpShown = false {
        didSet { if helpShown != oldValue { needsDisplay = true } }
    }

    init(title: String, hasHelp: Bool = false) {
        self.title = title
        self.hasHelp = hasHelp
        super.init(height: 20)
    }

    /// The "?" button, just after the title.
    private var helpRect: CGRect {
        let titleWidth = (title as NSString).size(withAttributes: [.font: Self.font]).width
        return CGRect(x: (14 + titleWidth + 3).rounded(), y: bounds.midY - 9, width: 16, height: 16)
    }

    /// The "?" button's frame on screen.
    var helpScreenRect: CGRect? {
        window.map { $0.convertToScreen(convert(helpRect, to: nil)) }
    }

    override func tick(dt: Double) {
        guard hasHelp else { return }
        // A little slack around the small button makes it easier to find.
        let hovered = mouseLocation.map { helpRect.insetBy(dx: -3, dy: -2).contains($0) } ?? false
        if hovered != helpHovered {
            helpHovered = hovered
            needsDisplay = true
        }
    }

    override func reset() {
        helpHovered = false
        helpShown = false
    }

    override func draw(_ dirtyRect: NSRect) {
        Drawing.text(title, font: Self.font, color: .secondaryLabelColor, x: 14, midY: bounds.midY - 1)
        guard hasHelp else { return }
        Drawing.symbol(helpShown ? "questionmark.circle.fill" : "questionmark.circle", pointSize: 12, weight: .regular,
                       color: helpHovered || helpShown ? .labelColor : .secondaryLabelColor, in: helpRect)
    }
}

/// A mode choice: a badge (filled with the mode's color when selected), the mode's name and,
/// while hovered, an animation of what the mode does.
final class ModeRowView: MenuItemView {
    let mode: Mode
    var onSelect: (() -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            // Animate the change only while the menu is open.
            if window?.isVisible != true { selection = isSelected ? 1 : 0 }
            needsDisplay = true
        }
    }
    /// Goes from 0 to 1 as the badge fills with the mode's color (and back when deselected).
    private var selection: CGFloat = 0
    var highlighted = false
    /// Opacity of the illustration, which fades in on hover.
    var reveal: CGFloat = 0
    var animationTime: Double = 0

    init(mode: Mode) {
        self.mode = mode
        super.init(height: 36)
    }

    override func tick(dt: Double) {
        let isHighlighted = isMenuItemHighlighted
        if isHighlighted && !highlighted { animationTime = 0 }  // play from the start on each hover
        let target: CGFloat = isHighlighted ? 1 : 0
        let step = CGFloat(dt / 0.2)
        let newReveal = reveal < target ? min(target, reveal + step) : max(target, reveal - step)
        if isHighlighted != highlighted || newReveal != reveal || newReveal > 0 { needsDisplay = true }
        if newReveal > 0 { animationTime += dt }
        highlighted = isHighlighted
        reveal = newReveal

        let selected: CGFloat = isSelected ? 1 : 0
        if selection != selected {
            let step = CGFloat(dt / 0.3)
            selection = selection < selected ? min(selected, selection + step) : max(selected, selection - step)
            needsDisplay = true
        }
    }

    override func reset() {
        highlighted = false
        reveal = 0
        selection = isSelected ? 1 : 0
    }

    /// Selecting a mode keeps the menu open, so the change can be seen.
    override func mouseUp(with event: NSEvent) {
        onSelect?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if highlighted { drawHighlight(in: bounds.insetBy(dx: 5, dy: 1)) }

        // The badge fills with the mode's color when selected, with a little bounce.
        let badge = CGRect(x: 14, y: bounds.midY - 12, width: 24, height: 24)
        let bounce = isSelected ? 0.18 * sin(.pi * selection) : 0
        let drawn = badge.insetBy(dx: -badge.width * bounce / 2, dy: -badge.height * bounce / 2)
        if selection < 1 {
            Drawing.badge(mode.glyph, fill: NSColor.labelColor.withAlphaComponent(0.1),
                          glyphColor: .secondaryLabelColor, in: drawn, context: ctx)
        }
        if selection > 0 {
            ctx.saveGState()
            ctx.setAlpha(selection)
            Drawing.badge(mode.glyph, fill: mode.color, glyphColor: .white, in: drawn, context: ctx)
            ctx.restoreGState()
        }
        Drawing.text(mode.title, font: .menuFont(ofSize: 0), color: .labelColor, x: badge.maxX + 9, midY: bounds.midY)

        if reveal > 0 {
            let art = CGRect(x: bounds.maxX - 14 - 92, y: bounds.minY + 3, width: 92, height: bounds.height - 6)
            ctx.saveGState()
            ctx.setAlpha(reveal)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ModeIllustration.draw(mode, time: animationTime, in: art, context: ctx)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }
}

/// The last row: Settings, About and the website on the left, a divider, and Quit on the right,
/// each with its own hover.
final class FooterRowView: MenuItemView {
    var onQuit: (() -> Void)?
    var onAbout: (() -> Void)?
    var onSettings: (() -> Void)?
    var onWebsite: (() -> Void)?
    /// Whether the About panel is open; its button is drawn highlighted while it is.
    var aboutOpen = false {
        didSet { if aboutOpen != oldValue { needsDisplay = true } }
    }

    private enum Part: CaseIterable { case settings, about, website, quit }
    private var hovered: Part?

    private static let font = NSFont.menuFont(ofSize: 0)
    /// Padding on each side of a text button's label.
    private static let padding: CGFloat = 8

    /// A standard separator, between the links and Quit.
    private let divider = NSBox()

    init() {
        super.init(height: 28)
        divider.boxType = .separator
        divider.autoresizingMask = [.maxXMargin]
        addSubview(divider)
        layoutDivider()
    }

    private func layoutDivider() {
        divider.frame = CGRect(x: dividerX, y: bounds.midY - 8, width: 1, height: 16)
    }

    private static func label(for part: Part) -> String {
        switch part {
        case .settings: return ""
        case .about: return "About"
        case .website: return "website"
        case .quit: return "Quit"
        }
    }

    /// A text button just around its label.
    private func textRect(_ part: Part, x: CGFloat) -> CGRect {
        let width = (Self.label(for: part) as NSString).size(withAttributes: [.font: Self.font]).width
        return CGRect(x: x, y: bounds.minY + 2, width: ceil(width) + 2 * Self.padding, height: bounds.height - 4)
    }

    private var settingsRect: CGRect { CGRect(x: 5, y: bounds.minY + 2, width: 30, height: bounds.height - 4) }
    private var aboutRect: CGRect { textRect(.about, x: settingsRect.maxX + 2) }
    private var websiteRect: CGRect { textRect(.website, x: aboutRect.maxX + 2) }
    private var dividerX: CGFloat { websiteRect.maxX + 6 }

    private var quitRect: CGRect {
        let rect = textRect(.quit, x: 0)
        return rect.offsetBy(dx: bounds.maxX - 5 - rect.width, dy: 0)
    }

    private func rect(for part: Part) -> CGRect {
        switch part {
        case .settings: return settingsRect
        case .about: return aboutRect
        case .website: return websiteRect
        case .quit: return quitRect
        }
    }

    /// The button at `point`, or nil in the space between them.
    private func part(at point: CGPoint) -> Part? {
        Part.allCases.first { rect(for: $0).minX <= point.x && point.x < rect(for: $0).maxX }
    }

    override func tick(dt: Double) {
        let part: Part?
        if let point = mouseLocation {
            part = self.part(at: point)
        } else {
            // With keyboard navigation the item is highlighted but the mouse is elsewhere: show Quit.
            part = isMenuItemHighlighted ? .quit : nil
        }
        if part != hovered {
            hovered = part
            needsDisplay = true
        }
    }

    override func reset() { hovered = nil }

    override func tooltip(at point: CGPoint) -> Tooltip? {
        switch part(at: point) {
        case .settings: return Tooltip(id: "settings", text: "Settings… ⌘,")
        case .about: return Tooltip(id: "about", text: "About Colchian Dragon")
        case .website: return Tooltip(id: "website", text: AppDelegate.website.absoluteString)
        case .quit: return Tooltip(id: "quit", text: "Quit Colchian Dragon. Normal sleep is restored.")
        case nil: return nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch part(at: convert(event.locationInWindow, from: nil)) {
        case .settings: closeMenu(then: onSettings)
        case .about: onAbout?()  // the menu stays open and expands to show the About panel
        case .website: closeMenu(then: onWebsite)
        case .quit: closeMenu(then: onQuit)
        case nil: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let hovered { drawHighlight(in: rect(for: hovered)) }
        if aboutOpen, hovered != .about { drawHighlight(in: aboutRect) }
        Drawing.symbol("gearshape", pointSize: 14, weight: .regular, color: .labelColor, in: settingsRect)
        // The website is underlined to show it's a link, in the same color as the other labels.
        for part in [Part.about, .website, .quit] {
            Drawing.text(Self.label(for: part), font: Self.font, color: .labelColor,
                         x: rect(for: part).minX + Self.padding, midY: bounds.midY, underlined: part == .website)
        }
    }
}
