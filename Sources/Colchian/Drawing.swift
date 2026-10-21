import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A color with separate variants for light and dark appearances.
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    /// Claude's orange, used for everything related to Claude Code.
    static let claude = NSColor(hex: 0xD97757)
}

/// An icon drawn inside a colored circle.
enum Glyph {
    case symbol(String)
    /// An asterisk like the spinner Claude Code shows while it works.
    case asterisk(rotation: CGFloat)
    /// The Colchian dragon's open eye, optionally with Claude Code's asterisk in its corner.
    case dragonEye(claude: Bool)
    /// A laptop with the Colchian dragon's eye over the corner of its screen.
    case laptopEye
}

/// Drawing helpers for the menu's custom views. Coordinates are unflipped (y points up).
enum Drawing {
    static func badge(_ glyph: Glyph, fill: NSColor, glyphColor: NSColor, in rect: CGRect, context ctx: CGContext) {
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: rect)
        self.glyph(glyph, color: glyphColor, in: rect, context: ctx)
    }

    /// Draws a badge's glyph, without the circle.
    static func glyph(_ glyph: Glyph, color: NSColor, in rect: CGRect, context ctx: CGContext) {
        switch glyph {
        case .symbol(let name):
            symbol(name, pointSize: rect.height * 0.45, color: color, in: rect)
        case .asterisk(let rotation):
            asterisk(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.height * 0.3,
                     rotation: rotation, color: color, in: ctx)
        case .dragonEye(let claude):
            dragonEye(claude: claude, color: color, in: rect, context: ctx)
        case .laptopEye:
            // Bolder than in the menu bar, to match the other glyphs at this small size.
            laptopEye(color: color, weight: .semibold, in: rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12), context: ctx)
        }
    }

    /// The laptop with the dragon's eye: the system's laptop symbol, with the eye over the top-right corner of
    /// its screen. The design is 24 × 16 pt, scaled to fit `rect`.
    static func laptopEye(color: NSColor, weight: NSFont.Weight, in rect: CGRect, context ctx: CGContext) {
        // In monochrome the symbol's screen is empty.
        let configuration = NSImage.SymbolConfiguration(pointSize: 0, weight: weight).applying(.preferringMonochrome())
        guard let laptop = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let scale = min(rect.width / 24, rect.height / 16)
        ctx.saveGState()
        ctx.translateBy(x: rect.midX - 12 * scale, y: rect.midY - 8 * scale)
        ctx.scaleBy(x: scale, y: scale)
        // Everything is drawn in black, then takes the color, so the cut-outs don't cut through what's below.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        laptop.draw(in: CGRect(origin: .zero, size: laptop.size))

        let c = CGPoint(x: 16.4, y: 10.9), w: CGFloat = 6.6, h: CGFloat = 3.5
        // A gap around the eye where it overlaps the laptop.
        let outline = almond(center: c, halfWidth: w, halfHeight: h)
        ctx.setBlendMode(.clear)
        ctx.addPath(outline)
        ctx.fillPath()
        ctx.addPath(outline)
        ctx.setLineWidth(2.2)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.setBlendMode(.normal)
        // The eye's outline, as heavy as the symbol's lines, and a solid iris with the slit pupil cut through it.
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(weight == .regular ? 1.05 : 1.3)
        ctx.addPath(almond(center: c, halfWidth: w - 0.5, halfHeight: h - 0.45))
        ctx.strokePath()
        let r = (h - 0.45) * 0.78
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.setBlendMode(.clear)
        ctx.addPath(slit(center: c, halfWidth: 0.55, halfHeight: r))
        ctx.fillPath()

        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// An eye's outline: two arcs meeting in points at the corners.
    private static func almond(center c: CGPoint, halfWidth w: CGFloat, halfHeight h: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x - w, y: c.y))
        path.addQuadCurve(to: CGPoint(x: c.x + w, y: c.y), control: CGPoint(x: c.x, y: c.y + 2 * h))
        path.addQuadCurve(to: CGPoint(x: c.x - w, y: c.y), control: CGPoint(x: c.x, y: c.y - 2 * h))
        path.closeSubpath()
        return path
    }

    /// A dragon's vertical slit pupil, pointed at both ends.
    private static func slit(center c: CGPoint, halfWidth w: CGFloat, halfHeight h: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x, y: c.y + h))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - h), control: CGPoint(x: c.x + 2 * w, y: c.y))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + h), control: CGPoint(x: c.x - 2 * w, y: c.y))
        path.closeSubpath()
        return path
    }

    /// A one-color version of the dragon's eye in the mode illustrations: an almond with a round iris
    /// cut out of it and a slit pupil inside. Claude Code's asterisk goes in the lower right, cut out of the eye.
    static func dragonEye(claude: Bool, color: NSColor, in rect: CGRect, context ctx: CGContext) {
        let size = rect.height
        let width = size * 0.72
        let center = CGPoint(x: rect.midX, y: rect.midY + (claude ? size * 0.06 : 0))
        let halfHeight = width * 0.3

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(almond(center: center, halfWidth: width / 2, halfHeight: halfHeight))
        ctx.fillPath()
        // A solid iris inside a cut-out ring, with the slit pupil cut through it.
        let r = halfHeight * 0.92, iris = r * 0.74
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ctx.setBlendMode(.normal)
        ctx.fillEllipse(in: CGRect(x: center.x - iris, y: center.y - iris, width: 2 * iris, height: 2 * iris))
        ctx.setBlendMode(.clear)
        ctx.addPath(slit(center: center, halfWidth: iris * 0.275, halfHeight: iris))
        ctx.fillPath()
        ctx.setBlendMode(.normal)

        if claude {
            let markCenter = CGPoint(x: rect.midX + size * 0.2, y: rect.midY - size * 0.19)
            let gap = size * 0.21
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: markCenter.x - gap, y: markCenter.y - gap, width: 2 * gap, height: 2 * gap))
            ctx.setBlendMode(.normal)
            asterisk(center: markCenter, radius: size * 0.16, rotation: 0, color: color, in: ctx)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func asterisk(center: CGPoint, radius: CGFloat, rotation: CGFloat, color: NSColor, in ctx: CGContext) {
        let spokeWidth = radius * 0.38
        let spoke = CGRect(x: -spokeWidth / 2, y: 0, width: spokeWidth, height: radius)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotation)
        for _ in 0..<8 {
            ctx.addPath(CGPath(roundedRect: spoke, cornerWidth: spokeWidth / 2, cornerHeight: spokeWidth / 2, transform: nil))
            ctx.rotate(by: .pi / 4)
        }
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Draws an SF Symbol in `color`, centered in `rect`.
    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor, in rect: CGRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let origin = CGPoint(x: pixelAligned(rect.midX - size.width / 2), y: pixelAligned(rect.midY - size.height / 2))
        image.draw(in: CGRect(origin: origin, size: size))
    }

    /// Draws one line of text starting at `x`, vertically centered on `midY`, truncated to `maxWidth`.
    static func text(_ string: String, font: NSFont, color: NSColor, x: CGFloat, midY: CGFloat,
                     maxWidth: CGFloat = .greatestFiniteMagnitude, underlined: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let text = NSAttributedString(string: string, attributes: attributes)
        let size = text.size()
        let rect = CGRect(x: x, y: pixelAligned(midY - size.height / 2), width: min(size.width, maxWidth), height: size.height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    static func pixelAligned(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}
