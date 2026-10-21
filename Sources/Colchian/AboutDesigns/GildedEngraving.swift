import AppKit
import CoreText

/// The About panel's artwork, in the manner of a gilded engraving brought to life: on a starry night-blue field
/// framed by a Greek key, the story of the Colchian dragon is set in gold; the dragon flies in from the
/// left, rears up and turns to face the viewer with unblinking amber eyes; then the credits appear.
///
/// The dragon is a small 3D model (a tube along a jointed spine, bat wings and a lofted head) that is
/// posed for each frame, projected, and inked with calligraphic gold lines, so its turn is a true rotation.
enum GildedEngraving: AboutArtwork {
    /// The canvas size the artwork is designed for, in points.
    static let size = CGSize(width: 310, height: 300)

    /// Draws the artwork `time` seconds after the About panel opened, into `rect` (unflipped).
    static func draw(time: Double, in rect: CGRect, context ctx: CGContext, story: String, tagline: String, credits: String) {
        let t = time.isFinite ? max(0, time) : 0
        // The text matrix (and with it the text position) isn't part of the graphics state, so it is put
        // back by hand when we're done.
        let textMatrix = ctx.textMatrix
        defer { ctx.textMatrix = textMatrix }
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.clip()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Once the story, the tagline and the credits have settled they are part of the (cached) backdrop.
        Backdrop.draw(in: rect, time: t, story: story, tagline: tagline, credits: credits, context: ctx)
        if t < Beat.story.upperBound { Lettering.drawStory(story, in: rect, time: t, context: ctx) }
        Lettering.drawCodaGlow(story, in: rect, strength: Pose.eyeBloom(at: t), context: ctx)
        Lettering.drawFleeceSheen(story, in: rect, time: t, context: ctx)
        if t < Beat.tagline.upperBound { Lettering.drawTagline(tagline, story: story, in: rect, time: t, context: ctx) }
        Sky.draw(in: rect, time: t, context: ctx)
        Dragon.draw(in: rect, time: t, context: ctx)
        if t < Beat.credits.upperBound { Lettering.drawCredits(credits, in: rect, time: t, context: ctx) }
        ctx.restoreGState()
    }
}

// MARK: - Timeline

/// When each beat happens, in seconds since the About button was clicked (the menu is fully open at 0.4 s).
private enum Beat {
    static let border = 0.0...1.5        // the Greek key is engraved around the canvas
    static let story = 0.4...2.1         // the story appears word by word, then, after a pause, its coda
    static let flight = 1.85...3.95      // the dragon flies in from the left edge
    static let rise = 3.3...4.6          // it rears up into a hover
    static let headTurn = 3.55...4.75    // its head turns to the viewer...
    static let bodyTurn = 3.8...5.15     // ...and its body follows
    static let gaze = 4.45...5.35        // its eyes kindle as they meet the viewer's
    static let flash = 4.7...5.15        // ...and a star of light flares in each
    static let settle = 4.6...6.0        // the wingbeats calm into slow breathing
    static let idle = 5.0...6.5          // idle motions fade in
    static let tagline = 5.45...6.35     // a closing line fades in below the story
    static let credits = 6.95...8.05     // after a pause, the credits appear
}

