import AppKit

/// The animations shown when hovering over a mode in the menu: a laptop whose lid closes and
/// reopens, next to the Colchian dragon's eye, which is open while the Mac is awake.
enum ModeIllustration {
    /// Seconds per lid cycle: open, close, stay closed, reopen.
    static let cycle = 3.2

    enum Screen {
        case desktop
        /// An agent at work; `progress` runs from 0 to 1 over one lid cycle.
        case agent(progress: Double, time: Double)
    }

    /// Draws the illustration for `mode`, right-aligned in `rect`.
    static func draw(_ mode: Mode, time: Double, in rect: CGRect, context ctx: CGContext) {
        let lid = lidOpenness(at: time)
        var eye = lid
        var screen = Screen.desktop
        switch mode {
        case .normal:
            break
        case .alwaysAwake:
            eye = 1
        case .claudeCode:
            // Alternate a lid cycle with an agent at work (stays awake) and one without (sleeps).
            let t = time.truncatingRemainder(dividingBy: 2 * cycle)
            if t < cycle {
                eye = 1
                screen = .agent(progress: t / cycle, time: time)
            }
        }

        let scale = rect.height / Laptop.bounds.height
        let laptopWidth = Laptop.bounds.width * scale
        let eyeWidth = (rect.height * 0.72).rounded()
        let gap = (rect.height * 0.22).rounded()
        let left = rect.maxX - eyeWidth - gap - laptopWidth
        Laptop.draw(openness: lid, screen: screen, origin: CGPoint(x: left, y: rect.minY), scale: scale, context: ctx)
        Eye.draw(openness: eye, center: CGPoint(x: rect.maxX - eyeWidth / 2, y: rect.midY + rect.height * 0.04),
                 width: eyeWidth, context: ctx)
    }

    /// 1 when the lid is open, 0 when it is closed.
    static func lidOpenness(at time: Double) -> CGFloat {
        let t = time.truncatingRemainder(dividingBy: cycle)
        switch t {
        case ..<1.0: return 1
        case ..<1.6: return 1 - smoothstep((t - 1.0) / 0.6)
        case ..<2.4: return 0
        case ..<3.0: return smoothstep((t - 2.4) / 0.6)
        default: return 1
        }
    }

    static func smoothstep(_ x: Double) -> CGFloat {
        let x = min(max(x, 0), 1)
        return CGFloat(x * x * (3 - 2 * x))
    }
}

private enum Palette {
    static let outline = NSColor.adaptive(0x5B616B, 0x2A2D33)
    static let baseTop = NSColor.adaptive(0xDCDFE4, 0xB7BBC2)
    static let baseFront = NSColor.adaptive(0xB3B8C0, 0x8C9199)
    static let baseSide = NSColor.adaptive(0xA2A7AF, 0x7A7F87)
    static let keyboard = NSColor.adaptive(0xA3A9B1, 0x70757D)
    static let trackpad = NSColor.adaptive(0xCBCFD5, 0xA5A9B0)
    static let lidBack = NSColor.adaptive(0xCDD1D7, 0xA9ADB4)
    static let bezel = NSColor(hex: 0x16181D)
    static let wallpaperTop = NSColor(hex: 0x5B8DEF)
    static let wallpaperBottom = NSColor(hex: 0xA46CF0)
    static let terminal = NSColor(hex: 0x10141E)
    static let output = NSColor(hex: 0xC9D1DC)
    static let added = NSColor(hex: 0x5BD08A)
    static let sclera = NSColor.adaptive(0xFFFFFF, 0xF2F2F2)
    static let irisInner = NSColor(hex: 0xFFD54A)
    static let irisOuter = NSColor(hex: 0xD9811A)
    static let pupil = NSColor(hex: 0x1A1410)
    static let eyelid = NSColor.adaptive(0x4F9D6E, 0x5FAE7E)
    static let eyelidEdge = NSColor(hex: 0x2E6B48)
    static let lashes = NSColor.adaptive(0x5B616B, 0xC9CDD3)
}

