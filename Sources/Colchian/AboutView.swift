import AppKit

/// The About panel: a canvas at the bottom of the menu that slides open below the footer and plays the
/// story of the Colchian dragon.
final class AboutView: MenuItemView {
    /// A no-break space keeps "Golden Fleece" on one line.
    static let story = "The Colchian Dragon is the guardian of the Golden\u{A0}Fleece from Greek mythology. It never sleeps."
    static let tagline = "Now it lets you control when your Mac sleeps."

    static let credits: String = {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleName"] as? String ?? "Colchian Dragon"
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let copyright = info?["NSHumanReadableCopyright"] as? String ?? "Copyright © 2026 Dan Romik and Rhombic Research Inc."
        return "\(name) Version \(version)\n\(copyright)"
    }()

    /// The design shown. Alternatives that were considered are kept in Archive/AboutDesigns.
    private static let artwork: any AboutArtwork.Type = GildedEngraving.self

    private static let padding: CGFloat = 6
    private static let fullHeight = padding + artwork.size.height + padding

    private(set) var isOpen = false
    /// 0 when collapsed, 1 when fully open; animates the menu's growth.
    private var openness: CGFloat = 0
    /// Seconds since the panel opened; drives the artwork.
    private var time: Double = 0
    /// The panel is rendered into a bitmap of our own and handed to the view's layer as its contents.
    /// Drawn in draw(_:), it would be replayed every frame into the menu's deep-color (16-bit float)
    /// backing store on the CPU, which for the artwork's shadows and gradients keeps most of a core busy.
    private var bitmap: CGContext?
    private var rendered: (time: Double, image: CGImage)?

    init() {
        super.init(height: 1)  // AppKit doesn't allow menu items of zero height
        wantsLayer = true
    }

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        if open { time = 0 }
    }

    override func tick(dt: Double) {
        guard isOpen || openness > 0 else { return }
        // Opens over 0.4 s and closes over 0.25 s, holding still once there.
        openness = isOpen ? min(1, openness + CGFloat(dt / 0.4)) : max(0, openness - CGFloat(dt / 0.25))
        // Ease out while opening, ease in while closing.
        let eased = isOpen ? 1 - pow(1 - openness, 3) : openness * openness
        let height = max(1, (Self.fullHeight * eased).rounded())
        if frame.height != height {
            setFrameSize(NSSize(width: frame.width, height: height))
            // The menu resizes its window when the view's size changes, but it lays out items in a
            // table whose row keeps its old height; re-attaching the view makes it measure the row again.
            if let item = enclosingMenuItem {
                item.view = nil
                item.view = self
            }
        }
        time += dt
        needsDisplay = true
    }

    override func reset() {
        isOpen = false
        openness = 0
        time = 0
        bitmap = nil
        rendered = nil
        layer?.contents = nil
        setFrameSize(NSSize(width: frame.width, height: 1))
    }

    // MARK: - Drawing

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard isOpen || openness > 0, let image = renderPanel() else {
            layer?.contents = nil
            return
        }
        // The panel opens from the top down, so the menu shows the image's top rows (which come first).
        let rows = min(image.height, Int((bounds.height / Self.fullHeight * CGFloat(image.height)).rounded()))
        layer?.contents = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: rows))
    }

    /// The fully open panel.
    private func renderPanel() -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: bounds.width, height: Self.fullHeight)
        let width = Int(size.width * scale), height = Int(size.height * scale)
        // In the window's color space, the image goes to the screen without being color matched every frame.
        let space = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if bitmap?.width != width || bitmap?.height != height || bitmap?.colorSpace != space {
            bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            bitmap?.scaleBy(x: scale, y: scale)
            rendered = nil
        }
        if let rendered, rendered.time == time { return rendered.image }
        guard let bitmap else { return nil }
        bitmap.clear(CGRect(origin: .zero, size: size))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        let artwork = Self.artwork
        let art = CGRect(x: ((size.width - artwork.size.width) / 2).rounded(), y: Self.padding,
                         width: artwork.size.width, height: artwork.size.height)
        artwork.draw(time: time, in: art, context: bitmap, story: Self.story, tagline: Self.tagline, credits: Self.credits)
        NSGraphicsContext.restoreGraphicsState()

        rendered = bitmap.makeImage().map { (time, $0) }
        return rendered?.image
    }
}