private func progress(_ t: Double, _ range: ClosedRange<Double>) -> CGFloat {
    CGFloat(min(max((t - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1))
}

private func smooth(_ x: CGFloat) -> CGFloat {
    let x = min(max(x, 0), 1)
    return x * x * (3 - 2 * x)
}

private func smoother(_ x: CGFloat) -> CGFloat {
    let x = min(max(x, 0), 1)
    return x * x * x * (x * (x * 6 - 15) + 10)
}

private func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

private func wave(_ t: Double, _ period: Double, _ phase: Double = 0) -> CGFloat {
    CGFloat(sin(2 * .pi * t / period + phase))
}

/// How far `t` is into a gesture that recurs every `period` seconds from `start` and lasts `duration`:
/// 0...1 while it lasts, nil the rest of the time.
private func window(_ t: Double, every period: Double, for duration: Double, from start: Double) -> CGFloat? {
    guard t > start else { return nil }
    let u = (t - start).truncatingRemainder(dividingBy: period)
    return u < duration ? CGFloat(u / duration) : nil
}

/// A gesture that recurs every `period` seconds from `start`: a smooth bump `duration` long that is exactly
/// zero, with zero slope, outside it, so the gesture eases in and out and never jumps.
private func occasionally(_ t: Double, every period: Double, for duration: Double, from start: Double) -> CGFloat {
    guard let u = window(t, every: period, for: duration, from: start) else { return 0 }
    let s = sin(.pi * u)
    return s * s
}

/// Which way the `period`-long gesture that `t` falls in leans: +1 and -1 by turns.
private func alternate(_ t: Double, every period: Double, from start: Double) -> CGFloat {
    (max(0, t - start) / period).rounded(.down).truncatingRemainder(dividingBy: 2) == 0 ? 1 : -1
}

// MARK: - Palette

private enum Palette {
    static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor { NSColor(hex: hex, alpha: alpha).cgColor }

    static func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient? {
        CGGradient(colorsSpace: space, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: stops.map { $0.2 })
    }

    static let night = color(0x060A16)
    static let gold = color(0xD9B466)
    static let goldDeep = color(0xA77E38)
    static let goldFaint = color(0xD9B466, 0.55)
    static let hide = color(0x0C2722)   // a deep emerald enamel, echoing the green lid of the app's dragon eye
    static let membrane = color(0x111B3A)
    static let membraneWash = gradient([(0xF0C46A, 0.26, 0), (0xD9A24A, 0.12, 0.5), (0xB98236, 0.035, 1)])
    static let groove = color(0x0A1022, 0.85)
    static let tongue = color(0xD8553A)
    static let sheen = gradient([(0xFFF8E2, 0, 0), (0xFFF8E2, 0.95, 0.5), (0xFFF8E2, 0, 1)])
    static let bellySheen = gradient([(0xE2B868, 0.16, 0), (0xD9B466, 0.1, 0.45), (0xD9B466, 0.05, 1)])

    static let vignette = gradient([(0x1A2445, 1, 0), (0x0F1630, 1, 0.45), (0x060A16, 1, 1)])
    static let textGold = gradient([(0xFFF5D2, 1, 0), (0xF2D48C, 1, 0.45), (0xD3A659, 1, 1)])
    static let textEdge = color(0xE9C77E, 0.9)
    static let iris = gradient([(0xFFF8D2, 1, 0), (0xFFD24A, 1, 0.3), (0xF39A1C, 1, 0.68), (0xA1400C, 1, 1)])
    static let eyeHalo = gradient([(0xFFB23A, 0.55, 0), (0xFF8A1E, 0.2, 0.45), (0xFF7A10, 0, 1)])
    static let ember = gradient([(0xFFB347, 0.36, 0), (0xF27B2B, 0.16, 0.45), (0xD0501C, 0, 1)])
    static let spark = gradient([(0xFFF6D8, 1, 0), (0xF6D27A, 0.6, 0.3), (0xE0A84A, 0, 1)])
}

// MARK: - Vectors and projection

private struct V3 {
    var x: CGFloat, y: CGFloat, z: CGFloat
    init(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) { self.x = x; self.y = y; self.z = z }
    static let zero = V3(0, 0, 0)
    static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: V3, s: CGFloat) -> V3 { V3(a.x * s, a.y * s, a.z * s) }
    static prefix func - (a: V3) -> V3 { V3(-a.x, -a.y, -a.z) }
    func dot(_ b: V3) -> CGFloat { x * b.x + y * b.y + z * b.z }
    func cross(_ b: V3) -> V3 { V3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    var length: CGFloat { sqrt(dot(self)) }
    var normalized: V3 { let l = length; return l > 1e-6 ? self * (1 / l) : self }
    /// Rotated about the y axis so that +x turns toward +z.
    func yawed(_ angle: CGFloat) -> V3 { V3(x * cos(angle) - z * sin(angle), y, x * sin(angle) + z * cos(angle)) }
    /// Rotated about the z axis so that +x turns toward +y.
    func pitched(_ angle: CGFloat) -> V3 { V3(x * cos(angle) - y * sin(angle), x * sin(angle) + y * cos(angle), z) }
    /// Rotated about the x axis so that +y turns toward +z.
    func rolled(_ angle: CGFloat) -> V3 { V3(x, y * cos(angle) - z * sin(angle), y * sin(angle) + z * cos(angle)) }
}

private extension CGPoint {
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    func lerp(_ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: x + (b.x - x) * t, y: y + (b.y - y) * t) }
    var length: CGFloat { hypot(x, y) }
}

/// Maps the dragon's body space (x forward, y up, z to its right; origin at the shoulders) onto the canvas:
/// the body is banked by `roll`, turned by `yaw` and moved to `position` on the stage, which a camera looks
/// at from slightly above.
private struct Projector {
    let cosYaw: CGFloat, sinYaw: CGFloat, cosRoll: CGFloat, sinRoll: CGFloat
    let position: V3
    let origin: CGPoint
    let cosE: CGFloat, sinE: CGFloat
    let distance: CGFloat
    /// Where the light comes from (upper left, in front), in stage space.
    static let light = V3(-0.5, 0.7, 0.5).normalized

    init(yaw: CGFloat, roll: CGFloat, position: V3, origin: CGPoint, elevation: CGFloat = 0.15, distance: CGFloat = 760) {
        cosYaw = cos(yaw); sinYaw = sin(yaw)
        cosRoll = cos(roll); sinRoll = sin(roll)
        self.position = position
        self.origin = origin
        cosE = cos(elevation); sinE = sin(elevation)
        self.distance = distance
    }

    func direction(_ v: V3) -> V3 {
        let y = v.y * cosRoll - v.z * sinRoll, z = v.y * sinRoll + v.z * cosRoll
        return V3(v.x * cosYaw - z * sinYaw, y, v.x * sinYaw + z * cosYaw)
    }

    /// How brightly a surface with body-space normal `n` is lit: 1 facing the light, below 0 in shadow.
    func lighting(_ n: V3) -> CGFloat { direction(n).dot(Projector.light) }

    func depth(_ p: V3) -> CGFloat {
        let w = direction(p) + position
        return w.z * cosE + w.y * sinE
    }

    func scale(_ p: V3) -> CGFloat { distance / (distance - depth(p)) }

    func point(_ p: V3) -> CGPoint {
        let w = direction(p) + position
        let s = distance / (distance - (w.z * cosE + w.y * sinE))
        return CGPoint(x: origin.x + w.x * s, y: origin.y + (w.y * cosE - w.z * sinE) * s)
    }

    /// How directly a surface with body-space normal `n` faces the viewer: 1 head-on, below 0 facing away.
    func facing(_ n: V3) -> CGFloat {
        let w = direction(n)
        return w.z * cosE + w.y * sinE
    }
}

// MARK: - Pen work

private enum Ink {
    /// Adds the convex hull of two circles to `path`, counterclockwise; a chain of these is a smooth tube.
    static func addCapsule(_ path: CGMutablePath, _ p0: CGPoint, _ r0: CGFloat, _ p1: CGPoint, _ r1: CGFloat) {
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let d = hypot(dx, dy)
        if d <= abs(r0 - r1) + 0.01 {
            let (c, r) = r0 > r1 ? (p0, r0) : (p1, r1)
            path.move(to: CGPoint(x: c.x + r, y: c.y))
            path.addArc(center: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.closeSubpath()
            return
        }
        let base = atan2(dy, dx), spread = acos((r0 - r1) / d)
        path.move(to: CGPoint(x: p1.x + r1 * cos(base - spread), y: p1.y + r1 * sin(base - spread)))
        path.addArc(center: p1, radius: r1, startAngle: base - spread, endAngle: base + spread, clockwise: false)
        path.addArc(center: p0, radius: r0, startAngle: base + spread, endAngle: base - spread + 2 * .pi, clockwise: false)
        path.closeSubpath()
    }

    /// A calligraphic stroke: the outline of a pen line along `points` whose width follows `widths`.
    static func ribbon(_ points: [CGPoint], _ widths: [CGFloat], into path: CGMutablePath) {
        let n = points.count
        guard n >= 2, widths.count == n else { return }
        var left = [CGPoint](), right = [CGPoint]()
        left.reserveCapacity(n); right.reserveCapacity(n)
        for i in 0..<n {
            let a = points[max(i - 1, 0)], b = points[min(i + 1, n - 1)]
            let l = max(hypot(b.x - a.x, b.y - a.y), 1e-4)
            let nx = -(b.y - a.y) / l, ny = (b.x - a.x) / l
            let h = widths[i] / 2
            left.append(CGPoint(x: points[i].x + nx * h, y: points[i].y + ny * h))
            right.append(CGPoint(x: points[i].x - nx * h, y: points[i].y - ny * h))
        }
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        for p in right.reversed() { path.addLine(to: p) }
        path.closeSubpath()
    }

    /// Adds the parts of the polyline `samples` where their value is positive, cut at the interpolated
    /// zero crossings so that the visible stretch grows and shrinks smoothly.
    static func trace(_ samples: [(CGPoint, CGFloat)], into path: CGMutablePath) {
        var open = false
        for k in 0..<samples.count {
            let (p, v) = samples[k]
            if v > 0 {
                if !open {
                    if k > 0, samples[k - 1].1 <= 0 {
                        let (q, w) = samples[k - 1]
                        path.move(to: q.lerp(p, w / (w - v)))
                        path.addLine(to: p)
                    } else {
                        path.move(to: p)
                    }
                    open = true
                } else {
                    path.addLine(to: p)
                }
            } else if open {
                let (q, w) = samples[k - 1]
                path.addLine(to: q.lerp(p, w / (w - v)))
                open = false
            }
        }
    }

    /// Widths that swell from `start` to `peak` (at `at`, 0...1) and taper to `end`.
    static func taper(_ n: Int, _ start: CGFloat, _ peak: CGFloat, _ end: CGFloat, at: CGFloat = 0.3, scale: CGFloat = 1) -> [CGFloat] {
        (0..<n).map { i in
            let u = CGFloat(i) / CGFloat(max(n - 1, 1))
            let w = u < at ? mix(start, peak, smooth(u / at)) : mix(peak, end, smooth((u - at) / (1 - at)))
            return w * scale
        }
    }

    /// Catmull-Rom spline through `points`, with `samples` points per span.
    static func spline(_ points: [CGPoint], samples: Int) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var out = [CGPoint]()
        out.reserveCapacity((points.count - 1) * samples + 1)
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            for s in 0..<samples {
                let t = CGFloat(s) / CGFloat(samples), t2 = t * t, t3 = t2 * t
                let a = -0.5 * t3 + t2 - 0.5 * t, b = 1.5 * t3 - 2.5 * t2 + 1
                let c = -1.5 * t3 + 2 * t2 + 0.5 * t, d = 0.5 * t3 - 0.5 * t2
                out.append(CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y))
            }
        }
        out.append(points[points.count - 1])
        return out
    }

    /// The convex hull of `points`, counterclockwise.
    static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let s = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        guard s.count > 2 else { return s }
        func turn(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower = [CGPoint](), upper = [CGPoint]()
        for p in s {
            while lower.count >= 2 && turn(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in s.reversed() {
            while upper.count >= 2 && turn(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }

    /// Inks a shape like an engraver: a gold outline that is fine on the lit (upper left) side and swells,
    /// in a deeper gold, on the shaded side; then the dark body of the shape. `rounding` grows the shape
    /// itself (for polygons).
    static func engrave(_ path: CGPath, weight: CGFloat, swell: CGFloat, rounding: CGFloat = 0,
                        fill: CGColor = Palette.hide, in ctx: CGContext) {
        ctx.setLineWidth(2 * (rounding + weight))
        for (color, offset) in [(Palette.goldDeep, swell), (Palette.gold, 0)] {
            ctx.saveGState()
            ctx.translateBy(x: offset * 0.55, y: -offset * 0.85)
            ctx.setFillColor(color)
            ctx.setStrokeColor(color)
            ctx.addPath(path)
            ctx.drawPath(using: .fillStroke)
            ctx.restoreGState()
        }
        ctx.setFillColor(fill)
        ctx.addPath(path)
        if rounding > 0 {
            ctx.setStrokeColor(fill)
            ctx.setLineWidth(2 * rounding)
            ctx.drawPath(using: .fillStroke)
        } else {
            ctx.fillPath()
        }
    }

    /// The same engraving for a shape given as filled regions: `outer` is the shape grown by the line
    /// weight, `inner` the shape itself. (Filling is much cheaper than stroking a union of many pieces.)
    static func engrave(outer: CGPath, inner: CGPath, swell: CGFloat, fill: CGColor = Palette.hide, in ctx: CGContext) {
        for (color, offset) in [(Palette.goldDeep, swell), (Palette.gold, 0)] {
            ctx.saveGState()
            ctx.translateBy(x: offset * 0.55, y: -offset * 0.85)
            ctx.setFillColor(color)
            ctx.addPath(outer)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.setFillColor(fill)
        ctx.addPath(inner)
        ctx.fillPath()
    }

    static func polygon(_ points: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    /// A slender four-pointed star, like a glint of light on gold.
    static func star(at c: CGPoint, radius r: CGFloat, color: CGColor, in ctx: CGContext) {
        guard r > 0.05 else { return }
        let w = r * 0.13
        let star = CGMutablePath()
        star.addLines(between: [CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x + w, y: c.y + w), CGPoint(x: c.x + r, y: c.y),
                                CGPoint(x: c.x + w, y: c.y - w), CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - w, y: c.y - w),
                                CGPoint(x: c.x - r, y: c.y), CGPoint(x: c.x - w, y: c.y + w)])
        star.closeSubpath()
        ctx.setFillColor(color)
        ctx.addPath(star)
        ctx.fillPath()
    }

    /// A soft round glow (a small radial gradient).
    static func glow(_ gradient: CGGradient?, at c: CGPoint, radius: CGFloat, alpha: CGFloat, in ctx: CGContext) {
        guard let gradient, alpha > 0.005, radius > 0.1 else { return }
        ctx.saveGState()
        ctx.setAlpha(min(alpha, 1))
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
        ctx.restoreGState()
    }
}

// MARK: - Backdrop

/// The night-blue field with its Greek-key border, and the lettering once it has settled. These never
/// change, so each stage is drawn once per scale into a layer. While the panel opens, the border is
/// revealed as if engraved, from the top center down both sides.
private enum Backdrop {
    private enum Stage: Int { case plain, framed, story, tagline, complete }
    private struct Key: Equatable { let size: CGSize, scale: CGFloat, story: String, tagline: String, credits: String }
    // Caches, used only while drawing (on the main thread).
    private static var key: Key?
    private static var layers: [Stage: CGLayer] = [:]

    static func draw(in rect: CGRect, time t: Double, story: String, tagline: String, credits: String, context ctx: CGContext) {
        let m = ctx.userSpaceToDeviceSpaceTransform
        let scale = max(1, min(4, (hypot(m.a, m.b) * 2).rounded() / 2))
        let current = Key(size: rect.size, scale: scale, story: story, tagline: tagline, credits: credits)
        if key != current {
            key = current
            layers.removeAll()
        }
        func show(_ stage: Stage) {
            if let layer = layer(stage, current, like: ctx) {
                ctx.draw(layer, in: rect)
            } else {
                paint(stage, current, in: ctx, at: rect.origin)
            }
        }
        if t >= Beat.credits.upperBound { return show(.complete) }
        if t >= Beat.tagline.upperBound { return show(.tagline) }
        if t >= Beat.story.upperBound { return show(.story) }
        let reveal = progress(t, Beat.border)
        if reveal >= 1 { return show(.framed) }
        show(.plain)
        guard reveal > 0 else { return }
        // Two burins travel at an even pace from the top center down both sides of the border to the bottom
        // center; a wedge from the canvas center through each one uncovers the engraving behind it.
        let band = rect.insetBy(dx: 9.8, dy: 9.8)
        let travel = smooth(reveal) * (band.width + band.height) * 1.02
        let burin = Backdrop.along(band, travel)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let reached = atan2(burin.y - center.y, burin.x - center.x)   // the right-hand burin's angle
        var sweep = CGFloat.pi / 2 - reached
        if sweep < 0 { sweep += 2 * .pi }
        if travel >= band.width + band.height { sweep = .pi * 1.01 }
        let wedge = CGMutablePath()
        wedge.move(to: center)
        wedge.addArc(center: center, radius: 400, startAngle: .pi / 2 - sweep, endAngle: .pi / 2 + sweep, clockwise: false)
        wedge.closeSubpath()
        ctx.saveGState()
        ctx.addPath(wedge)
        ctx.clip()
        show(.framed)
        ctx.restoreGState()
        // The burin's glint at each leading edge.
        let glint = 0.9 * (1 - smooth((reveal - 0.85) / 0.15))
        for p in [burin, CGPoint(x: 2 * center.x - burin.x, y: burin.y)] {
            Ink.glow(Palette.spark, at: p, radius: 7, alpha: glint, in: ctx)
        }
    }

    /// The point `distance` along `band`'s outline, clockwise from the middle of its top edge (and no
    /// further than the middle of its bottom edge).
    private static func along(_ band: CGRect, _ distance: CGFloat) -> CGPoint {
        let half = band.width / 2
        if distance <= half { return CGPoint(x: band.midX + distance, y: band.maxY) }
        if distance <= half + band.height { return CGPoint(x: band.maxX, y: band.maxY - (distance - half)) }
        return CGPoint(x: max(band.midX, band.maxX - (distance - half - band.height)), y: band.minY)
    }

    /// The layer for `stage`, drawn on first use. Only this stage's neighbors are kept (the border's reveal
    /// shows .plain and .framed together), so at most two layers are held, also after the panel reopens.
    private static func layer(_ stage: Stage, _ key: Key, like ctx: CGContext) -> CGLayer? {
        if let layer = layers[stage] { return layer }
        let size = CGSize(width: key.size.width * key.scale, height: key.size.height * key.scale)
        guard let layer = CGLayer(ctx, size: size, auxiliaryInfo: nil), let lctx = layer.context else { return nil }
        lctx.scaleBy(x: key.scale, y: key.scale)
        paint(stage, key, in: lctx, at: .zero)
        layers = layers.filter { abs($0.key.rawValue - stage.rawValue) == 1 }
        layers[stage] = layer
        return layer
    }

    private static func paint(_ stage: Stage, _ key: Key, in ctx: CGContext, at origin: CGPoint) {
        let r = CGRect(origin: origin, size: key.size)
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setFillColor(Palette.night)
        ctx.fill(r)
        // A lamplit field behind the dragon's post.
        if let vignette = Palette.vignette {
            let c = CGPoint(x: r.midX, y: r.minY + r.height * 0.48)
            ctx.drawRadialGradient(vignette, startCenter: c, startRadius: 0, endCenter: c, endRadius: r.height * 0.78,
                                   options: [.drawsAfterEndLocation])
        }
        // Fine engraved ruling across the field.
        ctx.setStrokeColor(Palette.color(0x9FB4FF, 0.035))
        ctx.setLineWidth(0.35)
        var y = r.minY + 16
        while y < r.maxY - 16 {
            ctx.move(to: CGPoint(x: r.minX + 16, y: y))
            ctx.addLine(to: CGPoint(x: r.maxX - 16, y: y))
            y += 2.2
        }
        ctx.strokePath()
        if stage.rawValue >= Stage.framed.rawValue { border(r, in: ctx) }
        if stage.rawValue >= Stage.story.rawValue { Lettering.drawStory(key.story, in: r, time: .infinity, context: ctx) }
        if stage.rawValue >= Stage.tagline.rawValue {
            Lettering.drawTagline(key.tagline, story: key.story, in: r, time: .infinity, context: ctx)
        }
        if stage == .complete { Lettering.drawCredits(key.credits, in: r, time: .infinity, context: ctx) }
        ctx.restoreGState()
    }

    /// Thin rules around a running Greek key, with small squares at the corners.
    private static func border(_ r: CGRect, in ctx: CGContext) {
        let outer: CGFloat = 4.5, band: CGFloat = 7, unit: CGFloat = 1.4, inner: CGFloat = 14.6
        let depth = 4 * unit
        ctx.setStrokeColor(Palette.color(0xD9B466, 0.8))
        ctx.setLineWidth(0.6)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: outer, dy: outer), cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.addRect(r.insetBy(dx: inner, dy: inner))
        ctx.strokePath()

        let key = CGMutablePath()
        let lo = band + depth
        // (origin, along, across) for the top, right, bottom and left runs; `across` points outward.
        let runs: [(CGPoint, CGVector, CGVector, CGFloat)] = [
            (CGPoint(x: r.minX + lo, y: r.maxY - lo), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1), r.width - 2 * lo),
            (CGPoint(x: r.maxX - lo, y: r.maxY - lo), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0), r.height - 2 * lo),
            (CGPoint(x: r.maxX - lo, y: r.minY + lo), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1), r.width - 2 * lo),
            (CGPoint(x: r.minX + lo, y: r.minY + lo), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0), r.height - 2 * lo),
        ]
        let motif: [(CGFloat, CGFloat)] = [(0, 0), (0, 4), (4, 4), (4, 1), (3, 1), (3, 3), (1, 3), (1, 0), (5, 0)]
        for (origin, along, across, length) in runs {
            let periods = max(1, Int((length / (5 * unit)).rounded()))
            let step = length / CGFloat(5 * periods)
            for k in 0..<periods {
                for (i, m) in motif.enumerated() {
                    let a = (CGFloat(k) * 5 + m.0) * step, b = m.1 * unit
                    let p = CGPoint(x: origin.x + along.dx * a + across.dx * b, y: origin.y + along.dy * a + across.dy * b)
                    if i == 0 && k == 0 { key.move(to: p) } else { key.addLine(to: p) }
                }
            }
        }
        // Corner squares, each with a lozenge.
        let corners = [CGPoint(x: r.minX + band, y: r.maxY - lo), CGPoint(x: r.maxX - lo, y: r.maxY - lo),
                       CGPoint(x: r.minX + band, y: r.minY + band), CGPoint(x: r.maxX - lo, y: r.minY + band)]
        for corner in corners { key.addRect(CGRect(origin: corner, size: CGSize(width: depth, height: depth))) }
        ctx.setStrokeColor(Palette.color(0xD9B466, 0.75))
        ctx.setLineWidth(0.55)
        ctx.addPath(key)
        ctx.strokePath()
        ctx.setFillColor(Palette.color(0xE8CC88, 0.85))
        for corner in corners {
            let c = CGPoint(x: corner.x + depth / 2, y: corner.y + depth / 2), h = depth * 0.32
            ctx.addLines(between: [CGPoint(x: c.x, y: c.y + h), CGPoint(x: c.x + h, y: c.y), CGPoint(x: c.x, y: c.y - h), CGPoint(x: c.x - h, y: c.y)])
            ctx.closePath()
        }
        ctx.fillPath()
    }
}

