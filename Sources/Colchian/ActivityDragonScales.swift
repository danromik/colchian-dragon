import AppKit

// MARK: - Design

/// The "Dragon Scales" activity design: a honeycomb heat map of the last 30 minutes.
///
/// Columns are 40-second slices and rows are agents. Each session is a band of rows: its main thread
/// on top and its subagents in lanes below, so the band thickens during a workflow burst, with a hairline
/// from each subagent's first scale up to its parent's row. Generating scales shimmer, tool calls hold
/// an ember, and a main thread waiting on its subagents shows hollow scales. When sessions or lanes come
/// and go, the comb re-tessellates with a ripple running out from where the change happened.
///
/// It redraws at 60 fps inside a menu, so the text is rendered into a bitmap when the snapshot changes,
/// and each comb keeps a bitmap of its settled scales (see `Comb.draw`). A frame draws those bitmaps plus
/// the moving parts: the newest scales, the ones still animating, links, pips and the hover outline.
final class DragonScalesDesign: ActivityDesign {
    let boxHeight: CGFloat = 106

    /// The strip at the top of the box with its title and counts; the comb fills the rest.
    private static let boxHeader: CGFloat = 20
    private static let boxOptions = Comb.Options(
        width: 310, fixedHeight: 86, maxHeight: 86, left: 11, right: 304, padTop: 3, padBottom: 6,
        columnWidth: (310 - 17) / 45.5, gap: 0.8, minPitch: 3.1, laneCap: 5, minGroupHeight: 0, cellGap: 0.55,
        linkAlpha: 0.22, emptyRows: 0)
    private static let panelOptions = Comb.Options(
        width: PanelMetrics.width - 2 * PanelMetrics.inset, fixedHeight: nil, maxHeight: 340, left: 108, right: 482,
        padTop: 3, padBottom: 18, columnWidth: 8, gap: 0.9, minPitch: 3.6, laneCap: 12, minGroupHeight: 26,
        cellGap: 0.6, linkAlpha: 0.3, emptyRows: 4)

    private let data = ScaleData()
    private var box = Comb(options: boxOptions)
    private var panel = Comb(options: panelOptions)
    private let boxCache = Offscreen()
    private let panelCache = Offscreen()
    private var boxKey: CacheKey?
    private var panelKey: CacheKey?
    private var palettes: [Bool: Palette] = [:]
    /// The agent under the mouse in the panel's comb, by ID so it survives snapshot refreshes.
    private var hovered: String?
    /// The session labels beside the panel's comb, kept for frames that draw them while the comb animates.
    private var labelLines: (version: Int, dark: Bool, lines: [(name: CTLine, detail: CTLine)])?
    /// The latest frame time, for `panelSize`, which isn't given one.
    private var lastTime: Double?

    func tick(dt: Double, now: Date, snapshot: ActivitySnapshot) {
        let t = now.timeIntervalSince1970
        lastTime = t
        data.update(snapshot: snapshot, time: t)
    }

    func reset() {
        box = Comb(options: Self.boxOptions)
        panel = Comb(options: Self.panelOptions)
        boxKey = nil
        panelKey = nil
        hovered = nil
    }

    // MARK: Box

    func drawBox(size: CGSize, context ctx: CGContext, now: Date, snapshot: ActivitySnapshot, mouse: CGPoint?) {
        let t = now.timeIntervalSince1970
        lastTime = t
        data.update(snapshot: snapshot, time: t)
        box.sync(data, time: t)
        box.advance(time: t)
        let dark = Self.isDark
        let palette = self.palette(dark: dark)
        let scale = Offscreen.scale(of: ctx)

        // Hovered: the menu's highlight (labelColor 10% instead of the tile's 7%).
        if mouse != nil {
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.035).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
        }

        let key = CacheKey(dark: dark, version: data.version, settled: true, hovered: nil, size: size, scale: scale)
        if key != boxKey {
            boxKey = key
            boxCache.render(size: size, like: ctx) { c in
                drawBoxHeader(c, size: size)
                if data.groups.isEmpty {
                    let o = Self.boxOptions
                    Text.draw(Text.line("No recent sessions", font: .systemFont(ofSize: 11), color: .secondaryLabelColor),
                              in: c, centerX: (o.left + o.right) / 2, midY: Self.boxHeader + o.fixedHeight! / 2 - 1)
                }
            }
        }
        boxCache.draw(in: ctx)