/// A laptop seen from the front left and slightly above, drawn with a simple 3D projection.
/// Model units: x to the right, y up, z toward the viewer; the hinge runs along x at y = z = 0.
private enum Laptop {
    static let width = 1.5, depth = 1.0, lidHeight = 0.95, thickness = 0.07
    static let openAngle = 108 * Double.pi / 180
    static let yaw = 30 * Double.pi / 180, pitch = 24 * Double.pi / 180

    static func project(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        let rx = x * cos(yaw) + z * sin(yaw)
        let rz = -x * sin(yaw) + z * cos(yaw)
        return CGPoint(x: rx, y: y * cos(pitch) - rz * sin(pitch))
    }

    /// Whether a face with outward normal (nx, ny, nz) faces the viewer.
    static func facesViewer(_ nx: Double, _ ny: Double, _ nz: Double) -> Bool {
        let rz = -nx * sin(yaw) + nz * cos(yaw)
        return ny * sin(pitch) + rz * cos(pitch) > 0
    }

    /// The projected bounding box over every lid position.
    static let bounds: CGRect = {
        let w = width / 2
        var points: [CGPoint] = []
        for x in [-w, w] {
            for z in [0, depth] {
                points += [project(x, 0, z), project(x, -thickness, z)]
            }
            for step in 0...24 {
                let angle = openAngle * Double(step) / 24
                points.append(project(x, lidHeight * sin(angle), lidHeight * cos(angle)))
            }
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }()

    /// Draws the laptop with `bounds` scaled by `scale` and its lower-left corner at `origin`.
    static func draw(openness: CGFloat, screen: ModeIllustration.Screen, origin: CGPoint, scale: CGFloat, context ctx: CGContext) {
        func p(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            let q = project(x, y, z)
            return CGPoint(x: origin.x + (q.x - bounds.minX) * scale, y: origin.y + (q.y - bounds.minY) * scale)
        }
        let w = width / 2
        let topBL = p(-w, 0, 0), topBR = p(w, 0, 0), topFR = p(w, 0, depth), topFL = p(-w, 0, depth)
        let bottomBL = p(-w, -thickness, 0), bottomFL = p(-w, -thickness, depth), bottomFR = p(w, -thickness, depth)

        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineWidth(0.75)

        // Base: the visible front and left sides, then the deck with keyboard and trackpad.
        fill([topFL, topFR, bottomFR, bottomFL], Palette.baseFront, ctx)
        fill([topBL, topFL, bottomFL, bottomBL], Palette.baseSide, ctx)
        fill([topBL, topBR, topFR, topFL], Palette.baseTop, ctx)
        let deck = Plane(origin: topBL, uEnd: topBR, vEnd: topFL)
        fill(deck.quad(0.07, 0.93, 0.1, 0.5), Palette.keyboard, ctx)
        fill(deck.quad(0.36, 0.64, 0.6, 0.9), Palette.trackpad, ctx)
        stroke([topBL, topBR, topFR, bottomFR, bottomFL, bottomBL], Palette.outline, ctx)

        // Lid, rotating about the hinge.
        let angle = Double(openness) * openAngle
        let ly = lidHeight * sin(angle), lz = lidHeight * cos(angle)
        let lidTL = p(-w, ly, lz), lidTR = p(w, ly, lz)
        let lid = Plane(origin: topBL, uEnd: topBR, vEnd: lidTL)
        let lidQuad = [topBL, topBR, lidTR, lidTL]
        if facesViewer(0, -cos(angle), sin(angle)) {
            fill(lidQuad, Palette.bezel, ctx)
            ctx.saveGState()
            ctx.concatenate(lid.transform(0.05, 0.95, 0.07, 0.93))
            drawScreen(screen, aspect: CGFloat(width * 0.9 / (lidHeight * 0.86)), ctx)
            ctx.restoreGState()
        } else {
            fill(lidQuad, Palette.lidBack, ctx)
        }
        stroke(lidQuad, Palette.outline, ctx)
        ctx.restoreGState()
    }

    /// Draws the display's content in unit coordinates (x across, y up the screen).
    /// `aspect` is the display's width/height, used to keep round things round.
    private static func drawScreen(_ screen: ModeIllustration.Screen, aspect: CGFloat, _ ctx: CGContext) {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        switch screen {
        case .desktop:
            ctx.saveGState()
            ctx.clip(to: unit)
            let colors = [Palette.wallpaperTop.cgColor, Palette.wallpaperBottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1), end: CGPoint(x: 1, y: 0), options: [])
            }
            ctx.restoreGState()
            ctx.setFillColor(NSColor(white: 1, alpha: 0.35).cgColor)
            ctx.fill(CGRect(x: 0, y: 0.89, width: 1, height: 0.11))  // menu bar
            ctx.setFillColor(NSColor(white: 1, alpha: 0.5).cgColor)
            ctx.fill(CGRect(x: 0.28, y: 0.05, width: 0.44, height: 0.1))  // Dock

        case .agent(let progress, let time):
            ctx.setFillColor(Palette.terminal.cgColor)
            ctx.fill(unit)
            // Spinner and a pulsing status line.
            ctx.saveGState()
            ctx.translateBy(x: 0.13, y: 0.8)
            ctx.scaleBy(x: 1, y: aspect)
            Drawing.asterisk(center: .zero, radius: 0.1, rotation: CGFloat(-time * 2.6), color: .claude, in: ctx)
            ctx.restoreGState()
            ctx.setFillColor(NSColor.claude.withAlphaComponent(0.65 + 0.35 * sin(time * 5)).cgColor)
            ctx.fill(CGRect(x: 0.27, y: 0.76, width: 0.4, height: 0.09))
            // Output lines typed one after another; two of them while the lid is closed.
            let lines: [(length: CGFloat, start: Double, end: Double, color: NSColor)] = [
                (0.72, 0.02, 0.16, Palette.output), (0.5, 0.16, 0.3, Palette.added),
                (0.8, 0.5, 0.64, Palette.output), (0.42, 0.64, 0.76, Palette.output),
            ]
            for (index, line) in lines.enumerated() {
                let typed = CGFloat(min(max((progress - line.start) / (line.end - line.start), 0), 1))
                guard typed > 0 else { continue }
                ctx.setFillColor(line.color.cgColor)
                ctx.fill(CGRect(x: 0.08, y: 0.57 - CGFloat(index) * 0.15, width: line.length * typed, height: 0.08))
            }
        }
    }

    private static func fill(_ points: [CGPoint], _ color: NSColor, _ ctx: CGContext) {
        ctx.addLines(between: points)
        ctx.closePath()
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    private static func stroke(_ points: [CGPoint], _ color: NSColor, _ ctx: CGContext) {
        ctx.addLines(between: points)
        ctx.closePath()
        ctx.setStrokeColor(color.cgColor)
        ctx.strokePath()
    }
}