// MARK: - Night sky

/// Golden stars scattered over the night field between the story and the credits. They come out one by one,
/// the brightest first, as at dusk, and twinkle gently; once the dragon has settled, the brightest glint in turn.
private enum Sky {
    private struct Star {
        let x: CGFloat, y: CGFloat   // from the canvas's lower left corner
        let size: CGFloat            // the length of its long rays, or a dot's radius
        let rays: Int                // 0 for a dot, 4, or 8 (four long and four short)
        let brightness: CGFloat
        let period: Double, phase: Double   // its twinkle
        let rise: Double             // when it comes out
    }

    /// The brightest stars (x, y, size), placed where the dragon doesn't cover them once it faces us.
    private static let bright: [(CGFloat, CGFloat, CGFloat)] = [(41, 205, 3.4), (266, 197, 3.1), (240, 86, 3.2)]
    /// Lesser eight-rayed stars.
    private static let lesser: [(CGFloat, CGFloat, CGFloat)] = [(98, 216, 2.5), (212, 213, 2.4), (30, 140, 2.4),
                                                                  (282, 132, 2.3), (72, 78, 2.6), (192, 60, 2.3)]

    private static let stars: [Star] = {
        // A fixed seed, so the sky is the same every time.
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func random(_ range: ClosedRange<CGFloat>) -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(seed >> 11) / CGFloat(1 << 53)
        }
        var stars = [Star]()
        func add(_ x: CGFloat, _ y: CGFloat, size: CGFloat, rays: Int, brightness: CGFloat, rise: Double) {
            stars.append(Star(x: x, y: y, size: size, rays: rays, brightness: brightness,
                              period: Double(random(2.6...6.4)), phase: Double(random(0...(2 * .pi))), rise: rise))
        }
        for (k, (x, y, size)) in bright.enumerated() { add(x, y, size: size, rays: 8, brightness: 0.95, rise: 0.55 + 0.15 * Double(k)) }
        for (k, (x, y, size)) in lesser.enumerated() { add(x, y, size: size, rays: 8, brightness: 0.85, rise: 1.0 + 0.1 * Double(k)) }
        // The rest are strewn at random over the field, clear of the dragon's head and of each other: small
        // four-pointed stars, then dots of star dust.
        let field = CGRect(x: 20, y: 54, width: 270, height: 166), head = CGPoint(x: 155, y: 190)
        var attempts = 0
        while stars.count < 64, attempts < 5000 {
            attempts += 1
            let p = CGPoint(x: random(field.minX...field.maxX), y: random(field.minY...field.maxY))
            guard (p - head).length > 36, !stars.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 10 }) else { continue }
            if stars.count < 30 {
                add(p.x, p.y, size: random(1.3...2.0), rays: 4, brightness: random(0.6...0.85), rise: Double(random(1.4...2.3)))
            } else {
                add(p.x, p.y, size: random(0.45...0.75), rays: 0, brightness: random(0.4...0.7), rise: Double(random(1.8...2.8)))
            }
        }
        return stars
    }()

    static func draw(in rect: CGRect, time t: Double, context ctx: CGContext) {
        let glint = self.glint(at: t)
        for (index, star) in stars.enumerated() {
            let shown = smooth(CGFloat((t - star.rise) / 0.7))
            guard shown > 0 else { continue }
            let twinkle = wave(t, star.period, star.phase)
            let c = CGPoint(x: rect.minX + star.x, y: rect.minY + star.y)
            guard star.rays > 0 else {
                let r = star.size
                ctx.setFillColor(Palette.color(0xE6CB8E, shown * star.brightness * (0.82 + 0.18 * twinkle)))
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                continue
            }
            var size = star.size * (0.9 + 0.1 * twinkle)
            if star.rays == 8 {
                // A soft halo, which swells as one of the brightest glints.
                let flare = glint?.index == index ? glint?.strength ?? 0 : 0
                let halo: CGFloat = index < bright.count ? 0.22 : 0.1
                Ink.glow(Palette.spark, at: c, radius: size * (1.6 + 1.6 * flare), alpha: shown * (halo + 0.4 * flare), in: ctx)
                size *= 1 + 0.8 * flare
            }
            let path = CGMutablePath()
            addStar(to: path, at: c, size: size, rays: star.rays)
            ctx.setFillColor(Palette.color(0xF8E6B0, shown * star.brightness * (0.8 + 0.2 * twinkle)))
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    /// Which of the brightest stars glints at `t`, and how strongly: each in turn, every few seconds, once the
    /// dragon has settled.
    private static func glint(at t: Double) -> (index: Int, strength: CGFloat)? {
        let start = 8.65, period = 7.7
        let strength = occasionally(t, every: period, for: 1.6, from: start)
        guard strength > 0 else { return nil }
        return (Int((t - start) / period) % bright.count, strength)
    }

    /// A star whose four long rays point up, down and to the sides, with four short ones between them
    /// when it has eight.
    private static func addStar(to path: CGMutablePath, at c: CGPoint, size: CGFloat, rays: Int) {
        let waist = size * (rays == 8 ? 0.13 : 0.2)
        for k in 0..<rays {
            let angle = CGFloat(k) * 2 * .pi / CGFloat(rays), between = angle + .pi / CGFloat(rays)
            let reach = rays == 8 && k % 2 == 1 ? size * 0.45 : size
            let tip = CGPoint(x: c.x + reach * sin(angle), y: c.y + reach * cos(angle))
            if k == 0 { path.move(to: tip) } else { path.addLine(to: tip) }
            path.addLine(to: CGPoint(x: c.x + waist * sin(between), y: c.y + waist * cos(between)))
        }
        path.closeSubpath()
    }
}

// MARK: - Lettering

private struct PlacedWord {
    let text: String
    let line: CTLine
    let x: CGFloat           // from the text column's left edge
    let baseline: CGFloat    // below the column's top
    let ascent: CGFloat, descent: CGFloat
    let coda: Bool           // part of the closing sentence
    var start: Double = 0    // when it begins to appear
}

/// The story, the tagline and the credits, set in Baskerville and gilded with a gradient.
private enum Lettering {
    static let column: CGFloat = 264
    // Caches, used only while drawing (on the main thread).
    private static var storyCache: (story: String, words: [PlacedWord], font: NSFont)?
    private static var taglineCache: (tagline: String, story: String, line: TaglineLine)?
    private static var creditsCache: (credits: String, lines: [CreditLine])?
    private static let roman = font("Baskerville", 13)
    private static let lineHeight: CGFloat = 16.5
    /// The story is set in this many lines, at 13 pt, or as much smaller as it takes to fit them.
    private static let storyLines = 2
    private static let title = font("Baskerville", 12, smallCaps: true), small = font("Baskerville", 11)

    static func font(_ name: String, _ size: CGFloat, smallCaps: Bool = false) -> NSFont {
        var font = NSFont(name: name, size: size)
            ?? NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size)
        if smallCaps {
            // Lowercase-to-small-caps (type 37, selector 1) and the older letter-case feature (type 3, selector 3).
            let settings: [[NSFontDescriptor.FeatureKey: Int]] = [
                [.typeIdentifier: 37, .selectorIdentifier: 1], [.typeIdentifier: 3, .selectorIdentifier: 3]]
            font = NSFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: settings]), size: size) ?? font
        }
        return font
    }

    private static func attributes(_ font: NSFont, kern: CGFloat = 0, lineHeight: CGFloat = 0,
                                   alignment: NSTextAlignment = .center) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        if lineHeight > 0 {
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
        }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style,
                                                         NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        // Extra space after each letter, on top of the font's kerning. A kern of exactly 0 would turn the
        // kerning off, so none is set then.
        if kern != 0 { attributes[.kern] = kern }
        return attributes
    }

    /// Lays the story out once, as one paragraph set flush left and centered in the column as a block, in
    /// `storyLines` lines if it can. Its last sentence, if short, is a coda, which follows the rest after a pause.
    /// The coda is never broken across lines: if it doesn't fit after the rest, it starts a line of its own.
    private static func layoutStory(_ story: String) -> (words: [PlacedWord], font: NSFont) {
        var text = story.trimmingCharacters(in: .whitespacesAndNewlines)
        var codaLocation = (text as NSString).length
        if let split = text.range(of: ". ", options: .backwards), text.distance(from: split.upperBound, to: text.endIndex) < 40 {
            codaLocation = NSRange(split.upperBound..., in: text).location
            text = String(text[..<split.upperBound]) + text[split.upperBound...].replacingOccurrences(of: " ", with: "\u{A0}")
        }
        let ns = text as NSString
        let height: CGFloat = 400
        func lines(_ font: NSFont) -> (lines: [CTLine], frame: CTFrame) {
            let framesetter = CTFramesetterCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes(font, lineHeight: lineHeight, alignment: .left)))
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                                 CGPath(rect: CGRect(x: 0, y: 0, width: column, height: height), transform: nil), nil)
            return (CTFrameGetLines(frame) as? [CTLine] ?? [], frame)
        }
        func sized(_ size: CGFloat) -> NSFont { NSFont(descriptor: roman.fontDescriptor, size: size) ?? roman }
        var font = roman
        if lines(roman).lines.count > storyLines {
            // The largest size, to a hundredth of a point, at which the story fits its lines (no smaller than 10 pt).
            var low: CGFloat = 10, high = roman.pointSize
            for _ in 0..<12 {
                let middle = (low + high) / 2
                if lines(sized(middle)).lines.count <= storyLines { low = middle } else { high = middle }
            }
            font = sized((low * 100).rounded(.down) / 100)
        }
        var words = [PlacedWord]()
        let (lines, frame) = lines(font)
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let widest = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth($0)) }.max() ?? 0
        let indent = (column - widest) / 2
        for (line, origin) in zip(lines, origins) {
            let range = CTLineGetStringRange(line)
            for wordRange in wordRanges(in: ns, NSRange(location: range.location, length: range.length)) {
                let word = ns.substring(with: wordRange)
                let wordLine = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: attributes(font)))
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                CTLineGetTypographicBounds(wordLine, &ascent, &descent, &leading)
                let x = indent + origin.x + CTLineGetOffsetForStringIndex(line, wordRange.location, nil)
                // Baselines below the column's top.
                words.append(PlacedWord(text: word, line: wordLine, x: x, baseline: height - origin.y, ascent: ascent,
                                        descent: descent, coda: wordRange.location >= codaLocation))
            }
        }
        // Stagger the words across the story beat. The coda waits until the story has fully appeared and a pause
        // has passed, then comes in at half the pace.
        let fade = 0.42, pause = 0.3
        let codaCount = words.filter(\.coda).count, storyCount = words.count - codaCount
        let span = Beat.story.upperBound - Beat.story.lowerBound - fade - (codaCount > 0 ? fade + pause : 0)
        let step = span / Double(max(storyCount - 1 + 2 * max(codaCount - 1, 0), 1))
        let codaStart = Beat.story.lowerBound + Double(max(storyCount - 1, 0)) * step + fade + pause
        for k in words.indices {
            words[k].start = words[k].coda ? codaStart + Double(k - storyCount) * 2 * step : Beat.story.lowerBound + Double(k) * step
        }
        return (words, font)
    }

    /// The story's layout, made once and then cached.
    private static func layout(of story: String) -> (words: [PlacedWord], font: NSFont) {
        if let cache = storyCache, cache.story == story { return (cache.words, cache.font) }
        let layout = layoutStory(story)
        storyCache = (story, layout.words, layout.font)
        return layout
    }

    /// The ranges of the whitespace-separated words (punctuation included) of `text` within `range`. The scan
    /// steps by whole characters (composed character sequences), so a character outside the Basic Multilingual
    /// Plane, such as an emoji, which takes two UTF-16 units, stays in one piece and the scan always moves on.
    private static func wordRanges(in text: NSString, _ range: NSRange) -> [NSRange] {
        var ranges = [NSRange]()
        var start: Int?, end = range.location   // the word being read: from its first character to past its last
        text.enumerateSubstrings(in: range, options: .byComposedCharacterSequences) { character, characterRange, _, _ in
            let blank = character?.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) } ?? true
            if !blank {
                if start == nil { start = characterRange.location }
                end = NSMaxRange(characterRange)
            } else if let first = start {
                ranges.append(NSRange(location: first, length: end - first))
                start = nil
            }
        }
        if let first = start { ranges.append(NSRange(location: first, length: end - first)) }
        return ranges
    }

    static func drawStory(_ story: String, in rect: CGRect, time t: Double, context ctx: CGContext) {
        guard t > Beat.story.lowerBound else { return }
        let words = layout(of: story).words
        let left = rect.midX - column / 2, top = rect.maxY - 21
        for word in words {
            let p = smooth(CGFloat((t - word.start) / 0.42))
            guard p > 0 else { continue }
            gild(word.line, at: CGPoint(x: left + word.x, y: top - word.baseline - 2.5 * (1 - p)),
                 ascent: word.ascent, descent: word.descent, alpha: p, in: ctx)
        }
    }

    /// The closing sentence ("It never sleeps.") glows for a moment as the dragon's eyes meet ours.
    static func drawCodaGlow(_ story: String, in rect: CGRect, strength: CGFloat, context ctx: CGContext) {
        guard strength > 0.01, let words = storyCache?.words, storyCache?.story == story else { return }
        let left = rect.midX - column / 2, top = rect.maxY - 21
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 5, color: Palette.color(0xFFB23A, 0.8 * strength))
        ctx.setFillColor(Palette.color(0xFFF1C9, 0.7 * strength))
        // Placed exactly as the gilded words beneath, so the glow sits on them.
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.textMatrix = .identity
        for word in words where word.coda {
            ctx.textPosition = CGPoint(x: left + word.x, y: top - word.baseline)
            CTLineDraw(word.line, ctx)
        }
        ctx.restoreGState()
    }

    /// Now and then a gleam of light runs across the words "Golden Fleece", as if the gilding caught the lamp.
    static func drawFleeceSheen(_ story: String, in rect: CGRect, time t: Double, context ctx: CGContext) {
        guard let u = window(t, every: 11.3, for: 1.9, from: 9.05), let words = storyCache?.words, storyCache?.story == story,
              let sheen = Palette.sheen else { return }
        guard let k = words.indices.first(where: { $0 + 1 < words.count && words[$0].text.hasPrefix("Golden")
            && words[$0 + 1].text.hasPrefix("Fleece") }) else { return }
        let left = rect.midX - column / 2, top = rect.maxY - 21
        let pair = [words[k], words[k + 1]]
        let from = left + pair[0].x
        let to = left + pair[1].x + CGFloat(CTLineGetTypographicBounds(pair[1].line, nil, nil, nil))
        let w: CGFloat = 9, x = from - w + (to - from + 2 * w) * smooth(u)
        ctx.saveGState()
        ctx.setAlpha(sin(.pi * u))
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setShouldSubpixelQuantizeFonts(false)
        for word in pair {
            let y = top - word.baseline
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.setTextDrawingMode(.clip)
            ctx.textPosition = CGPoint(x: left + word.x, y: y)
            CTLineDraw(word.line, ctx)
            // A slanted band of light.
            ctx.drawLinearGradient(sheen, start: CGPoint(x: x - w, y: y + 0.5 * w), end: CGPoint(x: x + w, y: y - 0.5 * w), options: [])
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Lays the tagline out once, as the line after the story and flush left with it: in the story's type
    /// (`storyFont`), set smaller only if needed to fit the column on one line.
    private static func layoutTagline(_ tagline: String, below story: [PlacedWord], storyFont: NSFont) -> TaglineLine {
        let text = tagline.trimmingCharacters(in: .whitespacesAndNewlines)
        func line(_ font: NSFont) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes(font)))
        }
        let natural = CGFloat(CTLineGetTypographicBounds(line(storyFont), nil, nil, nil))
        let font = natural > column
            ? NSFont(descriptor: storyFont.fontDescriptor, size: storyFont.pointSize * column / natural) ?? storyFont : storyFont
        let fitted = line(font)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(fitted, &ascent, &descent, &leading))
        return TaglineLine(line: fitted, width: width, ascent: ascent, descent: descent, x: story.map(\.x).min() ?? (column - width) / 2,
                           baseline: (story.map(\.baseline).max() ?? 0) + lineHeight)
    }

    /// The tagline fades in below the story once the dragon has turned to us, rising a little into place.
    static func drawTagline(_ tagline: String, story: String, in rect: CGRect, time t: Double, context ctx: CGContext) {
        let p = smooth(progress(t, Beat.tagline))
        guard p > 0 else { return }
        if taglineCache?.tagline != tagline || taglineCache?.story != story {
            let storyLayout = layout(of: story)
            taglineCache = (tagline, story, layoutTagline(tagline, below: storyLayout.words, storyFont: storyLayout.font))
        }
        guard let line = taglineCache?.line else { return }
        gild(line.line, at: CGPoint(x: rect.midX - column / 2 + line.x, y: rect.maxY - 21 - line.baseline - 2 * (1 - p)),
             ascent: line.ascent, descent: line.descent, alpha: p, in: ctx)
    }

    /// Lays the credits out once: blank lines are dropped, the first line (when there are several) is the
    /// title, and a line too wide for the column is set a little smaller or, failing that, broken in two.
    /// Lines are stacked upward from the bottom of the canvas.
    private static func layoutCredits(_ credits: String) -> [CreditLine] {
        let paragraphs = credits.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var pieces = [(text: String, font: NSFont, kern: CGFloat, alpha: CGFloat)]()
        for (index, text) in paragraphs.enumerated() {
            let isTitle = index == 0 && paragraphs.count > 1
            let kern: CGFloat = isTitle ? 1.0 : 0.1
            for (piece, font) in fitted(text, font: isTitle ? title : small, kern: kern) {
                pieces.append((piece, font, kern, isTitle ? 1 : 0.92))
            }
        }
        var lines = [CreditLine]()
        var baseline: CGFloat = 23
        for piece in pieces.reversed() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: piece.text, attributes: attributes(piece.font, kern: piece.kern)))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            lines.append(CreditLine(text: piece.text, font: piece.font, kern: piece.kern, alpha: piece.alpha, line: line,
                                    width: width, ascent: ascent, descent: descent, baseline: baseline))
            baseline += 15
        }
        return lines.reversed()
    }

    /// `text` in `font`, shrunk by up to a tenth to fit the column; past that, broken into lines that fit.
    private static func fitted(_ text: String, font: NSFont, kern: CGFloat) -> [(String, NSFont)] {
        let room = column - 6
        func width(_ font: NSFont) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes(font, kern: kern)))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        let natural = width(font)
        guard natural > room else { return [(text, font)] }
        // The tracking doesn't scale with the type, so only the letters' share of the width shrinks.
        let tracking = kern * CGFloat((text as NSString).length)
        let shrink = (room - tracking) / max(natural - tracking, 1)
        let size = font.pointSize * max(min(shrink, 1), 0.9)
        let smaller = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        if width(smaller) <= room { return [(text, smaller)] }
        let typesetter = CTTypesetterCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes(smaller, kern: kern)))
        let ns = text as NSString
        var pieces = [(String, NSFont)]()
        var start = 0
        while start < ns.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(room))
            guard count > 0 else { break }
            let piece = ns.substring(with: NSRange(location: start, length: count)).trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append((piece, smaller)) }
            start += count
        }
        return pieces
    }

    static func drawCredits(_ credits: String, in rect: CGRect, time t: Double, context ctx: CGContext) {
        let p = progress(t, Beat.credits)
        guard p > 0 else { return }
        if creditsCache?.credits != credits { creditsCache = (credits, layoutCredits(credits)) }
        guard let lines = creditsCache?.lines else { return }
        let fade = smooth(p), gather = 1 - smooth(p * 1.15)
        for credit in lines {
            // The letters draw together as they appear, never spreading wider than the column.
            let room = max((column - 6 - credit.width) / CGFloat(max(credit.text.count - 1, 1)), 0)
            let spread = max(min(1.6, room) * gather, 0)
            // The settled line is used only once the spread is exactly 0 (`gather` gets there at p = 1/1.15):
            // switching any earlier would drop the leftover tracking all at once, and the line would jump.
            let settled = spread == 0
            let line = settled ? credit.line
                : CTLineCreateWithAttributedString(NSAttributedString(string: credit.text, attributes: attributes(credit.font, kern: credit.kern + spread)))
            let width = settled ? credit.width : CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            // Centered on its letters: the tracking after the last one doesn't count.
            let x = rect.midX - (width - credit.kern - spread) / 2
            gild(line, at: CGPoint(x: x, y: rect.minY + credit.baseline + 1.5 * (1 - fade)),
                 ascent: credit.ascent, descent: credit.descent, alpha: fade * credit.alpha, in: ctx)
        }
    }

    /// Draws a line of text filled with a gold gradient. The gradient is confined to the line's own ink box,
    /// so a line with nothing to clip to (only spaces, say) can never flood the canvas.
    static func gild(_ line: CTLine, at origin: CGPoint, ascent: CGFloat, descent: CGFloat, alpha: CGFloat, in ctx: CGContext) {
        guard alpha > 0.004, CTLineGetGlyphCount(line) > 0, let gradient = Palette.textGold else { return }
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !ink.isNull, ink.width > 0, ink.height > 0 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.clip(to: ink.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: -1))
        // Glyphs placed at fractional positions, so text drifting by a fraction of a pixel moves smoothly.
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.textMatrix = .identity
        ctx.textPosition = origin
        // A hairline of gold around each letter gives the thin Baskerville strokes a little more body.
        ctx.setTextDrawingMode(.stroke)
        ctx.setLineWidth(0.32)
        ctx.setStrokeColor(Palette.textEdge)
        CTLineDraw(line, ctx)
        ctx.setTextDrawingMode(.clip)
        ctx.textPosition = origin
        CTLineDraw(line, ctx)
        ctx.drawLinearGradient(gradient, start: CGPoint(x: origin.x, y: origin.y + ascent * 0.85),
                               end: CGPoint(x: origin.x, y: origin.y - descent * 0.6),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
}