        let partial = data.partial(at: t)
        let lastX = box.lastX(partial: partial, scale: scale)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: Self.boxHeader)
        box.draw(ctx, time: t, lastX: lastX, partial: partial, palette: palette, dark: dark)
        box.drawLinks(ctx, time: t, lastX: lastX, dark: dark)
        box.drawPips(ctx, time: t, data: data, dark: dark)
        ctx.restoreGState()
    }

    /// "Agents", then "8 running · 28 in 30 min" and a chevron at the right.
    private func drawBoxHeader(_ ctx: CGContext, size: CGSize) {
        let midY: CGFloat = 11.5
        Text.draw(Text.line("Agents", font: .systemFont(ofSize: 12, weight: .bold), color: .labelColor), in: ctx, x: 8, midY: midY)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let count = Text.rich([
            ("\(data.snapshot.agentsRunning)", digits, .labelColor), (" running · ", digits, .secondaryLabelColor),
            ("\(data.snapshot.agentsRecent)", digits, .labelColor), (" in 30 min", digits, .secondaryLabelColor),
        ])
        let chevronX = size.width - 6 - 7
        Text.draw(count, in: ctx, x: chevronX - 4 - Text.width(count), midY: midY)
        let chevron = CGMutablePath()
        chevron.move(to: CGPoint(x: chevronX + 1.5, y: midY - 3.5))
        chevron.addLine(to: CGPoint(x: chevronX + 5, y: midY))
        chevron.addLine(to: CGPoint(x: chevronX + 1.5, y: midY + 3.5))
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(chevron)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Panel

    func panelSize(for snapshot: ActivitySnapshot) -> CGSize {
        let t = lastTime ?? snapshot.time.timeIntervalSince1970
        data.update(snapshot: snapshot, time: t)
        panel.sync(data, time: t)
        return CGSize(width: PanelMetrics.width, height: panelGeometry.height)
    }

    private var panelGeometry: PanelGeometry {
        let sessions = data.groups.count
        let shown = sessions > PanelMetrics.maxTableRows ? PanelMetrics.maxTableRows - 1 : sessions
        return PanelGeometry(combHeight: panel.height, tableRows: shown, more: sessions - shown)
    }

    func drawPanel(size: CGSize, context ctx: CGContext, now: Date, snapshot: ActivitySnapshot, mouse: CGPoint?) {
        let t = now.timeIntervalSince1970
        lastTime = t
        data.update(snapshot: snapshot, time: t)
        panel.sync(data, time: t)
        panel.advance(time: t)
        let dark = Self.isDark
        let palette = self.palette(dark: dark)
        let scale = Offscreen.scale(of: ctx)
        let geometry = panelGeometry
        let origin = CGPoint(x: PanelMetrics.inset, y: PanelMetrics.combTop)

        let partial = data.partial(at: t)
        let lastX = panel.lastX(partial: partial, scale: scale)
        let settled = !panel.isAnimating(at: t)
        let hit = mouse.flatMap { panel.hitTest(CGPoint(x: $0.x - origin.x, y: $0.y - origin.y), time: t, lastX: lastX) }
        hovered = hit.map { data.tracks[$0].agent.id }

        // The text, with the session labels while they stand still.
        let key = CacheKey(dark: dark, version: data.version, settled: settled, hovered: hovered, size: size, scale: scale)
        if key != panelKey {
            panelKey = key
            panelCache.render(size: size, like: ctx) { c in
                drawPanelText(c, size: size, geometry: geometry, hovered: hit, palette: palette, dark: dark)
                c.translateBy(x: origin.x, y: origin.y)
                panel.drawAxis(c)
                if settled { drawLabels(c, time: t, palette: palette, dark: dark) }
            }
        }
        panelCache.draw(in: ctx, replacing: true)

        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        panel.draw(ctx, time: t, lastX: lastX, partial: partial, palette: palette, dark: dark)
        panel.drawLinks(ctx, time: t, lastX: lastX, dark: dark)
        if let hit { panel.drawOutline(ctx, agent: hit, time: t, lastX: lastX) }
        if !settled { drawLabels(ctx, time: t, palette: palette, dark: dark) }
        ctx.restoreGState()
    }

    /// Session names and "Opus · busy · 8/15" to the left of each band, following the band as it moves.
    private func drawLabels(_ ctx: CGContext, time t: Double, palette: Palette, dark: Bool) {
        let o = Self.panelOptions
        if data.groups.isEmpty {
            Text.draw(Text.line("No recent sessions", font: .systemFont(ofSize: 11), color: .secondaryLabelColor),
                      in: ctx, centerX: (o.left + o.right) / 2, midY: (panel.height - o.padBottom + o.padTop) / 2)
            return
        }
        if labelLines?.version != data.version || labelLines?.dark != dark {
            labelLines = (data.version, dark, data.groups.map { group in
                let s = group.session
                let ended = !s.isOpen
                var detail = ClaudeModel.family(s.model) + " · " + (s.isBusy ? "busy" : s.isOpen ? "idle" : "ended")
                if !s.agents.isEmpty { detail += " · \(s.runningAgents)/\(s.agents.count)" }
                let x: CGFloat = 8
                let name = Text.line(s.name, font: .systemFont(ofSize: 11, weight: .semibold),
                                     color: ended ? .tertiaryLabelColor : .labelColor, maxWidth: o.left - x - 22)
                let second = Text.line(detail, font: .systemFont(ofSize: 10),
                                       color: ended ? .tertiaryLabelColor : .secondaryLabelColor, maxWidth: o.left - x - 6)
                return (name, second)
            })
        }
        guard let lines = labelLines?.lines else { return }
        for (gi, group) in panel.groups.enumerated() where gi < lines.count {
            guard let row = group.main, row.dying == nil else { continue }
            let pitch = panel.shownPitch
            let top = panel.rowY(row, x: o.left, time: t) - pitch / 2
            let mid = top + max(CGFloat(group.rows) * pitch, 22) / 2
            let a = panel.bornAlpha(row, x: o.left, time: t)
            guard a > 0.01 else { continue }
            let session = data.groups[gi].session
            ctx.saveGState()
            ctx.setAlpha(a)
            let swatch = palette.color(palette.base(data.groups[gi].model))
            Hex.fill(ctx, x: 11.5, y: mid - 5.5, hw: 3.6, hv: 4.1, color: swatch, alpha: session.isOpen ? 1 : 0.4)
            Text.draw(lines[gi].name, in: ctx, x: 19, midY: mid - 5.5)
            Text.draw(lines[gi].detail, in: ctx, x: 8, midY: mid + 7)
            ctx.restoreGState()
        }
    }

    /// Everything in the panel but the comb: title, stat tiles, legend or hover readout, and the session table.
    private func drawPanelText(_ ctx: CGContext, size: CGSize, geometry g: PanelGeometry, hovered: Int?,
                               palette: Palette, dark: Bool) {
        let snap = data.snapshot
        let inset = PanelMetrics.inset, right = size.width - inset
        let digits = { (size: CGFloat, weight: NSFont.Weight) in NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) }

        Text.draw(Text.line("Claude Code Activity", font: .systemFont(ofSize: 13, weight: .bold), color: .labelColor),
                  in: ctx, x: inset, midY: 14)
        let window = Text.line("last 30 min", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        Text.draw(window, in: ctx, x: right - Text.width(window), midY: 14.5)

        // Stat tiles.
        let workflows = snap.workflowsRunning
        let tiles: [(String, String, String)] = [
            ("\(snap.agentsRunning)", workflows > 0 ? (workflows == 1 ? "1 workflow" : "\(workflows) workflows") : "", "agents running"),
            ("\(snap.agentsRecent)", "peak \(snap.peakParallel)", "agents · 30 min"),
            (ActivityFormat.tokens(snap.outputPerMinute), "", "output tok/min"),
            (ActivityFormat.tokens(snap.inputPerMinute), "", "input tok/min"),
        ]
        let tileGap: CGFloat = 6, tileTop: CGFloat = 29, tileHeight: CGFloat = 43
        let tileWidth = (size.width - 2 * inset - 3 * tileGap) / 4
        for (i, tile) in tiles.enumerated() {
            let x = inset + CGFloat(i) * (tileWidth + tileGap)
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.07).cgColor)  // Core Text changes the fill color
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: tileTop, width: tileWidth, height: tileHeight),
                               cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.fillPath()
            var parts: [(String, NSFont, NSColor)] = [(tile.0, digits(15, .semibold), .labelColor)]
            if !tile.1.isEmpty { parts.append(("  " + tile.1, .systemFont(ofSize: 10), .secondaryLabelColor)) }
            Text.draw(Text.rich(parts), in: ctx, x: x + 8, baseline: tileTop + 20.5)
            Text.draw(Text.line(tile.2, font: .systemFont(ofSize: 10), color: .secondaryLabelColor, maxWidth: tileWidth - 12),
                      in: ctx, x: x + 8, midY: tileTop + 31.5)
        }

        // Legend, or a readout of the agent under the mouse.
        let legendMid = g.legendTop + 11
        if let hovered {
            drawReadout(ctx, track: data.tracks[hovered], midY: legendMid, left: inset, right: right, palette: palette)
        } else {
            drawLegend(ctx, midY: legendMid, left: inset, right: right, palette: palette)
        }

        guard g.hasTable else { return }
        ctx.setFillColor(NSColor.separatorColor.cgColor)
        ctx.fill(CGRect(x: inset, y: g.legendTop + 25, width: size.width - 2 * inset, height: 1))

        // Session table.
        let columns: [CGFloat] = [244, 313, 380, 460]  // right edges of Agents, Output, Input and Out/min
        let barX: CGFloat = 465, barWidth: CGFloat = 28
        var y = g.tableTop
        let header = NSFont.systemFont(ofSize: 10, weight: .semibold)
        Text.draw(Text.line("Session", font: header, color: .secondaryLabelColor), in: ctx, x: inset, midY: y + 9)
        for (title, edge) in zip(["Agents", "Output", "Input", "Out/min"], [columns[0], columns[1], columns[2], right]) {
            let line = Text.line(title, font: header, color: .secondaryLabelColor)
            Text.draw(line, in: ctx, x: edge - Text.width(line), midY: y + 9)
        }
        y += 18
        let rows = data.groups.map { group -> (SessionActivity, Int, Double, Double, Double) in
            var output = 0.0, input = 0.0, rate = 0.0
            for thread in group.session.threads {
                for (i, bucket) in thread.buckets.enumerated() {
                    output += bucket.output
                    input += bucket.input
                    if i >= thread.buckets.count - 12 { rate += bucket.output }
                }
            }
            return (group.session, group.model, output, input, rate)
        }
        let maxRate = max(1, rows.map(\.4).max() ?? 0)
        let regular = digits(11, .regular)
        func cell(_ text: String, _ edge: CGFloat, _ color: NSColor, _ font: NSFont, _ mid: CGFloat) {
            let line = Text.line(text, font: font, color: color)
            Text.draw(line, in: ctx, x: edge - Text.width(line), midY: mid)
        }
        for (session, model, output, input, rate) in rows.prefix(g.tableRows) {
            let mid = y + 8.5
            let ended = !session.isOpen
            let base = palette.color(palette.base(model))
            Hex.fill(ctx, x: inset + 4.5, y: mid, hw: 4, hv: 4.5, color: base, alpha: ended ? 0.4 : 1)
            Text.draw(Text.line(session.name, font: .systemFont(ofSize: 11), color: ended ? .tertiaryLabelColor : .labelColor,
                                maxWidth: 150), in: ctx, x: inset + 14, midY: mid)
            let primary: NSColor = ended ? .tertiaryLabelColor : .labelColor
            let muted: NSColor = ended ? .tertiaryLabelColor : .secondaryLabelColor
            cell(session.agents.isEmpty ? "–" : "\(session.runningAgents) / \(session.agents.count)", columns[0], muted, regular, mid)
            cell(ActivityFormat.tokens(output), columns[1], primary, regular, mid)
            cell(ActivityFormat.tokens(input), columns[2], muted, regular, mid)
            cell(ActivityFormat.tokens(rate), columns[3], primary, regular, mid)
            let w = (barWidth * CGFloat(rate / maxRate)).rounded()
            if w >= 1 {
                ctx.saveGState()
                ctx.setAlpha(0.85)
                ctx.setFillColor(base)
                ctx.addPath(CGPath(roundedRect: CGRect(x: barX, y: mid - 2.5, width: max(w, 5), height: 5),
                                   cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
                ctx.fillPath()
                ctx.restoreGState()
            }
            y += PanelMetrics.rowHeight
        }
        if g.more > 0 {
            Text.draw(Text.line("\(g.more) more", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor),
                      in: ctx, x: inset + 14, midY: y + 8.5)
            y += PanelMetrics.rowHeight
        }
        ctx.setFillColor(NSColor.separatorColor.cgColor)
        ctx.fill(CGRect(x: inset, y: y, width: size.width - 2 * inset, height: 1))
        let mid = y + 1 + 9.5
        let bold = digits(11, .semibold)
        let running = rows.reduce(0) { $0 + $1.0.runningAgents }, agents = rows.reduce(0) { $0 + $1.0.agents.count }
        Text.draw(Text.line("Total", font: .systemFont(ofSize: 11, weight: .semibold), color: .labelColor), in: ctx, x: inset, midY: mid)
        cell("\(running) / \(agents)", columns[0], .secondaryLabelColor, bold, mid)
        cell(ActivityFormat.tokens(rows.reduce(0) { $0 + $1.2 }), columns[1], .labelColor, bold, mid)
        cell(ActivityFormat.tokens(rows.reduce(0) { $0 + $1.3 }), columns[2], .secondaryLabelColor, bold, mid)
        cell(ActivityFormat.tokens(rows.reduce(0) { $0 + $1.4 }), columns[3], .labelColor, bold, mid)
    }

    /// The models on the left, and what the scales mean on the right.
    private func drawLegend(_ ctx: CGContext, midY: CGFloat, left: CGFloat, right: CGFloat, palette: Palette) {
        let font = NSFont.systemFont(ofSize: 10)
        var x = left
        for (family, model) in data.families {
            Hex.fill(ctx, x: x + 4.5, y: midY, hw: 4, hv: 4.5, color: palette.color(palette.base(model)), alpha: 1)
            let line = Text.line(family, font: font, color: .secondaryLabelColor)
            Text.draw(line, in: ctx, x: x + 12, midY: midY)
            x += 12 + Text.width(line) + 10
        }
        let opus = data.models.index(of: "claude-opus")
        let base = palette.base(opus)
        let items = ["generating", "tool", "waiting"].map { Text.line($0, font: font, color: .secondaryLabelColor) }
        var cursor = right - items.reduce(0) { $0 + 12 + Text.width($1) } - 20
        for (i, line) in items.enumerated() {
            let cx = cursor + 4.5
            switch i {
            case 0:
                Hex.fill(ctx, x: cx, y: midY, hw: 4, hv: 4.5, color: palette.color(base + 1 + 4), alpha: 1)
                Hex.sheen(ctx, x: cx, y: midY, hw: 4, hv: 4.5, alpha: 0.28)
            case 1:
                Hex.fill(ctx, x: cx, y: midY, hw: 4, hv: 4.5, color: palette.color(base), alpha: 0.32)
                ctx.setFillColor(palette.color(base + 33))
                ctx.fillEllipse(in: CGRect(x: cx - 1.6, y: midY - 1.6, width: 3.2, height: 3.2))
            default:
                ctx.saveGState()
                ctx.setStrokeColor(palette.color(base))
                ctx.setLineWidth(1)
                ctx.addPath(Hex.path(x: cx, y: midY, hw: 3.5, hv: 4))
                ctx.strokePath()
                ctx.restoreGState()
            }
            Text.draw(line, in: ctx, x: cursor + 12, midY: midY)
            cursor += 12 + Text.width(line) + 10
        }
    }

    /// The hovered agent: name, model and workflow, then its tokens, age and state.
    private func drawReadout(_ ctx: CGContext, track: Track, midY: CGFloat, left: CGFloat, right: CGFloat, palette: Palette) {
        let a = track.agent
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let state: String
        switch a.state {
        case .finished: state = "done"
        case .generating: state = "generating"
        case .tool: state = "tool call"
        case .waiting: state = "waiting"
        case .idle: state = "idle"
        }
        let age = (a.end ?? data.snapshot.time).timeIntervalSince(a.start)
        let input = a.inputTokens + a.cacheReadTokens + a.cacheWriteTokens
        let tail = Text.rich([
            (ActivityFormat.tokens(Double(a.outputTokens)) + " out · " + ActivityFormat.tokens(Double(input)) + " in   ", font, .labelColor),
            (ActivityFormat.duration(age) + " · " + state, font, .secondaryLabelColor),
        ])
        let tailX = right - Text.width(tail)
        Text.draw(tail, in: ctx, x: tailX, midY: midY)

        Hex.fill(ctx, x: left + 4.5, y: midY, hw: 4, hv: 4.5, color: palette.color(palette.base(track.model)), alpha: 1)
        var muted = ClaudeModel.name(a.model)
        if let id = a.workflowID, let wf = data.snapshot.session(a.sessionID)?.workflows.first(where: { $0.id == id }) {
            muted += " · " + wf.name
        }
        let head = Text.rich([
            (a.kind == .main ? a.label + " (main)" : a.label, .systemFont(ofSize: 11, weight: .semibold), .labelColor),
            ("  " + muted, .systemFont(ofSize: 11), .secondaryLabelColor),
        ])
        Text.draw(Text.truncate(head, width: tailX - left - 14 - 10), in: ctx, x: left + 14, midY: midY)
    }

    // MARK: Helpers

    private static var isDark: Bool {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func palette(dark: Bool) -> Palette {
        if let palette = palettes[dark] { return palette }
        let palette = Palette(models: data.models, dark: dark)
        palettes[dark] = palette
        return palette
    }
}

// MARK: - Constants and helpers

private enum Grid {
    static let columnSeconds: Double = 40
    /// 46 full columns (about 30 minutes) and the one filling now.
    static let columns = 47
    /// Columns before the newest five, whose scales never animate once settled. In the newest five, the
    /// shimmer of a generating agent fades out (and the newest column grows in), so those are drawn each frame.
    static let staticColumns = columns - 5
    /// How fast a layout change spreads, in points per second, and how long one scale takes to settle.
    static let rippleSpeed: CGFloat = 420
    static let settleTime: Double = 0.5
    static let rippleLife: Double = 2.2
    static let fadeOut: Double = 0.35
}

private enum PanelMetrics {
    static let width: CGFloat = 504
    static let inset: CGFloat = 10
    static let combTop: CGFloat = 80
    static let rowHeight: CGFloat = 17
    static let maxTableRows = 12
}

/// The panel's vertical layout below the comb.
private struct PanelGeometry {
    var combHeight: CGFloat
    var tableRows: Int
    var more: Int
    var hasTable: Bool { tableRows > 0 }
    var legendTop: CGFloat { PanelMetrics.combTop + combHeight }
    var tableTop: CGFloat { legendTop + 30 }
    var height: CGFloat {
        guard hasTable else { return legendTop + 22 + 6 }
        return tableTop + 18 + CGFloat(tableRows + (more > 0 ? 1 : 0)) * PanelMetrics.rowHeight + 20 + 7
    }
}

/// What a cached bitmap was drawn from; it's redrawn when any of it changes.
private struct CacheKey: Equatable {
    var dark: Bool
    var version: Int
    var settled: Bool
    var hovered: String?
    var size: CGSize
    var scale: CGFloat
}

@inline(__always) private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { v < lo ? lo : v > hi ? hi : v }
@inline(__always) private func ease(_ u: Double) -> Double { u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u) }