/// A projected rectangle: a parallelogram spanned from `origin` by the vectors to `uEnd` and `vEnd`.
private struct Plane {
    let origin: CGPoint, u: CGVector, v: CGVector

    init(origin: CGPoint, uEnd: CGPoint, vEnd: CGPoint) {
        self.origin = origin
        u = CGVector(dx: uEnd.x - origin.x, dy: uEnd.y - origin.y)
        v = CGVector(dx: vEnd.x - origin.x, dy: vEnd.y - origin.y)
    }

    func point(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + u.dx * a + v.dx * b, y: origin.y + u.dy * a + v.dy * b)
    }

    func quad(_ u0: CGFloat, _ u1: CGFloat, _ v0: CGFloat, _ v1: CGFloat) -> [CGPoint] {
        [point(u0, v0), point(u1, v0), point(u1, v1), point(u0, v1)]
    }

    /// Maps the unit square onto the part of the plane spanning u0...u1 and v0...v1.
    func transform(_ u0: CGFloat, _ u1: CGFloat, _ v0: CGFloat, _ v1: CGFloat) -> CGAffineTransform {
        let o = point(u0, v0)
        return CGAffineTransform(a: u.dx * (u1 - u0), b: u.dy * (u1 - u0), c: v.dx * (v1 - v0), d: v.dy * (v1 - v0),
                                 tx: o.x, ty: o.y)
    }
}