/// The tagline, laid out once.
private struct TaglineLine {
    let line: CTLine
    let width: CGFloat, ascent: CGFloat, descent: CGFloat
    let x: CGFloat           // from the text column's left edge
    let baseline: CGFloat    // below the text column's top
}

/// A line of the credits, laid out once.
private struct CreditLine {
    let text: String
    let font: NSFont
    let kern: CGFloat
    let alpha: CGFloat
    let line: CTLine         // as it settles
    let width: CGFloat, ascent: CGFloat, descent: CGFloat
    let baseline: CGFloat    // above the canvas's bottom edge
}

// MARK: - The dragon's pose

/// Everything about the dragon that changes over time.
private struct Pose {
    let time: Double
    var position = V3.zero       // the shoulders, on the stage
    var yaw: CGFloat = 0         // 0: profile, heading right; π/2: facing the viewer
    var roll: CGFloat = 0        // banking in flight, belly toward the viewer
    var headYaw: CGFloat = 0     // the head's extra turn relative to the body
    var headPitch: CGFloat = 0
    var headRoll: CGFloat = 0
    var rise: CGFloat = 0        // 0: level flight; 1: reared up, hovering
    var wingLift: CGFloat = 0    // the wingbeat: rotation of the wings about the forward axis
    var handLift: CGFloat = 0    // the same for the hand, which trails the arm like the end of a whip
    var wingFold: CGFloat = 0    // 0: spread; 1: folded (mid-upstroke)
    var handFold: CGFloat = 0
    var breath: CGFloat = 0      // -1...1
    var swim: CGFloat = 0        // the tail's undulation in flight
    var idle: CGFloat = 0        // 0...1: how much idle motion is mixed in
    var eyeGlow: CGFloat = 0
    var eyeBloom: CGFloat = 0    // the flare as its eyes meet ours
    var pupil: CGFloat = 1       // slit width factor
    var glint: CGFloat = 0
    var flash: CGFloat = 0       // a star of light flaring in each eye as they meet ours
    var grip: CGFloat = 0        // the talons flexing, -1...1
    // Now and then, while it hovers:
    var tongue: CGFloat = 0      // a forked tongue flicks out, quivering (0...1), and the frills flare
    var tailFlick: CGFloat = 0   // the tail's spade curls and flicks
    var stretch: CGFloat = 0     // the wings stretch wide