/// Pointy-top hexagons, centered on (x, y) with half-width `hw` and half-height `hv`.
private enum Hex {
    /// Adds a hexagon to `path`, point by point: `addPath(_:transform:)` gets slower the longer the path.
    @inline(__always) static func add(to path: CGMutablePath, _ x: CGFloat, _ y: CGFloat, _ hw: CGFloat, _ hv: CGFloat) {
        path.move(to: CGPoint(x: x, y: y - hv))
        path.addLine(to: CGPoint(x: x + hw, y: y - hv / 2))
        path.addLine(to: CGPoint(x: x + hw, y: y + hv / 2))
        path.addLine(to: CGPoint(x: x, y: y + hv))
        path.addLine(to: CGPoint(x: x - hw, y: y + hv / 2))
        path.addLine(to: CGPoint(x: x - hw, y: y - hv / 2))
        path.closeSubpath()
    }

    /// The upper half of a hexagon, for the sheen on bright scales.
    @inline(__always) static func addUpperHalf(to path: CGMutablePath, _ x: CGFloat, _ y: CGFloat, _ hw: CGFloat, _ hv: CGFloat) {
        path.move(to: CGPoint(x: x, y: y - hv))
        path.addLine(to: CGPoint(x: x + hw, y: y - hv / 2))
        path.addLine(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x - hw, y: y - hv / 2))
        path.closeSubpath()
    }

    static func path(x: CGFloat, y: CGFloat, hw: CGFloat, hv: CGFloat) -> CGPath {
        let path = CGMutablePath()
        add(to: path, x, y, hw, hv)
        return path
    }

    static func fill(_ ctx: CGContext, x: CGFloat, y: CGFloat, hw: CGFloat, hv: CGFloat, color: CGColor, alpha: CGFloat) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setFillColor(color)
        ctx.addPath(path(x: x, y: y, hw: hw, hv: hv))
        ctx.fillPath()
        ctx.restoreGState()
    }

    static func sheen(_ ctx: CGContext, x: CGFloat, y: CGFloat, hw: CGFloat, hv: CGFloat, alpha: CGFloat) {
        let path = CGMutablePath()
        addUpperHalf(to: path, x, y, hw, hv)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setFillColor(.white)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

/// Shapes collected by color and (quantized) alpha, so a frame fills a few dozen paths instead of
/// one per scale.
private struct Batch {
    private(set) var paths: [Int: CGMutablePath] = [:]

    @inline(__always) private mutating func path(_ slot: Int, _ alpha: CGFloat) -> CGMutablePath? {
        let level = Int((alpha * 48).rounded())
        guard level > 0 else { return nil }
        let key = slot << 6 | min(level, 48)
        if let p = paths[key] { return p }
        let p = CGMutablePath()
        paths[key] = p
        return p
    }

    mutating func hex(_ slot: Int, _ alpha: CGFloat, _ x: CGFloat, _ y: CGFloat, _ hw: CGFloat, _ hv: CGFloat) {
        if let p = path(slot, alpha) { Hex.add(to: p, x, y, hw, hv) }
    }

    mutating func sheen(_ alpha: CGFloat, _ x: CGFloat, _ y: CGFloat, _ hw: CGFloat, _ hv: CGFloat) {
        if let p = path(0, alpha) { Hex.addUpperHalf(to: p, x, y, hw, hv) }
    }

    mutating func dot(_ slot: Int, _ alpha: CGFloat, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        path(slot, alpha)?.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    mutating func line(_ slot: Int, _ alpha: CGFloat, from a: CGPoint, to b: CGPoint) {
        guard let p = path(slot, alpha) else { return }
        p.move(to: a)
        p.addLine(to: b)
    }

    func fill(_ ctx: CGContext, color: (Int) -> CGColor) {
        for (key, p) in paths {
            ctx.setAlpha(CGFloat(key & 63) / 48)
            ctx.setFillColor(color(key >> 6))
            ctx.addPath(p)
            ctx.fillPath()
        }
        ctx.setAlpha(1)
    }

    func stroke(_ ctx: CGContext, color: (Int) -> CGColor) {
        for (key, p) in paths {
            ctx.setAlpha(CGFloat(key & 63) / 48)
            ctx.setStrokeColor(color(key >> 6))
            ctx.addPath(p)
            ctx.strokePath()
        }
        ctx.setAlpha(1)
    }
}

/// The scales of one frame (or of one update of a comb's bitmap), sorted into the layers they're drawn in.
private struct Layers {
    var isEmpty = true
    let bg = CGMutablePath()
    let dormant = CGMutablePath()
    var rippled = Batch()
    var glows: [(x: CGFloat, y: CGFloat, model: Int, alpha: CGFloat)] = []
    var lit = Batch()
    var gloss = Batch()
    var embers = Batch()
    var strokes = Batch()

    func draw(_ ctx: CGContext, clip: CGRect, hw: CGFloat, hv: CGFloat, palette: Palette, dark: Bool) {
        guard !isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: clip)
        // 1. Dim scales: empty lanes and gaps in time, then idle stretches of an agent's life.
        let ink = NSColor.labelColor
        if !bg.isEmpty {
            ctx.setFillColor(ink.withAlphaComponent(dark ? 0.06 : 0.045).cgColor)
            ctx.addPath(bg)
            ctx.fillPath()
        }
        if !dormant.isEmpty {
            ctx.setFillColor(ink.withAlphaComponent(dark ? 0.13 : 0.1).cgColor)
            ctx.addPath(dormant)
            ctx.fillPath()
        }
        rippled.fill(ctx, color: palette.color)
        // 2. Glow under the scales generating right now: added light in dark mode, a soft tint in light mode.
        if !glows.isEmpty {
            ctx.saveGState()
            if dark { ctx.setBlendMode(.plusLighter) }
            let radius = max(hw, hv) * 2.6
            for glow in glows {
                guard let gradient = palette.glow(glow.model) else { continue }
                ctx.setAlpha(glow.alpha)
                let center = CGPoint(x: glow.x, y: glow.y)
                ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
            }
            ctx.restoreGState()
        }
        // 3. Lit scales, a sheen on the bright ones, embers in tool calls, outlines while waiting.
        lit.fill(ctx, color: palette.color)
        gloss.fill(ctx, color: palette.color)
        embers.fill(ctx, color: palette.color)
        ctx.setLineWidth(1)
        strokes.stroke(ctx, color: palette.color)
        ctx.restoreGState()
    }
}

/// One line of text, set with Core Text: faster than NSAttributedString drawing, and it works the same in
/// the flipped bitmaps here.
private enum Text {
    private static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    static func line(_ string: String, font: NSFont, color: NSColor, maxWidth: CGFloat? = nil) -> CTLine {
        let line = rich([(string, font, color)])
        return maxWidth.map { truncate(line, width: $0) } ?? line
    }

    static func rich(_ parts: [(String, NSFont, NSColor)]) -> CTLine {
        let text = NSMutableAttributedString()
        for (string, font, color) in parts {
            text.append(NSAttributedString(string: string, attributes: [.font: font, colorKey: color.cgColor]))
        }
        return CTLineCreateWithAttributedString(text)
    }

    static func truncate(_ line: CTLine, width: CGFloat) -> CTLine {
        guard self.width(line) > width else { return line }
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        let attributes = runs.last.map { CTRunGetAttributes($0) as NSDictionary as? [NSAttributedString.Key: Any] ?? [:] } ?? [:]
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        return CTLineCreateTruncatedLine(line, Double(max(width, 1)), .end, token) ?? line
    }

    static func width(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Draws `line` starting at `x`, its glyph box centered on `midY`.
    static func draw(_ line: CTLine, in ctx: CGContext, x: CGFloat, midY: CGFloat) {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        draw(line, in: ctx, x: x, baseline: midY + (ascent - descent) / 2)
    }

    static func draw(_ line: CTLine, in ctx: CGContext, centerX: CGFloat, midY: CGFloat) {
        draw(line, in: ctx, x: centerX - width(line) / 2, midY: midY)
    }

    static func draw(_ line: CTLine, in ctx: CGContext, x: CGFloat, baseline: CGFloat) {
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: (baseline * 2).rounded() / 2)
        CTLineDraw(line, ctx)
    }
}

/// A bitmap for what changes less often than every frame, drawn in the same flipped coordinates as the
/// surface it's copied to, at the surface's scale so the copy is pixel for pixel.
private final class Offscreen {
    private var context: CGContext?
    private var image: CGImage?
    private var size = CGSize.zero

    static func scale(of ctx: CGContext) -> CGFloat {
        let m = ctx.userSpaceToDeviceSpaceTransform
        return max(1, (m.a * m.a + m.b * m.b).squareRoot())
    }

    /// Clears the bitmap, sized for `size` points at the scale of `destination`.
    func begin(size: CGSize, like destination: CGContext) {
        image = nil  // released first, so drawing doesn't copy its pixels
        let scale = Self.scale(of: destination)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { context = nil; return }
        let space = destination.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if context?.width != width || context?.height != height || context?.colorSpace != space {
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.translateBy(x: 0, y: CGFloat(height))
            context?.scaleBy(x: scale, y: -scale)
        }
        self.size = size
        context?.clear(CGRect(origin: .zero, size: size))
    }

    /// Draws more into the bitmap, over what's there.
    func update(_ draw: (CGContext) -> Void) {
        guard let context else { return }
        image = nil
        context.saveGState()
        draw(context)
        context.restoreGState()
        image = context.makeImage()
    }

    func render(size: CGSize, like destination: CGContext, draw: (CGContext) -> Void) {
        begin(size: size, like: destination)
        update(draw)
    }

    /// Draws the bitmap at the origin. `replacing` copies its pixels instead of blending them, which is
    /// several times faster and right when nothing has been drawn there yet.
    func draw(in ctx: CGContext, replacing: Bool = false) {
        guard let image else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        if replacing { ctx.setBlendMode(.copy) }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }
}

// MARK: - Colors

/// Model IDs seen so far, numbered so cells and palettes can refer to them cheaply.
private final class ModelTable {
    private(set) var ids: [String] = []
    private var indices: [String: Int] = [:]

    func index(of id: String) -> Int {
        if let i = indices[id] { return i }
        indices[id] = ids.count
        ids.append(id)
        return ids.count - 1
    }
}

/// Colors for one appearance, in slots for `Batch`: slot 0 is white, slot 1 Claude's accent, and each model
/// has a block of 34: its base color, an iridescent ring of 32 tints for the shimmer, and an ember core.
private final class Palette {
    let dark: Bool
    private let models: ModelTable
    private var colors: [CGColor]
    private var blocks: [Int: Int] = [:]
    private var gradients: [Int: CGGradient] = [:]
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static let white = 0, accent = 1

    init(models: ModelTable, dark: Bool) {
        self.models = models
        self.dark = dark
        colors = [CGColor(gray: 1, alpha: 1), NSColor.claude.cgColor]
    }

    @inline(__always) func color(_ slot: Int) -> CGColor { colors[slot] }

    /// The slot of a model's base color; its ring follows at +1…+32 and its core at +33.
    func base(_ model: Int) -> Int {
        if let block = blocks[model] { return block }
        let block = colors.count
        let rgb = NSColor(cgColor: ClaudeModel.color(models.ids[model]).cgColor)?.usingColorSpace(.sRGB) ?? .gray
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        let (h, s, l) = Self.hsl(r, g, b)
        colors.append(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        for i in 0..<32 {
            let th = CGFloat(i) / 32 * 2 * .pi
            colors.append(Self.color(h: h + 0.07 * sin(th), s: clamp(s + 0.08, 0, 1),
                                     l: clamp(l + (dark ? 0.1 : 0.04) + (dark ? 0.1 : 0.07) * cos(th), 0, dark ? 0.86 : 0.74)))
        }
        colors.append(Self.color(h: h + 0.03, s: clamp(s + 0.1, 0, 1), l: dark ? 0.78 : 0.42))
        blocks[model] = block
        gradients[model] = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: r, green: g, blue: b, alpha: dark ? 0.55 : 0.38), CGColor(srgbRed: r, green: g, blue: b, alpha: 0),
        ] as CFArray, locations: [0, 1])
        return block
    }

    func glow(_ model: Int) -> CGGradient? {
        _ = base(model)
        return gradients[model]
    }

    private static func hsl(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: CGFloat
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    private static func color(h: CGFloat, s: CGFloat, l: CGFloat) -> CGColor {
        let h = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        guard s > 0 else { return CGColor(srgbRed: l, green: l, blue: l, alpha: 1) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func channel(_ t: CGFloat) -> CGFloat {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return CGColor(srgbRed: channel(h + 1.0 / 3), green: channel(h), blue: channel(h - 1.0 / 3), alpha: 1)
    }
}

// MARK: - Data

private enum ScaleState: UInt8 { case idle, generating, tool, waiting }

/// One agent's activity in one 40-second column.
private struct ColumnSample {
    /// Fractions of the column spent generating, in a tool call, and waiting on subagents.
    var generating: Float = 0
    var tool: Float = 0
    var waiting: Float = 0
    var output: Float = 0
}

/// An agent's history in columns, with what the comb needs to know about it.
private struct Track {
    var agent: AgentActivity
    var model: Int
    /// The first column it's alive in, and when it ended (infinity while it runs).
    var firstColumn: Int
    var end: Double
    var columns: [ColumnSample]
    /// What it's doing now; nil once it has finished.
    var live: ScaleState?
}

/// A session's band: its main thread and its subagents in lanes.
private struct Group {
    var session: SessionActivity
    var model: Int
    var main: Int
    /// Track indices per lane. A lane holds agents one after another; empty lanes keep their place.
    var lanes: [[Int]]
}

/// The snapshot in columns, shared by the box and the panel. Rebuilt when the snapshot changes or a new
/// column starts, which is when `version` changes.
private final class ScaleData {
    private(set) var version = 0
    private(set) var snapshot = ActivitySnapshot.empty
    /// The start of the column filling now, in seconds since 1970 (columns are aligned to multiples of 40 s
    /// so they scroll steadily).
    private(set) var lastStart: Double = 0
    private(set) var tracks: [Track] = []
    private(set) var groups: [Group] = []
    /// Model families in the window, for the legend: (name, model index).
    private(set) var families: [(String, Int)] = []
    let models = ModelTable()
    private var snapshotTime: Date?
    /// Each session's lane per agent, kept while the agent is in the window so lanes don't jump around.
    private var lanes: [String: [String: Int]] = [:]

    var windowStart: Double { lastStart - Double(Grid.columns - 1) * Grid.columnSeconds }

    /// How far the column filling now has filled, 0–1.
    func partial(at t: Double) -> Double { clamp((t - lastStart) / Grid.columnSeconds, 0, 1) }

    func update(snapshot: ActivitySnapshot, time t: Double) {
        let start = (t / Grid.columnSeconds).rounded(.down) * Grid.columnSeconds
        guard snapshot.time != snapshotTime || start != lastStart else { return }
        snapshotTime = snapshot.time
        self.snapshot = snapshot
        lastStart = start
        version += 1
        rebuild()
    }

    private func rebuild() {
        let B = Grid.columnSeconds, N = Grid.columns
        let ws = windowStart
        let count = ActivitySnapshot.bucketCount, width = ActivitySnapshot.bucketSeconds
        let snapT = snapshot.time.timeIntervalSince1970
        var bucketColumn = [Int](repeating: -1, count: count)
        for k in 0..<count {
            let mid = snapT - Double(count - k) * width + width / 2
            let c = Int(((mid - ws) / B).rounded(.down))
            if c >= 0, c < N { bucketColumn[k] = c }
        }
        // The column filling now covers only the time up to the snapshot.
        let lastCover = Float(clamp(snapT - (ws + Double(N - 1) * B), width, B))

        func track(_ a: AgentActivity) -> Track {
            var columns = [ColumnSample](repeating: ColumnSample(), count: N)
            for (k, bucket) in a.buckets.prefix(count).enumerated() {
                let c = bucketColumn[k]
                guard c >= 0 else { continue }
                columns[c].generating += Float(bucket.generating)
                columns[c].tool += Float(bucket.tool)
                columns[c].output += Float(bucket.output)
            }
            for c in 0..<N {
                let cover = c == N - 1 ? lastCover : Float(B)
                columns[c].generating = min(1, columns[c].generating / cover)
                columns[c].tool = min(1, columns[c].tool / cover)
            }
            let live: ScaleState?
            switch a.state {
            case _ where a.end != nil: live = nil
            case .generating: live = .generating
            case .tool: live = .tool
            case .waiting: live = .waiting
            case .idle: live = .idle
            case .finished: live = nil
            }
            return Track(agent: a, model: models.index(of: a.model),
                         firstColumn: max(0, Int(((a.start.timeIntervalSince1970 - ws) / B).rounded(.down))),
                         end: a.end?.timeIntervalSince1970 ?? .infinity, columns: columns, live: live)
        }

        var tracks: [Track] = [], groups: [Group] = []
        var seen = Set<String>()
        for s in snapshot.sessions {
            if let ended = s.endedAt, ended.timeIntervalSince1970 < ws { continue }
            seen.insert(s.id)
            let visible = s.agents
                .filter { $0.end.map { $0.timeIntervalSince1970 > ws } ?? true }
                .sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
            let ids = Set(visible.map(\.id))
            var assigned = (lanes[s.id] ?? [:]).filter { ids.contains($0.key) }
            // Lanes in use, by when their last agent ends; a new agent takes the lowest lane whose
            // last agent ended in an earlier column.
            var laneEnd: [Double] = []
            func grow(_ l: Int) { while laneEnd.count <= l { laneEnd.append(-.infinity) } }
            for a in visible {
                guard let l = assigned[a.id] else { continue }
                grow(l)
                laneEnd[l] = max(laneEnd[l], a.end?.timeIntervalSince1970 ?? .infinity)
            }
            for a in visible where assigned[a.id] == nil {
                let startColumn = (a.start.timeIntervalSince1970 / B).rounded(.down)
                var l = 0
                while l < laneEnd.count, laneEnd[l] != -.infinity, !((laneEnd[l] / B).rounded(.down) < startColumn) { l += 1 }
                assigned[a.id] = l
                grow(l)
                laneEnd[l] = a.end?.timeIntervalSince1970 ?? .infinity
            }
            lanes[s.id] = assigned

            let main = tracks.count
            tracks.append(track(s.main))
            var laneList = [[Int]](repeating: [], count: laneEnd.count)
            var alive = [Bool](repeating: false, count: N)
            for a in visible {
                laneList[assigned[a.id]!].append(tracks.count)
                let t = track(a)
                for c in t.firstColumn..<N where ws + Double(c) * B < t.end { alive[c] = true }
                tracks.append(t)
            }
            // History doesn't tell a tool call from waiting on subagents: the main thread's tool time
            // while its subagents run is taken as waiting.
            for c in 0..<N where alive[c] {
                tracks[main].columns[c].waiting = tracks[main].columns[c].tool
                tracks[main].columns[c].tool = 0
            }
            groups.append(Group(session: s, model: tracks[main].model, main: main, lanes: laneList))
        }
        lanes = lanes.filter { seen.contains($0.key) }
        self.tracks = tracks
        self.groups = groups

        let order = ["Opus", "Sonnet", "Haiku", "Fable"]
        var families: [String: Int] = [:]
        for t in tracks where families[ClaudeModel.family(t.agent.model)] == nil {
            families[ClaudeModel.family(t.agent.model)] = t.model
        }
        self.families = families.sorted { a, b in
            let ia = order.firstIndex(of: a.key) ?? order.count, ib = order.firstIndex(of: b.key) ?? order.count
            return ia != ib ? ia < ib : a.key < b.key
        }.map { ($0.key, $0.value) }
    }
}

// MARK: - Comb

/// One scale's data: its agents merged, if a row holds several (an overflow lane).
private struct Cell {
    var present = false
    var state = ScaleState.idle
    var heat: Float = 0
    var generating: Float = 0
    var tool: Float = 0
    var waiting: Float = 0
    var output: Float = 0
    var model = 0
    /// The busiest agent in the cell, and in the newest column the one doing the most right now.
    var agent = -1
    var live: ScaleState?
    var liveAgent = -1
    /// Whether the cell's agent is generating now, so its newest scales shimmer.
    var shimmers = false
}

/// A honeycomb laid out for one surface (the box or the panel), with its animation state.
private final class Comb {
    struct Options {
        var width: CGFloat
        /// The box has a fixed height and fits the rows to it; the panel grows up to `maxHeight`.
        var fixedHeight: CGFloat?
        var maxHeight: CGFloat
        /// The honeycomb's x range.
        var left: CGFloat
        var right: CGFloat
        var padTop: CGFloat
        var padBottom: CGFloat
        var columnWidth: CGFloat
        /// The space between sessions, in rows.
        var gap: CGFloat
        var minPitch: CGFloat
        /// The most lanes a session shows; more are merged into the last.
        var laneCap: Int
        var minGroupHeight: CGFloat
        var cellGap: CGFloat
        var linkAlpha: CGFloat
        /// Rows of empty scales when there are no sessions (0: as many as fit).
        var emptyRows: Int
    }

    /// A ripple or a row's arrival, spreading from a point.
    struct Wave {
        var t0: Double
        var x: CGFloat
        var y: CGFloat
    }

    struct Shift {
        var wave: Wave
        var distance: CGFloat
    }

    struct Ripple {
        var wave: Wave
        var strength: CGFloat
    }

    final class Row {
        let key: String
        /// The group it belongs to, or -1 for the empty state's rows and rows on their way out.
        var group = -1
        var r = 0
        /// Where the row was before its pending shifts, and where they leave it. A shift moves each scale
        /// when its wave reaches it, so the row bends as the ripple passes.
        var y0: CGFloat
        var target: CGFloat
        var shifts: [Shift] = []
        /// A new row's scales grow in as the wave reaches them; a removed row fades out from `dying`.
        var born: Wave?
        var dying: Double?
        var cells: [Cell] = []
        /// Which of its scales are in the comb's bitmap.
        var cached: [Bool] = []

        init(key: String, y: CGFloat, born: Wave) {
            self.key = key
            y0 = y
            target = y
            self.born = born
        }
    }

    struct GroupLayout {
        var rows: Int
        var lanes: Int
        var rowList: [Row]
        var main: Row? { rowList.first }
    }

    struct Link {
        var parent: Row
        var child: Row
        var column: Int
    }

    let o: Options
    /// The pitch of a regular honeycomb with this column width.
    let regularPitch: CGFloat
    private(set) var rows: [Row] = []
    private var rowByKey: [String: Row] = [:]
    private var ripples: [Ripple] = []
    /// The lanes shown per session at the last layout, to tell where a change began; nil before the first.
    private var previous: [String: Int]?
    /// The row pitch, and the one drawn, which eases toward it.
    private(set) var pitch: CGFloat
    private(set) var shownPitch: CGFloat
    private(set) var height: CGFloat
    private(set) var groups: [GroupLayout] = []
    private var links: [Link] = []
    private var version = -1
    private var lastAdvance: Double?
    /// Counts layout changes, which invalidate the bitmap of settled scales.
    private var generation = 0
    private let cellCache = Offscreen()
    private var cellKey: CellKey?
    /// Whether every scale but the newest few is in the bitmap, so frames needn't look at the rest.
    private var fullyCached = false

    private struct CellKey: Equatable {
        var dark: Bool
        var version: Int
        var generation: Int
        var lastX: CGFloat
        var scale: CGFloat
    }

    init(options: Options) {
        o = options
        regularPitch = 1.5 * (options.columnWidth / 2 / (3.0.squareRoot() / 2))
        pitch = regularPitch
        shownPitch = regularPitch
        height = options.fixedHeight ?? options.padTop + options.padBottom
    }

    /// The x of the newest column's center (in even rows), on the device pixel grid so the cached
    /// scales and the ones drawn each frame line up.
    func lastX(partial: Double, scale: CGFloat) -> CGFloat {
        let x = o.right - o.columnWidth / 2 - o.columnWidth * CGFloat(partial)
        return (x * scale).rounded() / scale
    }

    func sync(_ data: ScaleData, time t: Double) {
        guard version != data.version else { return }
        version = data.version
        layout(data.groups, time: t)
        fillCells(data)
    }

    // MARK: Layout

    private func layout(_ data: [Group], time t: Double) {
        let S = data.count
        var ks = data.map { min($0.lanes.count, o.laneCap) }
        var rowsPer: [Int] = []
        var p = regularPitch
        let H: CGFloat
        func widest(above floor: Int) -> Int? {
            var index: Int?, most = floor
            for (i, k) in ks.enumerated() where k > most { most = k; index = i }
            return index
        }
        let gaps = CGFloat(max(0, S - 1)) * o.gap
        if S == 0 {
            // No sessions: a few rows of empty scales.
            if let fixed = o.fixedHeight {
                let avail = fixed - o.padTop - o.padBottom
                let n = max(1, Int(avail / regularPitch))
                p = avail / CGFloat(n)
                H = fixed
                rowsPer = [n]
            } else {
                rowsPer = [o.emptyRows]
                H = (CGFloat(o.emptyRows) * p + o.padTop + o.padBottom).rounded()
            }
        } else if let fixed = o.fixedHeight {
            let avail = fixed - o.padTop - o.padBottom
            // Merge the widest sessions' extra lanes until the rows fit at the smallest pitch.
            var guardCount = 400
            while guardCount > 0, (CGFloat(ks.reduce(0, +) + S) + gaps) * o.minPitch > avail, let i = widest(above: 0) {
                ks[i] -= 1
                guardCount -= 1
            }
            rowsPer = ks.map { 1 + $0 }
            // Spare room becomes empty lanes for the thinnest bands, so every session has a band of dim scales.
            let maxRows = Int((avail / regularPitch - gaps).rounded(.down))
            var spare = maxRows - rowsPer.reduce(0, +)
            while spare > 0 {
                var j = 0
                for i in 1..<S where rowsPer[i] < rowsPer[j] { j = i }
                rowsPer[j] += 1
                spare -= 1
            }
            p = avail / (CGFloat(rowsPer.reduce(0, +)) + gaps)
            H = fixed
        } else {
            let available = o.maxHeight - o.padTop - o.padBottom
            func rebuild() { rowsPer = ks.map { max(1 + $0, Int((o.minGroupHeight / p).rounded(.up))) } }
            func total() -> CGFloat { CGFloat(rowsPer.reduce(0, +)) * p + gaps * p }
            rebuild()
            // Too tall: first shrink the scales a little, then merge the widest sessions' lanes (down to 5),
            // then shrink to the minimum, then merge further.
            while total() > available, p > regularPitch * 0.78 { p *= 0.97; rebuild() }
            while total() > available, let i = widest(above: 5) { ks[i] -= 1; rebuild() }
            while total() > available, p > o.minPitch { p = max(o.minPitch, p * 0.96); rebuild() }
            while total() > available, let i = widest(above: 1) { ks[i] -= 1; rebuild() }
            H = (total() + o.padTop + o.padBottom).rounded()
        }
        if previous == nil { shownPitch = p }
        let pitchBefore = pitch
        pitch = p
        height = H

        // Targets.
        struct Target { var key: String; var group: Int; var r: Int; var y: CGFloat }
        var targets: [Target] = []
        var spans: [(CGFloat, CGFloat)] = []
        var cursor = o.padTop
        for (gi, n) in rowsPer.enumerated() {
            let id = S == 0 ? "empty" : data[gi].session.id
            for r in 0..<n { targets.append(Target(key: "\(id)#\(r)", group: S == 0 ? -1 : gi, r: r, y: cursor + (CGFloat(r) + 0.5) * p)) }
            spans.append((cursor, cursor + CGFloat(n) * p))
            cursor += CGFloat(n) * p + o.gap * p
        }

        // Where did the change start? New sessions and bursts start at "now" (right); thinning comes from the left.
        let first = previous == nil
        var origin: (x: CGFloat, y: CGFloat, ring: CGFloat)?
        if let previous {
            for gi in 0..<S where origin == nil {
                let cy = (spans[gi].0 + spans[gi].1) / 2
                if let k = previous[data[gi].session.id] {
                    if ks[gi] > k { origin = (o.right, cy, 0.35) } else if ks[gi] < k { origin = (o.left, cy, 0) }
                } else {
                    origin = (o.right, cy, 1)
                }
            }
        } else {
            origin = (o.right, H / 2, 0.9)
        }
        let source = origin ?? (o.right, H / 2, 0)
        let wave = Wave(t0: first ? t + 0.15 : t, x: source.x, y: source.y)

        var seen = Set<String>()
        var changed = false
        for target in targets {
            seen.insert(target.key)
            let row: Row
            if let existing = rowByKey[target.key] {
                row = existing
                if abs(target.y - row.target) > 0.01 {
                    row.shifts.append(Shift(wave: Wave(t0: t, x: source.x, y: source.y), distance: target.y - row.target))
                    row.target = target.y
                    changed = true
                }
                if row.dying != nil { changed = true }
                row.dying = nil
            } else {
                row = Row(key: target.key, y: target.y, born: wave)
                rowByKey[target.key] = row
                rows.append(row)
                changed = true
            }
            row.group = target.group
            row.r = target.r
        }
        for row in rows where !seen.contains(row.key) && row.dying == nil {
            row.dying = t
            row.group = -1
            changed = true
        }
        if source.ring > 0, first || !targets.isEmpty {
            ripples.append(Ripple(wave: wave, strength: source.ring))
        }
        if changed || pitchBefore != p { generation += 1 }
        var kept: [String: Int] = [:]
        for gi in 0..<S { kept[data[gi].session.id] = ks[gi] }
        previous = kept

        groups = (0..<S).map { gi in
            GroupLayout(rows: rowsPer[gi], lanes: ks[gi],
                        rowList: (0..<rowsPer[gi]).compactMap { rowByKey["\(data[gi].session.id)#\($0)"] })
        }
    }

    /// Merges each row's agents into cells, and finds the spawn links.
    private func fillCells(_ data: ScaleData) {
        let N = Grid.columns, B = Grid.columnSeconds, ws = data.windowStart
        var rowOfTrack: [Int: Row] = [:]
        var laneAgents: [(Row, [Int])] = []
        for (gi, layout) in groups.enumerated() {
            let g = data.groups[gi]
            let k = layout.lanes
            for row in layout.rowList {
                let r = row.r
                var agents: [Int] = []
                if r == 0 {
                    agents = [g.main]
                } else if r < k {
                    agents = g.lanes[r - 1]
                } else if r == k {
                    for l in (r - 1)..<g.lanes.count { agents += g.lanes[l] }
                }
                for a in agents { rowOfTrack[a] = row }
                if r > 0 { laneAgents.append((row, agents)) }
                guard !agents.isEmpty else { row.cells = []; continue }

                var cells = [Cell](repeating: Cell(), count: N)
                var best = [Float](repeating: -1, count: N)
                var liveRank = [Int](repeating: 0, count: N)
                for a in agents {
                    let track = data.tracks[a]
                    var i = track.firstColumn
                    while i < N, ws + Double(i) * B < track.end {
                        let s = track.columns[i]
                        cells[i].present = true
                        cells[i].generating = max(cells[i].generating, s.generating)
                        cells[i].tool = max(cells[i].tool, s.tool)
                        cells[i].waiting = max(cells[i].waiting, s.waiting)
                        cells[i].output += s.output
                        let activity = s.generating + s.tool
                        if activity > best[i] {
                            best[i] = activity
                            cells[i].agent = a
                            cells[i].model = track.model
                        }
                        if i == N - 1, let live = track.live {
                            let rank: Int
                            switch live {
                            case .generating: rank = 4
                            case .tool: rank = 3
                            case .waiting: rank = 2
                            case .idle: rank = 1
                            }
                            if rank > liveRank[i] {
                                liveRank[i] = rank
                                cells[i].live = live
                                cells[i].liveAgent = a
                            }
                        }
                        i += 1
                    }
                }
                for i in 0..<N where cells[i].present {
                    let c = cells[i]
                    let activity = c.generating + c.tool + c.waiting
                    let state: ScaleState
                    if activity < 0.04 {
                        state = c.output < 1 ? .idle : .generating
                    } else if c.generating >= c.tool * 0.8 && c.generating > 0.02 {
                        state = .generating
                    } else {
                        state = c.tool >= c.waiting ? .tool : .waiting
                    }
                    let outN = min(1, log(1 + c.output) / log(1 + 9000))
                    cells[i].state = state
                    cells[i].heat = clamp(0.3 * outN + 0.9 * c.generating, 0, 1)
                    let shown = c.liveAgent >= 0 ? c.liveAgent : c.agent
                    cells[i].shimmers = shown >= 0 && data.tracks[shown].live == .generating
                }
                row.cells = cells
            }
        }
        for row in rows where row.group < 0 && row.dying == nil { row.cells = [] }

        links = []
        for (gi, layout) in groups.enumerated() {
            guard let main = layout.main else { continue }
            let g = data.groups[gi]
            for (row, agents) in laneAgents where row.group == gi {
                for a in agents {
                    let agent = data.tracks[a].agent
                    let parentTrack = agent.parentID == g.session.id ? g.main : data.tracks.firstIndex { $0.agent.id == agent.parentID }
                    let parent = parentTrack.flatMap { rowOfTrack[$0] } ?? main
                    let column = Int(((agent.start.timeIntervalSince1970 - ws) / B).rounded(.down))
                    guard parent !== row, column >= 0 else { continue }
                    links.append(Link(parent: parent, child: row, column: column))
                }
            }
        }
    }

    // MARK: Animation

    func advance(time t: Double) {
        let dt = lastAdvance.map { clamp(t - $0, 0, 0.1) } ?? 0
        lastAdvance = t
        shownPitch += (pitch - shownPitch) * CGFloat(min(1, dt * 7))
        if abs(shownPitch - pitch) < 0.01 { shownPitch = pitch }

        let maxDelay = Double(hypot(o.width, height) / Grid.rippleSpeed) + Grid.settleTime
        rows.removeAll { row in
            guard let dying = row.dying, t - dying > Grid.fadeOut else { return false }
            rowByKey[row.key] = nil
            return true
        }
        for row in rows {
            row.shifts.removeAll { shift in
                guard t - shift.wave.t0 > maxDelay else { return false }
                row.y0 += shift.distance
                return true
            }
            if let born = row.born, t - born.t0 > maxDelay { row.born = nil }
        }
        // A ripple is done once its ring has passed every corner of the comb.
        ripples.removeAll { ripple in
            let age = t - ripple.wave.t0
            let reach = hypot(max(ripple.wave.x, o.width - ripple.wave.x), max(ripple.wave.y, height - ripple.wave.y))
            return age > Grid.rippleLife || CGFloat(age) * Grid.rippleSpeed - 16 > reach
        }
    }

    func isAnimating(at t: Double) -> Bool {
        !ripples.isEmpty || shownPitch != pitch || rows.contains { !$0.shifts.isEmpty || $0.born != nil || $0.dying != nil }
    }

    @inline(__always) func rowY(_ row: Row, x: CGFloat, time t: Double) -> CGFloat {
        var y = row.y0
        for shift in row.shifts {
            let d = hypot(x - shift.wave.x, row.target - shift.wave.y)
            y += shift.distance * CGFloat(ease((t - shift.wave.t0 - Double(d / Grid.rippleSpeed)) / Grid.settleTime))
        }
        return y
    }

    @inline(__always) func bornAlpha(_ row: Row, x: CGFloat, time t: Double) -> CGFloat {
        guard let born = row.born else { return 1 }
        let d = hypot(x - born.x, row.target - born.y)
        return CGFloat(ease((t - born.t0 - Double(d / Grid.rippleSpeed)) / Grid.settleTime))
    }

    // MARK: Drawing

    private var halfWidth: CGFloat { o.columnWidth / 2 - o.cellGap }
    private var halfHeight: CGFloat { max(1.4, shownPitch * 2 / 3 - o.cellGap * 0.9) }

    /// Draws the scales, clipped to the comb.
    ///
    /// Scales that have settled (fully grown in, past every ripple and done moving) are drawn once into a
    /// bitmap that's kept until the data, the layout or the scroll position changes; each frame then draws
    /// that bitmap, the scales still animating, and the newest scales, which shimmer, breathe or grow in.
    /// Filling a scale costs about a microsecond, so this is what keeps a comb of 2,500 scales cheap.
    func draw(_ ctx: CGContext, time t: Double, lastX: CGFloat, partial: Double, palette: Palette, dark: Bool) {
        let N = Grid.columns, colW = o.columnWidth
        let hw = halfWidth, hv = halfHeight
        let L = o.left, R = o.right, fadeWidth = (R - L) * 0.42
        let grow = CGFloat(0.45 + 0.55 * clamp(partial * 1.6, 0, 1))
        let active = ripples.filter { t >= $0.wave.t0 }

        // While the pitch eases, every scale changes size each frame, so nothing is kept.
        let caching = shownPitch == pitch
        if caching {
            let key = CellKey(dark: dark, version: version, generation: generation, lastX: lastX, scale: Offscreen.scale(of: ctx))
            if key != cellKey {
                cellKey = key
                cellCache.begin(size: CGSize(width: o.width, height: height), like: ctx)
                for row in rows { row.cached.removeAll(keepingCapacity: true) }
                fullyCached = false
            }
        } else {
            cellKey = nil
            fullyCached = false
        }

        var fresh = Layers(), frame = Layers()
        var pending = false
        let columns = fullyCached ? Grid.staticColumns..<N : 0..<N
        for row in rows {
            var rowAlpha: CGFloat = 1
            if let dying = row.dying {
                rowAlpha = CGFloat(1 - (t - dying) / Grid.fadeOut)
                pending = true
                if rowAlpha <= 0 { continue }
            }
            if caching, row.cached.count != N { row.cached = [Bool](repeating: false, count: N) }
            let parity = row.r % 2 == 1 ? colW / 2 : 0
            let hasCells = !row.cells.isEmpty
            let still = row.shifts.isEmpty
            for i in columns {
                if caching, row.cached[i] { continue }
                let x = lastX - CGFloat(N - 1 - i) * colW - parity
                if x < L - hw || x > R + hw { continue }
                let y = still ? row.y0 : rowY(row, x: x, time: t)
                let a = rowAlpha * bornAlpha(row, x: x, time: t)
                if a <= 0.01 { pending = true; continue }
                // Ripple ring: a band of light running outward from where the layout changed.
                var boost: CGFloat = 0
                for ripple in active {
                    let age = CGFloat(t - ripple.wave.t0)
                    let d = abs(hypot(x - ripple.wave.x, y - ripple.wave.y) - age * Grid.rippleSpeed)
                    if d < 16 { boost = max(boost, ripple.strength * (1 - d / 16) * (1 - age / CGFloat(Grid.rippleLife))) }
                }
                let present = hasCells && row.cells[i].present
                // The newest column grows in, and the newest scales of a generating agent shimmer.
                let animated = present && (i == N - 1 || (i >= Grid.staticColumns && row.cells[i].state == .generating && row.cells[i].shimmers))
                if caching, !animated, a >= 1, boost == 0, isSettled(row, x: x, y: y, time: t) {
                    add(row, column: i, x: x, y: y, alpha: a, boost: 0, to: &fresh, time: t, grow: grow, fadeWidth: fadeWidth, palette: palette, dark: dark)
                    row.cached[i] = true
                } else {
                    if !animated { pending = true }
                    add(row, column: i, x: x, y: y, alpha: a, boost: boost, to: &frame, time: t, grow: grow, fadeWidth: fadeWidth, palette: palette, dark: dark)
                }
            }
        }
        if caching {
            if !fresh.isEmpty { cellCache.update { fresh.draw($0, clip: clipRect, hw: hw, hv: hv, palette: palette, dark: dark) } }
            if !pending { fullyCached = true }
            cellCache.draw(in: ctx)
        }
        frame.draw(ctx, clip: clipRect, hw: hw, hv: hv, palette: palette, dark: dark)
    }

    private var clipRect: CGRect { CGRect(x: o.left - 1, y: 0, width: o.right - o.left + 2, height: height) }

    /// Whether a scale at full size will stay as it is: every ripple has passed it and every move is done.
    private func isSettled(_ row: Row, x: CGFloat, y: CGFloat, time t: Double) -> Bool {
        for ripple in ripples where CGFloat(t - ripple.wave.t0) * Grid.rippleSpeed - 16 <= hypot(x - ripple.wave.x, y - ripple.wave.y) {
            return false
        }
        for shift in row.shifts {
            let d = hypot(x - shift.wave.x, row.target - shift.wave.y)
            if t - shift.wave.t0 - Double(d / Grid.rippleSpeed) < Grid.settleTime { return false }
        }
        return true
    }

    /// Adds one scale to `layers`: dim if empty or idle, lit while generating or in a tool call, outlined while waiting.
    @inline(__always) private func add(_ row: Row, column i: Int, x: CGFloat, y: CGFloat, alpha a: CGFloat, boost: CGFloat,
                                       to layers: inout Layers, time t: Double, grow: CGFloat, fadeWidth: CGFloat,
                                       palette: Palette, dark: Bool) {
        let N = Grid.columns
        let hw = halfWidth, hv = halfHeight
        layers.isEmpty = false
        var sc = 1 + 0.22 * boost
        if i == N - 1 { sc *= grow }
        guard !row.cells.isEmpty, row.cells[i].present else {
            if boost > 0.02 {
                layers.rippled.hex(Palette.accent, min(1, 0.1 + a * boost * (dark ? 0.55 : 0.45)), x, y, hw * sc, hv * sc)
            } else {
                Hex.add(to: layers.bg, x, y, hw * a, hv * a)
            }
            return
        }
        let c = row.cells[i]
        let isLive = i == N - 1 && c.live != nil
        let state = isLive ? c.live! : c.state
        if state == .idle {
            Hex.add(to: layers.dormant, x, y, hw * a, hv * a)
            return
        }
        let fade = 0.3 + 0.7 * CGFloat(ease(Double((x - o.left) / fadeWidth)))
        let itemAlpha = a * fade
        let base = palette.base(c.model)
        switch state {
        case .generating:
            // Shimmer: the newest scales of a generating agent cycle through iridescent tints.
            let recent = isLive ? 1 : (c.shimmers ? exp(-Double(N - 1 - i) / 1.6) : 0)
            let slot: Int, alpha: CGFloat
            if recent > 0.08 {
                var phase = (Double(x) * 0.018 + Double(y) * 0.045 - t * 0.55).truncatingRemainder(dividingBy: 1)
                if phase < 0 { phase += 1 }
                slot = base + 1 + min(31, Int(phase * 32))
                alpha = 0.55 + 0.45 * CGFloat(max(Double(c.heat), recent))
                if isLive { layers.glows.append((x, y, c.model, itemAlpha)) }
            } else {
                slot = base
                alpha = (dark ? 0.32 : 0.3) + (dark ? 0.6 : 0.58) * CGFloat(c.heat)
            }
            layers.lit.hex(slot, min(1, itemAlpha * alpha + boost * 0.3), x, y, hw * sc, hv * sc)
            if alpha > 0.6, hv > 2.2 { layers.gloss.sheen(itemAlpha * (dark ? 0.22 : 0.28), x, y, hw * sc, hv * sc) }
        case .tool:
            let breathe = isLive ? 0.5 + 0.5 * CGFloat(sin(t * 3.2 + Double(x) * 0.05)) : 0.5
            let alpha = (dark ? 0.24 : 0.2) + 0.12 * CGFloat(min(1, c.tool)) + (isLive ? 0.1 * breathe : 0)
            layers.lit.hex(base, min(1, itemAlpha * alpha + boost * 0.3), x, y, hw * sc, hv * sc)
            let ember = isLive ? 0.55 + 0.4 * breathe : 0.45
            layers.embers.dot(base + 33, itemAlpha * ember, x, y, max(0.8, min(hw, hv) * 0.42))
        case .waiting:
            let alpha = isLive ? 0.65 + 0.25 * CGFloat(sin(t * 2.4)) : 0.5
            layers.strokes.hex(base, itemAlpha * alpha, x, y, hw * sc - 0.5, hv * sc - 0.5)
        case .idle:
            break
        }
    }

    /// Spawn links: a hairline from the parent's row to the child's first scale.
    func drawLinks(_ ctx: CGContext, time t: Double, lastX: CGFloat, dark: Bool) {
        guard !links.isEmpty else { return }
        let N = Grid.columns, colW = o.columnWidth, L = o.left, R = o.right
        var lines = Batch(), dots = Batch()
        for link in links where link.child.dying == nil && link.parent.dying == nil {
            let x = lastX - CGFloat(N - 1 - link.column) * colW - colW / 4
            guard x >= L + 2, x <= R else { continue }
            let y1 = rowY(link.parent, x: x, time: t), y2 = rowY(link.child, x: x, time: t)
            let fade = 0.3 + 0.7 * CGFloat(ease(Double((x - L) / ((R - L) * 0.42))))
            let alpha = fade * o.linkAlpha * min(bornAlpha(link.child, x: x, time: t), bornAlpha(link.parent, x: x, time: t))
            lines.line(0, alpha, from: CGPoint(x: x, y: y1), to: CGPoint(x: x, y: y2))
            dots.dot(0, alpha, x, y2, 1.1)
        }
        let color = NSColor.labelColor.withAlphaComponent(dark ? 0.75 : 0.6).cgColor
        ctx.saveGState()
        ctx.clip(to: CGRect(x: L - 1, y: 0, width: R - L + 2, height: height))
        ctx.setLineWidth(1)
        ctx.setLineCap(.round)
        lines.stroke(ctx) { _ in color }
        dots.fill(ctx) { _ in color }
        ctx.restoreGState()
    }

    /// Box only: a status pip per session at the left edge, pulsing while the session is busy.
    func drawPips(_ ctx: CGContext, time t: Double, data: ScaleData, dark: Bool) {
        let r = max(1.3, min(2.2, shownPitch * 0.42))
        for (gi, group) in groups.enumerated() where gi < data.groups.count {
            guard let row = group.main, row.dying == nil else { continue }
            let session = data.groups[gi].session
            let y = rowY(row, x: 4, time: t), a = bornAlpha(row, x: o.right, time: t)
            if session.isBusy {
                ctx.setFillColor(NSColor.claude.withAlphaComponent(a * CGFloat(0.75 + 0.25 * sin(t * 3))).cgColor)
                ctx.fillEllipse(in: CGRect(x: 4.5 - r, y: y - r, width: 2 * r, height: 2 * r))
            } else if session.isOpen {
                ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.3 * a).cgColor)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: CGRect(x: 4.5 - r + 0.4, y: y - r + 0.4, width: 2 * r - 0.8, height: 2 * r - 0.8))
            }
        }
    }

    /// Panel only: "−30m", "−20m", "−10m" and "now" under the comb.
    func drawAxis(_ ctx: CGContext) {
        let y = height - 5
        let xNow = o.right - o.columnWidth / 2
        ctx.setFillColor(NSColor.tertiaryLabelColor.cgColor)
        for m in [0, 10, 20, 30] {
            let line = Text.line(m == 0 ? "now" : "−\(m)m", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
            let w = Text.width(line)
            var x = xNow - o.columnWidth * CGFloat(m * 60) / CGFloat(Grid.columnSeconds)
            let textX: CGFloat
            switch m {
            case 0: x = o.right; textX = x - w
            case 30: x = max(x, o.left); textX = x
            default: textX = x - w / 2
            }
            Text.draw(line, in: ctx, x: textX, baseline: y)
            ctx.fill(CGRect(x: (m == 0 ? o.right - 0.5 : x).rounded() - 0.25, y: y - 13, width: 0.5, height: 3))
        }
    }

    /// The agent whose scale is under `point`, as a track index.
    func hitTest(_ point: CGPoint, time t: Double, lastX: CGFloat) -> Int? {
        guard point.x >= o.left - 4, point.x <= o.right + 4, point.y >= 0, point.y <= height else { return nil }
        let N = Grid.columns, colW = o.columnWidth, hw = halfWidth, hv = halfHeight
        var best: Int?, bestDistance: CGFloat = 1.25
        for row in rows where row.dying == nil && !row.cells.isEmpty {
            let parity = row.r % 2 == 1 ? colW / 2 : 0
            let i = N - 1 - Int(((lastX - parity - point.x) / colW).rounded())
            guard i >= 0, i < N, row.cells[i].present else { continue }
            let x = lastX - CGFloat(N - 1 - i) * colW - parity, y = rowY(row, x: x, time: t)
            let d = hypot((point.x - x) / hw, (point.y - y) / hv)
            if d < bestDistance {
                bestDistance = d
                let c = row.cells[i]
                best = c.liveAgent >= 0 ? c.liveAgent : c.agent
            }
        }
        return best
    }

    /// Outlines every scale of the hovered agent.
    func drawOutline(_ ctx: CGContext, agent: Int, time t: Double, lastX: CGFloat) {
        let N = Grid.columns, colW = o.columnWidth, hw = halfWidth, hv = halfHeight
        let path = CGMutablePath()
        for row in rows where row.dying == nil && !row.cells.isEmpty {
            let parity = row.r % 2 == 1 ? colW / 2 : 0
            for i in 0..<N where row.cells[i].present && (row.cells[i].agent == agent || row.cells[i].liveAgent == agent) {
                let x = lastX - CGFloat(N - 1 - i) * colW - parity
                guard x >= o.left - hw, x <= o.right + hw else { continue }
                Hex.add(to: path, x, rowY(row, x: x, time: t), hw + 0.3, hv + 0.3)
            }
        }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: o.left - 2, y: 0, width: o.right - o.left + 4, height: height))
        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineWidth(1.2)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
