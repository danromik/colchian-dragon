import AppKit

/// The menu bar icon: the selected mode's glyph, as on its badge in the menu.
enum MenuBarIcon {
    /// Every mode's icon has the same size, so the status item keeps its width and an open menu doesn't
    /// shift when the mode changes.
    private static let size = CGSize(width: 24, height: 16)

    /// A template image, which the menu bar draws in its own colors.
    static func image(for mode: Mode, description: String) -> NSImage? {
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            switch mode.glyph {
            case .laptopEye:
                Drawing.laptopEye(color: .black, weight: .regular, in: bounds, context: ctx)
            case .dragonEye(let claude):
                // In a badge this size, the eye with Claude Code's asterisk below it is as tall as the icon. The eye
                // is the same size in both Stay Awake modes, and moves up to center the two together.
                let side: CGFloat = 25.5, lift: CGFloat = claude ? 0.93 : 0
                Drawing.dragonEye(claude: claude, color: .black,
                                  in: CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2 + lift, width: side, height: side),
                                  context: ctx)
            case let glyph:
                Drawing.glyph(glyph, color: .black, in: bounds, context: ctx)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