    init(time t: Double) {
        time = t
        let fly = progress(t, Beat.flight)
        let glide = 1 - (1 - fly) * (1 - fly)   // a swift entry slowing to a hover
        let settle = smooth(progress(t, Beat.settle))
        idle = smooth(progress(t, Beat.idle))
        rise = smooth(progress(t, Beat.rise))
        swim = 1 - rise
        breath = wave(t, 3.3)

        // Gestures that come and go while it hovers, each on its own long cycle.
        tongue = idle * occasionally(t, every: 9.7, for: 1.0, from: 8.0)
        tailFlick = idle * occasionally(t, every: 7.3, for: 1.1, from: 6.9)
        stretch = idle * occasionally(t, every: 15.1, for: 3.2, from: 12.3)
        // A curious tilt of the head, to one side and then, next time, the other.
        let tilt = idle * occasionally(t, every: 12.7, for: 2.6, from: 10.4) * alternate(t, every: 12.7, from: 10.4)
        // And a glance down toward Aries, the ram whose fleece it guards, before its eyes come back to us.
        let glance = idle * occasionally(t, every: 17.9, for: 3.4, from: 15.2)

        // Wingbeats: full strokes in flight; reared up, powerful downstrokes with a shorter recovery (so the
        // wings never sweep over the story), calming to a slow rise and fall. The hand trails the arm, so
        // the wing flexes like a whip; on the upstroke the elbow and the hand fold, the wrist leading.
        let phase = Pose.wingPhase(t), stroke = CGFloat(sin(phase))
        let rise = self.rise
        func lift(_ phase: Double) -> CGFloat {
            let stroke = CGFloat(sin(phase))
            let beat = stroke * (1 - 0.65 * rise * (1 + stroke) / 2)
            return mix(0.06, 0, settle) + mix(0.74, 0.08, settle) * beat
        }
        wingLift = lift(phase) + 0.035 * stretch
        handLift = lift(phase - 0.5) + 0.06 * stretch
        let folding = 1 - smooth(progress(t, 3.6...4.6))
        // Idly the wings flex a little with each breath, and now and then stretch wide.
        let flex = idle * (0.05 + 0.04 * wave(t, 6.7, 0.4)) - 0.16 * stretch
        wingFold = folding * CGFloat(0.5 + 0.5 * cos(phase - 0.3)) + flex
        handFold = folding * CGFloat(0.5 + 0.5 * cos(phase - 0.75)) + flex * 1.4

        position = V3(-330 * (1 - glide), 18 * (1 - glide) - 12 * sin(.pi * glide), -60 * (1 - glide))
        position.y -= mix(3.2, 1.4, settle) * stroke   // each downstroke lifts the body
        position.y += 6 * smooth(progress(t, 3.6...5.4))   // rearing up, it rises a little
        roll = -0.42 * (1 - rise)

        let yaw0: CGFloat = 0.3
        yaw = yaw0 + (.pi / 2 - yaw0) * smoother(progress(t, Beat.bodyTurn))
        let headTurn = yaw0 + (.pi / 2 - yaw0) * smoother(progress(t, Beat.headTurn))
        headYaw = headTurn - yaw + idle * (0.06 * wave(t, 9.1, 0.5) + 0.03 * wave(t, 5.3, 1.7)) + 0.06 * tilt - 0.24 * glance
        // Reared up, the head bows a little, so the muzzle shows below the eyes as it looks down at us; it
        // lifts a touch with each breath.
        headPitch = mix(-0.12, -0.42, rise) + idle * (0.04 * wave(t, 7.3) + 0.02 * wave(t, 3.9, 0.8) + 0.015 * breath)
            - 0.1 * glance
        // The head stays nearly level while the body banks.
        headRoll = -0.85 * roll + idle * 0.05 * wave(t, 8.3, 2.1) + 0.15 * tilt - 0.05 * glance
        // As its eyes meet ours they flare once, and the pupils tighten to slits.
        let meet = progress(t, Beat.gaze)
        eyeBloom = Pose.eyeBloom(at: t)
        eyeGlow = mix(0.6, 1, smooth(meet)) * (0.92 + 0.08 * wave(t, 3.3, 1)) + 0.45 * eyeBloom
        pupil = (1 + 0.22 * wave(t, 6.7) + 0.08 * wave(t, 2.9, 1.3)) * (1 - 0.3 * smooth(meet) - 0.25 * eyeBloom)
        glint = pow(max(0, wave(t, 5.3, 0.7)), 24)
        flash = pow(sin(.pi * progress(t, Beat.flash)), 2)
        grip = wave(t, 4.3, 0.4)
    }

    /// The flare as the dragon's eyes meet ours: 0 before and after, peaking mid-beat.
    static func eyeBloom(at t: Double) -> CGFloat { pow(sin(.pi * progress(t, Beat.gaze)), 2) }

    /// The wingbeat phase. The quick strokes of flight slow to a languid idle rhythm; the frequency eases
    /// between the two over [a, b], integrated in closed form so the phase never jumps.
    static func wingPhase(_ t: Double) -> Double {
        let w1 = 2 * Double.pi / 0.62, w2 = 2 * Double.pi / 3.8
        let a = 3.7, b = 5.6, d = b - a
        guard t > a else { return w1 * t }
        let x = min((t - a) / d, 1)
        return w1 * t + (w2 - w1) * (d * (x * x * x - x * x * x * x / 2) + max(0, t - b))
    }
}

// MARK: - The dragon's anatomy

/// The spine: a chain from the head (point 0) through the shoulders (`root`) and hips to the tail tip,
/// with a rotation-minimizing frame (tangent toward the tail, dorsal, and lateral to the dragon's right).
private struct Spine {
    static let root = 7, hips = 13, count = 30
    var points = [V3](), radii = [CGFloat](), tangents = [V3](), dorsals = [V3](), laterals = [V3]()

    // Elevation of each segment (degrees), from the head toward the tail, in level flight and reared up.
    private static let neckFlight: [CGFloat] = [-4, -12, -22, -28, -24, -15, -8]
    private static let neckUpright: [CGFloat] = [-16, -32, -52, -70, -84, -90, -88]
    private static let bodyFlight: [CGFloat] = [-3, -1, 1, 2, 3, 3]
    private static let bodyUpright: [CGFloat] = [-86, -88, -90, -91, -90, -87]
    /// How much each neck segment bends to follow the head when it turns ahead of the body.
    private static let neckFollow: [CGFloat] = [0.55, 0.4, 0.25, 0.12, 0.05, 0, 0]
    private static let bodyRadii: [CGFloat] = [11.4, 12.6, 12.6, 11.8, 10.8, 9.6, 8.3]

    static func length(_ j: Int) -> CGFloat {
        j < root ? 5.6 : (j < hips ? 6.6 : 5.4 - 1.5 * CGFloat(j - hips) / 15)
    }

    static func radius(_ i: Int, breath: CGFloat) -> CGFloat {
        switch i {
        case ..<root: return 5.6 + 4.8 * CGFloat(i) / CGFloat(root)
        case root...hips: return bodyRadii[i - root] * (1 + 0.04 * breath * (i < root + 4 ? 1 : 0.4))
        default:
            let u = CGFloat(i - hips) / CGFloat(count - 1 - hips)
            return 8.3 * pow(1 - u, 1.15) + 0.9 * u
        }
    }

    init(pose: Pose) {
        let t = pose.time
        let segments = Spine.count - 1
        var dirs = [V3]()
        dirs.reserveCapacity(segments)
        let headLead = pose.headYaw * 180 / .pi
        for j in 0..<segments {
            var e: CGFloat, a: CGFloat = 0
            if j < Spine.root {
                e = mix(Spine.neckFlight[j], Spine.neckUpright[j], pose.rise)
                a = -headLead * Spine.neckFollow[j]
            } else if j < Spine.hips {
                e = mix(Spine.bodyFlight[j - Spine.root], Spine.bodyUpright[j - Spine.root], pose.rise)
            } else {
                let u: CGFloat = CGFloat(j - Spine.hips) / CGFloat(segments - 1 - Spine.hips)
                let lag: Double = Double(u) * 2 * .pi
                let swim: CGFloat = 11 * wave(t, 0.95, -1.1 * lag) * (0.25 + 0.75 * u) * pose.swim
                let flight: CGFloat = 3 + 4 * u + swim
                // Reared up, the tail hangs, sweeps to the dragon's right and curls; idly, the curl breathes.
                let breathe: CGFloat = pose.idle * 9 * u * wave(t, 6.1, 1 - 0.9 * lag)
                let flick: CGFloat = pose.tailFlick * 34 * u * u   // now and then the spade curls and flicks
                let curl: CGFloat = -87 + 250 * pow(u, 1.6) + breathe + flick
                e = mix(flight, curl, pose.rise)
                let sway: CGFloat = pose.idle * 7 * u * wave(t, 4.7, -0.7 * lag)
                a = pose.rise * (90 * smooth(u / 0.3) + sway)
            }
            let er: CGFloat = e * .pi / 180, ar: CGFloat = a * .pi / 180
            dirs.append(V3(-cos(er) * cos(ar), sin(er), cos(er) * sin(ar)))
        }
        points = [V3](repeating: .zero, count: Spine.count)
        for j in stride(from: Spine.root - 1, through: 0, by: -1) { points[j] = points[j + 1] - dirs[j] * Spine.length(j) }
        for j in Spine.root..<segments { points[j + 1] = points[j] + dirs[j] * Spine.length(j) }
        radii = (0..<Spine.count).map { Spine.radius($0, breath: pose.breath) }
        tangents = (0..<Spine.count).map { (i: Int) -> V3 in
            let before: V3 = dirs[max(i - 1, 0)], after: V3 = dirs[min(i, segments - 1)]
            return (before + after).normalized
        }
        // Rotation-minimizing frames, transported both ways from the shoulders.
        dorsals = [V3](repeating: V3(0, 1, 0), count: Spine.count)
        let tr = tangents[Spine.root], up = V3(tr.y, -tr.x, 0)
        dorsals[Spine.root] = (up - tr * up.dot(tr)).normalized
        for i in stride(from: Spine.root - 1, through: 0, by: -1) {
            dorsals[i] = (dorsals[i + 1] - tangents[i] * dorsals[i + 1].dot(tangents[i])).normalized
        }
        for i in (Spine.root + 1)..<Spine.count {
            dorsals[i] = (dorsals[i - 1] - tangents[i] * dorsals[i - 1].dot(tangents[i])).normalized
        }
        laterals = (0..<Spine.count).map { dorsals[$0].cross(tangents[$0]) }
    }
}

/// The wing's bones in the flight frame (x forward along the body, y dorsal, z outward): the elbow and the
/// wrist relative to the shoulder, and four finger tips relative to the wrist. As the dragon rears up the
/// whole wing pitches with it, so the `display` pose (swept forward here) ends up raised and spread flat
/// toward the viewer. On the upstroke the elbow drops back and the wrist leads, and the wing folds, so the
/// arm is never a straight mast.
private struct WingBones {
    let elbow: V3, wrist: V3, fingers: [V3]

    static let span: CGFloat = 1.3
    static let flight = WingBones(elbow: V3(6, 4, 18), wrist: V3(13, 8, 36),
                                  fingers: [V3(6, 1, 15), V3(-8, -5, 46), V3(-24, -11, 38), V3(-34, -12, 20)])
    /// Where the elbow moves in flight as the wing rises: back, kinking the arm.
    static let raisedElbow = V3(-3, 5, 17)
    static let folded = WingBones(elbow: V3(-7, 7, 12), wrist: V3(5, 14, 21),
                                  fingers: [V3(3, 3, 9), V3(-19, -3, 21), V3(-29, -7, 12), V3(-32, -8, 4)])
    static let display = WingBones(elbow: V3(10, 4, 18), wrist: V3(30, 8, 34),
                                   fingers: [V3(14, 2, 12), V3(2, 6, 46), V3(-22, 8, 42), V3(-42, 8, 24)])

    /// Level flight blended toward the display pose by `rise`, with the upstroke's fold added on top.
    static func blend(_ a: V3, _ folded: V3, _ display: V3, fold: CGFloat, rise: CGFloat) -> V3 {
        (a + (display - a) * rise + (folded - a) * fold) * span
    }
}