/// The dragon's eye: a golden iris with a slit pupil and an eyelid that closes from the top.
private enum Eye {
    static func draw(openness: CGFloat, center: CGPoint, width: CGFloat, context ctx: CGContext) {
        let height = width * 0.6
        let left = CGPoint(x: center.x - width / 2, y: center.y)
        let right = CGPoint(x: center.x + width / 2, y: center.y)
        let almond = CGMutablePath()
        almond.move(to: left)
        almond.addQuadCurve(to: right, control: CGPoint(x: center.x, y: center.y + height))
        almond.addQuadCurve(to: left, control: CGPoint(x: center.x, y: center.y - height))
        almond.closeSubpath()

        ctx.saveGState()
        ctx.addPath(almond)
        ctx.clip()
        ctx.setFillColor(Palette.sclera.cgColor)
        ctx.fill(almond.boundingBox)

        let r = height * 0.46
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ctx.clip()
        let colors = [Palette.irisInner.cgColor, Palette.irisOuter.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
        }
        ctx.restoreGState()
        ctx.setFillColor(Palette.pupil.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - r * 0.17, y: center.y - r * 0.85, width: r * 0.34, height: r * 1.7))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - r * 0.62, y: center.y + r * 0.2, width: r * 0.32, height: r * 0.32))

        // The eyelid's lower edge sweeps from the top of the eye (open) to the bottom (closed).
        let closure = 1 - openness
        let edge = CGMutablePath()
        edge.move(to: left)
        edge.addQuadCurve(to: right, control: CGPoint(x: center.x, y: center.y + height * (1 - 2 * closure)))
        let lid = edge.mutableCopy()!
        lid.addLine(to: CGPoint(x: right.x, y: center.y + height))
        lid.addLine(to: CGPoint(x: left.x, y: center.y + height))
        lid.closeSubpath()
        ctx.addPath(lid)
        ctx.setFillColor(Palette.eyelid.cgColor)
        ctx.fillPath()
        if closure > 0.02 {
            ctx.addPath(edge)
            ctx.setStrokeColor(Palette.eyelidEdge.cgColor)
            ctx.setLineWidth(0.9)
            ctx.strokePath()
        }
        ctx.restoreGState()

        ctx.addPath(almond)
        ctx.setStrokeColor(Palette.outline.cgColor)
        ctx.setLineWidth(0.9)
        ctx.strokePath()

        // Lashes along the lid's edge make the closed eye read as asleep.
        let lashes = ModeIllustration.smoothstep(Double(closure - 0.7) / 0.3)
        guard lashes > 0 else { return }
        let control = CGPoint(x: center.x, y: center.y + height * (1 - 2 * closure))
        ctx.setStrokeColor(Palette.lashes.withAlphaComponent(lashes).cgColor)
        ctx.setLineWidth(0.9)
        ctx.setLineCap(.round)
        for s in [0.22, 0.4, 0.6, 0.78] as [CGFloat] {
            // Point on the edge curve and the downward normal there.
            let a = (1 - s) * (1 - s), b = 2 * (1 - s) * s, c = s * s
            let point = CGPoint(x: a * left.x + b * control.x + c * right.x, y: a * left.y + b * control.y + c * right.y)
            let tangent = CGVector(dx: 2 * (1 - s) * (control.x - left.x) + 2 * s * (right.x - control.x),
                                   dy: 2 * (1 - s) * (control.y - left.y) + 2 * s * (right.y - control.y))
            let length = hypot(tangent.dx, tangent.dy)
            let lash = width * 0.13
            ctx.move(to: point)
            ctx.addLine(to: CGPoint(x: point.x + tangent.dy / length * lash, y: point.y - tangent.dx / length * lash))
        }
        ctx.strokePath()
    }
}