/// A hind leg relative to the hip, side-normalized: knee, ankle, then three talon tips.
private enum LegBones {
    static let tucked = [V3(-6, -4, 2.5), V3(-14, -4, 3), V3(-19, -5.5, 4.5), V3(-20.5, -5, 2.5), V3(-19, -4.5, 0.6)]
    static let dangling = [V3(5, -6, 5.5), V3(3, -15, 7.5), V3(7.5, -19, 10.5), V3(8.5, -20.5, 7.6), V3(7.5, -19.5, 4.8)]
}

// MARK: - The dragon

private enum Dragon {
    static func draw(in rect: CGRect, time t: Double, context ctx: CGContext) {
        guard t > Beat.flight.lowerBound else { return }
        let pose = Pose(time: t)
        let post = CGPoint(x: rect.midX, y: rect.minY + 130)
        let view = Projector(yaw: pose.yaw, roll: pose.roll, position: pose.position, origin: post)
        Renderer(pose: pose, view: view, ctx: ctx).draw()
    }
}

/// Projects the posed model and inks it, back to front.
private struct Renderer {
    let pose: Pose
    let view: Projector
    let ctx: CGContext
    let spine: Spine
    let screen: [CGPoint], screenRadii: [CGFloat]

    init(pose: Pose, view: Projector, ctx: CGContext) {
        self.pose = pose
        self.view = view
        self.ctx = ctx
        let spine = Spine(pose: pose)
        self.spine = spine
        screen = spine.points.map { view.point($0) }
        screenRadii = (0..<Spine.count).map { spine.radii[$0] * view.scale(spine.points[$0]) }
    }

    func draw() {
        // The far wing is always behind the body and the near one always in front: as the dragon rears up,
        // the wings' roots slide from its back to its flanks, so by the time it faces us the near wing's
        // root lies on the body's edge and the wing has nothing left to pass behind.
        let far = wingShape(side: -1), near = wingShape(side: 1)
        // The far wing is a little dimmer, until the dragon faces us square.
        wing(far, ink: 0.72 + 0.28 * smooth((pose.yaw - 0.3) / (.pi / 2 - 0.3)))
        leg(side: -1)
        leg(side: 1)
        body()
        let horns = head()
        wing(near, ink: 1)
        gleam(at: [horns.first, near.wrist, horns.last, far.wrist].compactMap { $0 })
    }

    /// Now and then the light catches the gold: a glint at a horn tip or a wing's knuckle, each in turn.
    /// Each glint swells and fades to nothing before the next, so it never jumps.
    private func gleam(at anchors: [CGPoint]) {
        guard pose.idle > 0, !anchors.isEmpty else { return }
        let cycle = pose.time / 3.9, turn = cycle.rounded(.down)
        let strength = pose.idle * CGFloat(pow(sin(.pi * (cycle - turn)), 6))
        guard strength > 0.02 else { return }
        let c = anchors[Int(turn.truncatingRemainder(dividingBy: Double(anchors.count)))]
        Ink.glow(Palette.spark, at: c, radius: 2 + 6 * strength, alpha: strength, in: ctx)
        Ink.star(at: c, radius: 6 * strength, color: Palette.color(0xFFF8E0, strength), in: ctx)
    }

    // MARK: Body

    private func body() {
        spikes()
        let outer = CGMutablePath(), inner = CGMutablePath()
        for i in 0..<(Spine.count - 1) {
            Ink.addCapsule(outer, screen[i], screenRadii[i] + 0.8, screen[i + 1], screenRadii[i + 1] + 0.8)
            Ink.addCapsule(inner, screen[i], screenRadii[i], screen[i + 1], screenRadii[i + 1])
        }
        Ink.engrave(outer: outer, inner: inner, swell: 1.0, in: ctx)
        belly(within: inner)
        ember()
        scutes()
        spade()
    }

    /// The belly's plates, between its two rails, catch a little of the lamplight, giving the body some weight.
    private func belly(within body: CGPath) {
        guard let sheen = Palette.bellySheen else { return }
        var left = [CGPoint](), right = [CGPoint]()
        for i in 1..<(Spine.count - 3) {
            let r: CGFloat = spine.radii[i] * 0.98
            let down: V3 = -spine.dorsals[i], side: V3 = spine.laterals[i]
            left.append(view.point(spine.points[i] + (down * cos(0.86) - side * sin(0.86)) * r))
            right.append(view.point(spine.points[i] + (down * cos(0.86) + side * sin(0.86)) * r))
        }
        let band = Ink.polygon(left + right.reversed())
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.addPath(band)
        ctx.clip()
        // Brightest at the chest, where the ember is, fading toward the tail.
        let chest = screen[Spine.root + 1], tail = screen[Spine.count - 4]
        ctx.drawLinearGradient(sheen, start: chest, end: tail, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// The dragon's inner fire, glowing faintly through its chest and brightening with each breath.
    private func ember() {
        guard let gradient = Palette.ember else { return }
        let i = Spine.root + 2
        let core = spine.points[i] - spine.dorsals[i] * (spine.radii[i] * 0.3)
        let c = view.point(core), radius = 22 * view.scale(core)
        let chest = CGMutablePath()
        for k in (Spine.root - 2)..<(Spine.hips + 1) {
            Ink.addCapsule(chest, screen[k], screenRadii[k], screen[k + 1], screenRadii[k + 1])
        }
        ctx.saveGState()
        ctx.addPath(chest)
        ctx.clip()
        ctx.setAlpha(0.75 + 0.25 * pose.breath)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    /// The tail ends in a spade, drawn flat to the viewer along the tail's last stretch.
    private func spade() {
        let n = Spine.count - 1
        let tip = screen[n]
        var dir = tip - screen[n - 2]
        dir = dir * (1 / max(dir.length, 0.001))
        let s = view.scale(spine.points[n]) * 1.05
        let frame = CGAffineTransform(a: dir.x * s, b: dir.y * s, c: -dir.y * s, d: dir.x * s, tx: tip.x, ty: tip.y)
        let blade = CGMutablePath()
        blade.move(to: CGPoint(x: 0, y: 0.7), transform: frame)
        blade.addQuadCurve(to: CGPoint(x: -1.8, y: 4.4), control: CGPoint(x: 0.2, y: 2.6), transform: frame)
        blade.addQuadCurve(to: CGPoint(x: 8.6, y: 0), control: CGPoint(x: 3.8, y: 3.6), transform: frame)
        blade.addQuadCurve(to: CGPoint(x: -1.8, y: -4.4), control: CGPoint(x: 3.8, y: -3.6), transform: frame)
        blade.addQuadCurve(to: CGPoint(x: 0, y: -0.7), control: CGPoint(x: 0.2, y: -2.6), transform: frame)
        blade.closeSubpath()
        ctx.setFillColor(Palette.gold)
        ctx.addPath(blade)
        ctx.fillPath()
        let rib = CGMutablePath()
        rib.move(to: CGPoint(x: 0.6, y: 0), transform: frame)
        rib.addLine(to: CGPoint(x: 6.4, y: 0), transform: frame)
        ctx.setStrokeColor(Palette.groove)
        ctx.setLineWidth(0.55)
        ctx.addPath(rib)
        ctx.strokePath()
    }

    /// A crest of thorns along the back, drawn before the body so that the body hides their roots.
    private func spikes() {
        let path = CGMutablePath()
        for i in 1..<(Spine.count - 7) {
            let h: CGFloat = i < Spine.root ? 3.4 : (i <= Spine.hips ? 4.6 : 4.6 * (1 - CGFloat(i - Spine.hips) / 11))
            guard h > 0.7 else { continue }
            let p = spine.points[i], d = spine.dorsals[i], t = spine.tangents[i], r = spine.radii[i]
            let base = p + d * (r * 0.85)
            let a = view.point(base - t * (h * 0.5)), b = view.point(base + t * (h * 0.45))
            let tip = view.point(base + d * h + t * (h * 0.75))
            path.move(to: a)
            path.addQuadCurve(to: tip, control: a.lerp(tip, 0.5) + (b - a) * 0.12)
            path.addLine(to: b)
            path.closeSubpath()
        }
        ctx.setFillColor(Palette.goldDeep)
        ctx.addPath(path)
        ctx.fillPath()
    }

    /// Lines engraved on the body's surface, all of them rings or rails around the spine drawn only where
    /// the surface faces the viewer, so they wrap around the form as it turns: the belly's scutes between
    /// two rails, and sparse cross-contour hatching on the side turned away from the light. Each line is
    /// cut exactly where its condition changes sign, so its ends glide instead of jumping.
    private func scutes() {
        let rings = CGMutablePath(), hatching = CGMutablePath(), rails = CGMutablePath()
        let last = Spine.count - 3
        func surface(_ i: Int, _ psi: CGFloat) -> (CGPoint, V3) {
            let n = (-spine.dorsals[i]) * cos(psi) + spine.laterals[i] * sin(psi)
            return (view.point(spine.points[i] + n * (spine.radii[i] * 0.98)), n)
        }
        for i in 1..<last {
            // Scutes on the body, thinning out toward the tip of the tail.
            if i <= Spine.hips + 4 || i % 2 == 0 {
                Ink.trace((0...6).map { k in
                    let (q, n) = surface(i, -0.8 + 1.6 * CGFloat(k) / 6)
                    return (q, view.facing(n) - 0.1)
                }, into: rings)
            }
            // Hatching on both flanks, from the belly's rail around to the spine, where it is in shadow.
            guard i > 1, i < last - 2 else { continue }
            for side in [-1, 1] as [CGFloat] {
                Ink.trace((0...6).map { k in
                    let (q, n) = surface(i, side * (1.05 + 1.9 * CGFloat(k) / 6))
                    return (q, min(view.facing(n) - 0.15, -0.08 - view.lighting(n)))
                }, into: hatching)
            }
        }
        for side in [-1, 1] as [CGFloat] {
            Ink.trace((1..<last).map { i in
                let (q, n) = surface(i, 0.86 * side)
                return (q, view.facing(n) - 0.1)
            }, into: rails)
        }
        ctx.setStrokeColor(Palette.goldFaint)
        ctx.setLineWidth(0.5)
        ctx.addPath(rings)
        ctx.strokePath()
        ctx.setStrokeColor(Palette.color(0xD9B466, 0.34))
        ctx.setLineWidth(0.45)
        ctx.addPath(hatching)
        ctx.strokePath()
        ctx.setStrokeColor(Palette.color(0xD9B466, 0.8))
        ctx.setLineWidth(0.7)
        ctx.addPath(rails)
        ctx.strokePath()
    }

    // MARK: Limbs

    /// A wing on the canvas: shoulder, elbow, wrist, the four finger tips (and each finger's midpoint, which
    /// bows as the hand trails the arm), and where it joins the flank.
    private struct WingShape {
        let shoulder: CGPoint, elbow: CGPoint, wrist: CGPoint, tips: [CGPoint], knuckles: [CGPoint], flank: CGPoint
        /// How much lamplight the membrane catches, 0...1: most when its broad side turns toward the light
        /// (reflected) or away from it (shining through), least edge-on.
        let sheen: CGFloat
    }

    private func wingShape(side: CGFloat) -> WingShape {
        // The roots slide from the back (in flight) to the flanks (reared up, facing us).
        let root = Spine.root, hip = Spine.root + 4
        let r0: CGFloat = spine.radii[root], r1: CGFloat = spine.radii[hip]
        let shoulder: V3 = spine.points[root] + spine.dorsals[root] * (r0 * mix(0.5, 0.1, pose.rise))
            + spine.laterals[root] * (side * r0 * mix(0.55, 0.96, pose.rise))
        let trailing: V3 = spine.points[hip] + spine.dorsals[hip] * (r1 * mix(0.2, 0.04, pose.rise))
            + spine.laterals[hip] * (side * r1 * mix(0.8, 0.98, pose.rise))
        let pitch = pose.rise * .pi / 2, rise = pose.rise
        let (flight, folded, display) = (WingBones.flight, WingBones.folded, WingBones.display)
        /// Pitched with the body, then raised by the wingbeat (a turn about the forward axis), mirrored by side.
        func place(_ v: V3, lift: CGFloat) -> V3 {
            let p = v.pitched(pitch)
            let c = cos(lift), s = sin(lift)
            return V3(p.x, p.y * c + p.z * s, (-p.y * s + p.z * c) * side)
        }
        let raised = smooth((pose.wingLift + 0.2) / 0.75)
        let flightElbow = flight.elbow + (WingBones.raisedElbow - flight.elbow) * raised
        let elbow = shoulder + place(WingBones.blend(flightElbow, folded.elbow, display.elbow, fold: pose.wingFold, rise: rise),
                                     lift: pose.wingLift)
        let wrist = shoulder + place(WingBones.blend(flight.wrist, folded.wrist, display.wrist, fold: pose.wingFold, rise: rise),
                                     lift: pose.wingLift)
        var tips = [CGPoint](), knuckles = [CGPoint](), middle = wrist
        let bend = mix(pose.wingLift, pose.handLift, 0.4)
        for k in 0..<4 {
            let finger = WingBones.blend(flight.fingers[k], folded.fingers[k], display.fingers[k], fold: pose.handFold, rise: rise)
            let tip: V3 = wrist + place(finger, lift: pose.handLift)
            if k == 2 { middle = tip }
            tips.append(view.point(tip))
            knuckles.append(view.point(wrist + place(finger * 0.5, lift: bend)))
        }
        let normal: V3 = (wrist - shoulder).cross(middle - shoulder).normalized
        let sheen: CGFloat = abs(view.lighting(normal))
        return WingShape(shoulder: view.point(shoulder), elbow: view.point(elbow), wrist: view.point(wrist), tips: tips,
                         knuckles: knuckles, flank: view.point(trailing), sheen: sheen)
    }

    private func wing(_ shape: WingShape, ink: CGFloat) {
        let s = shape.shoulder, h = shape.flank, elbow = shape.elbow, wrist = shape.wrist, tips = shape.tips

        // The membrane, with scalloped trailing edges between the finger tips.
        var scallops = [(CGPoint, CGPoint, CGPoint)]()
        for i in 0..<3 { scallops.append((tips[i], tips[i].lerp(tips[i + 1], 0.5).lerp(wrist, 0.3), tips[i + 1])) }
        scallops.append((tips[3], tips[3].lerp(h, 0.5).lerp(elbow, 0.25), h))
        let edge = CGMutablePath()
        edge.move(to: tips[0])
        for (_, c, b) in scallops { edge.addQuadCurve(to: b, control: c) }
        let membrane = CGMutablePath()
        membrane.move(to: s)
        membrane.addLine(to: elbow)
        membrane.addLine(to: wrist)
        // The leading finger, bowed like its bone (a quadratic through its knuckle).
        membrane.addQuadCurve(to: tips[0], control: shape.knuckles[0] * 2 - wrist.lerp(tips[0], 0.5))
        for (_, c, b) in scallops { membrane.addQuadCurve(to: b, control: c) }
        membrane.addQuadCurve(to: s, control: h.lerp(s, 0.5).lerp(elbow, 0.15))
        membrane.closeSubpath()
        ctx.setFillColor(Palette.membrane)
        ctx.addPath(membrane)
        ctx.fillPath()
        // Lamplight glowing through the skin: warm near the arm, fading toward the scalloped edge.
        if let wash = Palette.membraneWash {
            var reach: CGFloat = 1
            for tip in tips { reach = max(reach, (tip - elbow).length) }
            ctx.saveGState()
            ctx.addPath(membrane)
            ctx.clip()
            ctx.setAlpha(ink * (0.6 + 0.55 * shape.sheen))
            let c = elbow.lerp(wrist, 0.35)
            ctx.drawRadialGradient(wash, startCenter: c, startRadius: 0, endCenter: c, endRadius: reach, options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }

        // Fine veins fanning from the wrist (the elbow, for the innermost panel), stopping at a contour
        // that echoes the scalloped edge.
        let veins = CGMutablePath(), contour = CGMutablePath()
        for (index, (a, c, b)) in scallops.enumerated() {
            let hub = index < 3 ? wrist : elbow
            for f in [0.2, 0.4, 0.6, 0.8] as [CGFloat] {
                let target = a.lerp(c, f).lerp(c.lerp(b, f), f)
                veins.move(to: hub.lerp(target, 0.18))
                veins.addLine(to: target.lerp(hub, 0.16))
            }
            contour.move(to: a.lerp(hub, 0.11))
            contour.addQuadCurve(to: b.lerp(hub, 0.11), control: c.lerp(hub, 0.11))
        }
        ctx.setStrokeColor(Palette.color(0xD9B466, 0.36 * ink))
        ctx.setLineWidth(0.45)
        ctx.addPath(veins)
        ctx.strokePath()
        ctx.setStrokeColor(Palette.color(0xD9B466, 0.5 * ink))
        ctx.addPath(contour)
        ctx.strokePath()
        ctx.setStrokeColor(Palette.color(0xD9B466, 0.9 * ink))
        ctx.setLineWidth(0.75)
        ctx.addPath(edge)
        ctx.strokePath()

        // Bones: the fingers, then the arm along the leading edge, and the thumb's claw.
        let bonesPath = CGMutablePath()
        for (tip, knuckle) in zip(tips, shape.knuckles) {
            Ink.ribbon(Ink.spline([wrist, knuckle, tip], samples: 3), Ink.taper(7, 1.7, 1.4, 0.25, at: 0.1), into: bonesPath)
        }
        // The arm: the upper arm and the forearm meet at a knuckled elbow, so the wing folds like a limb.
        Ink.ribbon([s, s.lerp(elbow, 0.5), elbow], [3.0, 2.8, 2.5], into: bonesPath)
        Ink.ribbon([elbow, elbow.lerp(wrist, 0.5), wrist], [2.5, 2.1, 1.7], into: bonesPath)
        let claw = wrist + (wrist - elbow) * 0.14
        Ink.ribbon([wrist, claw, claw + (claw - wrist) * 0.3 + CGPoint(x: 0, y: -1.6)], [1.6, 1.0, 0.2], into: bonesPath)
        ctx.setFillColor(Palette.color(0xD9B466, ink))
        ctx.addPath(bonesPath)
        ctx.fillPath()
        ctx.fillEllipse(in: CGRect(x: elbow.x - 1.45, y: elbow.y - 1.45, width: 2.9, height: 2.9))
        ctx.setFillColor(Palette.color(0xF6E3A6, ink))
        ctx.fillEllipse(in: CGRect(x: wrist.x - 1.4, y: wrist.y - 1.4, width: 2.8, height: 2.8))
    }

    /// A hind leg: thigh and shin as an engraved tube, then three hooked talons. Drawn behind the body.
    private func leg(side: CGFloat) {
        let i = Spine.hips - 1
        let hip = spine.points[i] - spine.dorsals[i] * (spine.radii[i] * 0.25) + spine.laterals[i] * (side * spine.radii[i] * 0.7)
        let joints = (0..<5).map { k -> V3 in
            let v = LegBones.tucked[k] + (LegBones.dangling[k] - LegBones.tucked[k]) * pose.rise
            return hip + V3(v.x, v.y, v.z * side)
        }
        let limb = [hip, joints[0], joints[1]].map { view.point($0) }
        let radii: [CGFloat] = [5.2, 3.4, 2.4].map { $0 * view.scale(hip) }
        let outer = CGMutablePath(), inner = CGMutablePath()
        for k in 0..<2 {
            Ink.addCapsule(outer, limb[k], radii[k] + 0.8, limb[k + 1], radii[k + 1] + 0.8)
            Ink.addCapsule(inner, limb[k], radii[k], limb[k + 1], radii[k + 1])
        }
        Ink.engrave(outer: outer, inner: inner, swell: 0.8, in: ctx)
        let talons = CGMutablePath()
        let ankle = joints[1]
        for k in 2..<5 {
            let tip = joints[k] + V3(0, -0.6 * pose.grip * pose.idle, 0)
            let mid = ankle + (tip - ankle) * 0.6 + V3(0, 0.8, 0)
            let hook = tip + (tip - ankle).normalized * 0.6 + V3(0, -1.6, 0)
            let pts = Ink.spline([ankle, mid, tip, hook].map { view.point($0) }, samples: 3)
            Ink.ribbon(pts, Ink.taper(pts.count, 1.8, 1.5, 0.2, at: 0.3), into: talons)
        }
        ctx.setFillColor(Palette.gold)
        ctx.addPath(talons)
        ctx.fillPath()
    }

    // MARK: Head

    static let headScale: CGFloat = 1.4

    /// Cross sections of the head along its length: (forward, center height, half width, top, bottom).
    private static let stations: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (-3, 1.6, 4.4, 4.4, 3.8), (2.5, 1.8, 8.4, 5.8, 7.0), (8.5, 2.2, 8.6, 6.8, 5.4), (14, 1.4, 5.4, 4.8, 4.0),
        (20, 0.8, 4.0, 3.8, 3.2), (25, 0.5, 3.4, 3.2, 2.8), (28.5, 0.4, 2.3, 2.2, 2.0),
    ]

    /// The head's frame in body space: its origin (the back of the skull) and scaled forward, up, right.
    private func headFrame() -> (o: V3, f: V3, u: V3, r: V3) {
        var f = V3(1, 0, 0), u = V3(0, 1, 0), r = V3(0, 0, 1)
        f = f.rolled(pose.headRoll).pitched(pose.headPitch).yawed(pose.headYaw)
        u = u.rolled(pose.headRoll).pitched(pose.headPitch).yawed(pose.headYaw)
        r = r.rolled(pose.headRoll).pitched(pose.headPitch).yawed(pose.headYaw)
        let k = Renderer.headScale
        // The neck joins the skull low at the back.
        return (spine.points[0] - f * (2 * k) + u * (3.5 * k), f * k, u * k, r * k)
    }

    /// Draws the head and returns where its horn tips are.
    private func head() -> [CGPoint] {
        let (o, f, u, r) = headFrame()
        func at(_ F: CGFloat, _ U: CGFloat, _ R: CGFloat) -> V3 { o + f * F + u * U + r * R }
        func p(_ F: CGFloat, _ U: CGFloat, _ R: CGFloat) -> CGPoint { view.point(at(F, U, R)) }
        let k = Renderer.headScale
        let unitF = f * (1 / k), unitU = u * (1 / k), unitR = r * (1 / k)
        let zoom = view.scale(o) * k

        // Behind the skull: frills fanning from the jaw, and horns sweeping back and up.
        frills(at)
        let horns = CGMutablePath(), grooves = CGMutablePath()
        var hornTips = [CGPoint]()
        for side in [-1, 1] as [CGFloat] {
            let ctrl = [p(4.5, 6.8, 3.6 * side), p(0, 11, 7.2 * side), p(-5.5, 15, 10.8 * side), p(-8.5, 20, 12.2 * side),
                        p(-7.5, 25, 11 * side), p(-4.5, 28, 9 * side)]
            let pts = Ink.spline(ctrl, samples: 4)
            let widths = Ink.taper(pts.count, 3.4, 3.0, 0.3, at: 0.15, scale: zoom)
            Ink.ribbon(pts, widths, into: horns)
            hornTips.append(pts[pts.count - 2])
            for g in stride(from: 3, to: pts.count - 3, by: 2) {
                let dir = pts[g + 1] - pts[g - 1], l = max(dir.length, 0.001)
                let n = CGPoint(x: -dir.y / l, y: dir.x / l) * (widths[g] * 0.42)
                grooves.move(to: pts[g] + n)
                grooves.addLine(to: pts[g] - n)
            }
        }
        ctx.setFillColor(Palette.gold)
        ctx.addPath(horns)
        ctx.fillPath()
        ctx.setStrokeColor(Palette.groove)
        ctx.setLineWidth(0.5)
        ctx.addPath(grooves)
        ctx.strokePath()

        // The skull: the hull of its lofted cross sections.
        var outline = [CGPoint]()
        outline.reserveCapacity(Renderer.stations.count * 10)
        for (F, cu, hw, top, bottom) in Renderer.stations {
            for i in 0..<10 {
                let a = CGFloat(i) / 10 * 2 * .pi
                let c = cos(a), s = sin(a)
                let R = hw * (c < 0 ? -1 : 1) * pow(abs(c), 0.8)
                let U = cu + (s < 0 ? -bottom : top) * pow(abs(s), 0.8)
                outline.append(p(F, U, R))
            }
        }
        let skull = Ink.polygon(Ink.hull(outline))
        Ink.engrave(skull, weight: 0.8, swell: 0.9, rounding: 1.1, in: ctx)

        // Engraved features, clipped to the head.
        ctx.saveGState()
        ctx.addPath(skull)
        ctx.clip()
        let lines = CGMutablePath()
        for side in [-1, 1] as [CGFloat] {
            let lateral = unitR * side
            // The mouth along the jaw: seen from the side only, so the face never seems to smile.
            let mouthFacing = view.facing((lateral + unitU * -0.4).normalized)
            if mouthFacing > 0.15 {
                let pts = Ink.spline([p(29.4, -1.0, 0.6 * side), p(25, -1.9, 3.3 * side), p(18, -2.8, 4.8 * side),
                                      p(11, -3.7, 6.6 * side), p(6, -4.6, 7.6 * side)], samples: 3)
                let fade = smooth((mouthFacing - 0.15) / 0.3)
                Ink.ribbon(pts, Ink.taper(pts.count, 0.4 * fade, 1.4 * fade, 0.3 * fade, at: 0.6), into: lines)
                // A fang, growing in with the mouth line.
                let a = p(24.6, -2.0, 3.5 * side), b = p(23.0, -2.2, 3.9 * side)
                let tip = a.lerp(b, 0.4).lerp(p(24.0, -4.5, 3.8 * side), fade)
                lines.move(to: a); lines.addLine(to: tip); lines.addLine(to: b); lines.closeSubpath()
            }
            // Brow ridges, frowning toward the snout and sweeping back to the horns.
            let brow = Ink.spline([p(16.5, 4.4, 2.6 * side), p(12.5, 6.6, 5.6 * side), p(8, 7.6, 7.4 * side), p(3.5, 7.2, 7.6 * side)], samples: 3)
            Ink.ribbon(brow, Ink.taper(brow.count, 0.6, 2.4, 0.4, at: 0.35, scale: zoom / k), into: lines)
            // Ridges along the top of the muzzle.
            let ridge = Ink.spline([p(15, 4.6, 2.5 * side), p(21, 3.7, 2.0 * side), p(27, 2.7, 1.5 * side)], samples: 3)
            Ink.ribbon(ridge, Ink.taper(ridge.count, 1.0, 0.8, 0.25, at: 0.2), into: lines)
            // Nostrils.
            let flare = smooth(view.facing((unitF + unitU * 0.6 + lateral * 0.5).normalized) / 0.25)
            if flare > 0 {
                let nostril = Ink.spline([p(28.6, 1.3, 1.3 * side), p(28.0, 2.2, 2.2 * side), p(26.8, 2.0, 2.6 * side), p(26.4, 1.3, 2.3 * side)], samples: 2)
                Ink.ribbon(nostril, Ink.taper(nostril.count, 0.3 * flare, 1.2 * flare, 0.3 * flare, at: 0.3), into: lines)
            }
            // Scales along the cheek.
            let cheek = smooth((view.facing(lateral) - 0.2) / 0.25)
            for (F, U) in [(4.0, -1.0), (6.5, 0.6), (5.0, -3.6)] as [(CGFloat, CGFloat)] where cheek > 0 {
                let arc = [p(F + 1.6, U + 1.2, 8.2 * side), p(F, U, 8.6 * side), p(F + 1.6, U - 1.2, 8.2 * side)]
                Ink.ribbon(Ink.spline(arc, samples: 2), [0.2, 0.6, 0.8, 0.6, 0.2].map { $0 * cheek }, into: lines)
            }
        }
        // Scales across the top of the muzzle, where it faces us.
        let snoutFacing = view.facing(unitU)
        if snoutFacing > 0.15 {
            let fade = smooth((snoutFacing - 0.15) / 0.3)
            for F in [18, 21, 24] as [CGFloat] {
                let w = 2.0 - (F - 18) * 0.08
                let arc = Ink.spline([p(F - 0.6, 3.9 - (F - 18) * 0.15, -w), p(F + 0.5, 4.2 - (F - 18) * 0.15, 0),
                                      p(F - 0.6, 3.9 - (F - 18) * 0.15, w)], samples: 3)
                Ink.ribbon(arc, Ink.taper(arc.count, 0.2, 0.7 * fade, 0.2, at: 0.5), into: lines)
            }
        }
        ctx.setFillColor(Palette.gold)
        ctx.addPath(lines)
        ctx.fillPath()
        ctx.restoreGState()

        tongue(at)

        // The eyes.
        for side in [-1, 1] as [CGFloat] {
            eye(center: at(9.6, 3.6, 5.8 * side), forward: unitF, up: unitU, lateral: unitR * side, size: 4.7 * k, clip: skull)
        }
        return hornTips
    }

    /// Now and then a forked tongue flicks out from under the muzzle, its tip quivering.
    private func tongue(_ at: (CGFloat, CGFloat, CGFloat) -> V3) {
        let out = pose.tongue
        guard out > 0.01 else { return }
        let quiver = CGFloat(sin(2 * .pi * pose.time / 0.17)) * out
        let length = 10.5 * out
        func p(_ s: CGFloat, _ r: CGFloat) -> CGPoint { view.point(at(27.4 + 0.72 * length * s, -1.0 - 0.7 * length * s, r)) }
        let stem = Ink.spline([p(0, 0), p(0.35, 0.4 * quiver), p(0.7, 1.0 * quiver), p(1, 1.6 * quiver)], samples: 3)
        let path = CGMutablePath()
        let zoom = view.scale(at(27, -1, 0))
        Ink.ribbon(stem, Ink.taper(stem.count, 1.5 * zoom, 1.3 * zoom, 0.9 * zoom, at: 0.2), into: path)
        let fork = p(1, 1.6 * quiver)
        for prong in [-1, 1] as [CGFloat] {
            let tip = view.point(at(27.4 + 0.72 * length * 1.26, -1.0 - 0.7 * length * 1.2, (1.6 * quiver + 1.9 * prong) * out))
            Ink.ribbon([fork, fork.lerp(tip, 0.5), tip], [0.9 * zoom, 0.6 * zoom, 0.15], into: path)
        }
        ctx.setFillColor(Palette.tongue)
        ctx.addPath(path)
        ctx.fillPath()
    }

    /// Fan-shaped frills behind the jaw: four spines webbed most of the way, angled to show from the front
    /// and the side.
    private func frills(_ at: (CGFloat, CGFloat, CGFloat) -> V3) {
        let webs = CGMutablePath(), edges = CGMutablePath(), spines = CGMutablePath()
        let zoom = view.scale(at(0, 0, 0))
        // The frills fan wider as the tongue flicks, and breathe a little.
        let flare = pose.tongue + 0.15 * pose.idle * pose.breath
        for side in [-1, 1] as [CGFloat] {
            let base = view.point(at(1.5, -0.5, 6.8 * side))
            let tips = [(-4, 9.5, 11.5), (-8, 4.5, 15), (-9.5, -1, 16), (-7.5, -6.5, 13.5)].map { (F: CGFloat, U: CGFloat, R: CGFloat) in
                view.point(at(F, U * (1 + 0.12 * flare), R * side * (1 + 0.2 * flare)))
            }
            let ends = tips.map { base.lerp($0, 0.74) }
            webs.move(to: base)
            webs.addLine(to: ends[0])
            edges.move(to: ends[0])
            for k in 0..<3 {
                let control = ends[k].lerp(ends[k + 1], 0.5).lerp(base, 0.22)
                webs.addQuadCurve(to: ends[k + 1], control: control)
                edges.addQuadCurve(to: ends[k + 1], control: control)
            }
            webs.closeSubpath()
            for tip in tips {
                Ink.ribbon([base, base.lerp(tip, 0.5), tip], [1.9 * zoom, 1.2 * zoom, 0.15], into: spines)
            }
        }
        ctx.setFillColor(Palette.membrane)
        ctx.addPath(webs)
        ctx.fillPath()
        ctx.setStrokeColor(Palette.color(0xD9B466, 0.85))
        ctx.setLineWidth(0.6)
        ctx.addPath(edges)
        ctx.strokePath()
        ctx.setFillColor(Palette.goldDeep)
        ctx.addPath(spines)
        ctx.fillPath()
    }

    /// An almond-shaped reptilian eye with an amber iris and a vertical slit pupil, set into the head.
    private func eye(center c: V3, forward f: V3, up u: V3, lateral l: V3, size: CGFloat, clip: CGPath) {
        let n = (f * 0.72 + u * 0.16 + l * 0.68).normalized
        var a = f * -0.58 + u * 0.28 + l * 0.76
        a = (a - n * a.dot(n)).normalized
        var b = n.cross(a)
        if b.dot(u) < 0 { b = -b }
        let visible = smooth((view.facing(n) - 0.05) / 0.3)
        guard visible > 0.01 else { return }
        let C = view.point(c)
        let A = view.point(c + a * size) - C, B = view.point(c + b * (size * 0.78)) - C
        let frame = CGAffineTransform(a: A.x, b: A.y, c: B.x, d: B.y, tx: C.x, ty: C.y)
        let reach = max(A.length, B.length)
        Ink.glow(Palette.eyeHalo, at: C, radius: reach * (2.4 + 0.9 * pose.eyeBloom), alpha: visible * pose.eyeGlow, in: ctx)

        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        ctx.setAlpha(visible)
        let almond = CGMutablePath()
        almond.move(to: CGPoint(x: -1, y: -0.14), transform: frame)
        almond.addQuadCurve(to: CGPoint(x: 1, y: 0.24), control: CGPoint(x: -0.1, y: 1.16), transform: frame)
        almond.addQuadCurve(to: CGPoint(x: -1, y: -0.14), control: CGPoint(x: 0.12, y: -0.98), transform: frame)
        almond.closeSubpath()
        ctx.saveGState()
        ctx.addPath(almond)
        ctx.clip()
        let irisCenter = CGPoint(x: -0.05, y: 0.06).applying(frame)
        if let iris = Palette.iris {
            ctx.drawRadialGradient(iris, startCenter: irisCenter, startRadius: 0, endCenter: irisCenter, endRadius: reach * 0.95,
                                   options: [.drawsAfterEndLocation])
        }
        // The iris is a little dimmer until the dragon meets our gaze.
        ctx.setFillColor(Palette.color(0x2A0E02, 0.45 * (1 - pose.eyeGlow)))
        ctx.fill(almond.boundingBoxOfPath)
        // A shadowed rim under the lids frames the iris.
        ctx.setStrokeColor(Palette.color(0x5A1E04, 0.55))
        ctx.setLineWidth(reach * 0.22)
        ctx.addPath(almond)
        ctx.strokePath()
        // The pupil: a slit as tall as the eye, upright along the head's own vertical, so it reads as a
        // reptile's even when the eye is small.
        let rise = view.point(c + u * size) - C
        let up = rise * (1 / max(rise.length, 0.001)), across = CGPoint(x: up.y, y: -up.x)
        let half = reach * 1.3, w = reach * (0.075 + 0.075 * pose.pupil)
        let top = irisCenter + up * half, bottom = irisCenter - up * half
        let pupil = CGMutablePath()
        pupil.move(to: top)
        pupil.addQuadCurve(to: bottom, control: irisCenter + across * (2 * w))
        pupil.addQuadCurve(to: top, control: irisCenter - across * (2 * w))
        ctx.setFillColor(Palette.color(0x0E0603))
        ctx.addPath(pupil)
        ctx.fillPath()
        ctx.restoreGState()

        // A catchlight, upper left, that sparkles now and then.
        let g = C + CGPoint(x: -0.3 * reach, y: 0.2 * reach)
        let gr = reach * (0.14 + 0.06 * pose.glint)
        ctx.setFillColor(Palette.color(0xFFFBEA, 0.85 + 0.15 * pose.glint))
        ctx.fillEllipse(in: CGRect(x: g.x - gr, y: g.y - gr, width: 2 * gr, height: 2 * gr))

        // Lids: a heavy upper lid with a flick at the outer corner, a fine lower lid.
        let upper = (0...8).map { i -> CGPoint in
            let s = CGFloat(i) / 8
            let x = (1 - s) * (1 - s) * -1.05 + 2 * (1 - s) * s * -0.1 + s * s * 1.05
            let y = (1 - s) * (1 - s) * -0.14 + 2 * (1 - s) * s * 1.22 + s * s * 0.26
            return CGPoint(x: x, y: y).applying(frame)
        } + [CGPoint(x: 1.5, y: 0.52).applying(frame)]
        let lids = CGMutablePath()
        Ink.ribbon(upper, Ink.taper(upper.count, 0.3, 1.5, 0.2, at: 0.6), into: lids)
        ctx.setFillColor(Palette.color(0xE8C77E))
        ctx.addPath(lids)
        ctx.fillPath()
        let lower = CGMutablePath()
        lower.move(to: CGPoint(x: 1, y: 0.24), transform: frame)
        lower.addQuadCurve(to: CGPoint(x: -1, y: -0.14), control: CGPoint(x: 0.12, y: -0.98), transform: frame)
        ctx.setStrokeColor(Palette.color(0xD9B466, 0.8))
        ctx.setLineWidth(0.5)
        ctx.addPath(lower)
        ctx.strokePath()
        ctx.restoreGState()

        // As its eyes meet ours, a star of light flares in each.
        let flash = pose.flash * visible
        if flash > 0.01 {
            Ink.glow(Palette.spark, at: g, radius: reach * (0.4 + 0.5 * flash), alpha: 0.9 * flash, in: ctx)
            Ink.star(at: g, radius: reach * (0.3 + 0.55 * flash), color: Palette.color(0xFFFBEA, flash), in: ctx)
        }
    }
}
