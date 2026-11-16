import AppKit

/// The "Activity Stream" activity design: a river of Claude Code sessions.
///
/// Each session is a glowing stream as wide as its main thread's output rate, flowing from now (on the
/// right) into the past. Subagents branch off as filaments in their model's color and rejoin when they
/// finish, so a workflow opens into a delta. Particles drift along busy stretches, and a glowing source at
/// the right edge marks each thread producing tokens now. A strip of squares under the river keeps one row
/// per session. The box shows the last 10 minutes; the panel shows 30, with stat tiles, labels and a table.
///
/// Everything that only changes with the snapshot (about once a second) is drawn into cached bitmaps: the
/// streams and squares in one, which each frame shifts left by as much as time has moved on since, and the
/// text and tiles in another. Only the particles, sources and workflow tags are drawn every frame.
final class ActivityStreamDesign: ActivityDesign {
    let boxHeight: CGFloat = 95

    /// The header row above the box's river.
    private static let boxHeader: CGFloat = 21
    private static let panelWidth: CGFloat = 500

    private let slots = SlotBook()
    private let budget = FrameBudget()
    private lazy var boxRiver = River(config: .box, slots: slots, budget: budget)
    private lazy var panelRiver = River(config: .panel, slots: slots, budget: budget)

    private let boxChrome = Offscreen()
    private var boxChromeKey = ""
    private let panelChrome = Offscreen()
    private var panelChromeKey = ""
    private var layoutCache: (time: Date, layout: PanelLayout)?

    /// The session (and stream) under the mouse in the panel, which the river and the table highlight.
    private var focusSession: String?
    private var focusStream: String?
    private var tooltip: (key: String, time: Date, lines: [NSAttributedString])?

    func tick(dt: Double, now: Date, snapshot: ActivitySnapshot) {
        budget.reset()
    }

    func reset() {
        focusSession = nil
        focusStream = nil
        tooltip = nil
        boxRiver.reset()
        panelRiver.reset()
    }

    // MARK: Box

    func drawBox(size: CGSize, context ctx: CGContext, now: Date, snapshot: ActivitySnapshot, mouse: CGPoint?) {
        let dark = Palette.isDark
        let header = Self.boxStat(snapshot)
        let empty = River.visibleSessions(snapshot, window: River.Config.box.window).isEmpty
        let key = "\(header.string)|\(dark)|\(mouse != nil)|\(empty)|\(size.width)x\(size.height)|\(Offscreen.scale(of: ctx))"
        if key != boxChromeKey, let c = boxChrome.begin(size: size, like: ctx) {
            boxChromeKey = key
            Offscreen.withAppKit(c) {
                // The box lights up while the mouse is over it, like a highlighted menu item, since it opens the panel.
                if mouse != nil {
                    NSColor.labelColor.withAlphaComponent(0.05).setFill()
                    NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 8, yRadius: 8).fill()
                }
                Text.draw(Text.make("Activity", .systemFont(ofSize: 12, weight: .bold), .labelColor), x: 9, midY: 13)
                let width = header.size().width
                let right = size.width - 9
                Text.draw(header, x: right - width, midY: 13.5)
                let live = snapshot.agentsRunning > 0 || snapshot.busySessions > 0
                (live ? NSColor.claude : NSColor.tertiaryLabelColor).setFill()
                NSBezierPath(ovalIn: CGRect(x: right - width - 10, y: 10.5, width: 6, height: 6)).fill()
                if empty {
                    let text = Text.make("No sessions", .systemFont(ofSize: 11), .tertiaryLabelColor)
                    Text.draw(text, x: (size.width - text.size().width) / 2, midY: Self.boxHeader + 33)
                }
            }
            boxChrome.finish()
        }
        boxChrome.draw(in: ctx, at: .zero)
        guard !empty else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: Self.boxHeader)
        boxRiver.draw(in: ctx, now: now, snapshot: snapshot, height: size.height - Self.boxHeader,
                      focus: nil, focusStream: nil, dark: dark)
        ctx.restoreGState()
    }

    /// "● 4 running · 27 in 30m · 6.9k tok/m", with the numbers in the label color.
    private static func boxStat(_ snapshot: ActivitySnapshot) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        s.append(Text.make("\(snapshot.agentsRunning)", bold, .labelColor))
        s.append(Text.make(" running · ", font, .secondaryLabelColor))
        s.append(Text.make("\(snapshot.agentsRecent)", bold, .labelColor))
        s.append(Text.make(" in 30m · \(ActivityFormat.tokens(snapshot.outputPerMinute)) tok/m", font, .secondaryLabelColor))
        return s
    }

    // MARK: Panel

    func panelSize(for snapshot: ActivitySnapshot) -> CGSize { layout(for: snapshot).size }

    private func layout(for snapshot: ActivitySnapshot) -> PanelLayout {
        if let cache = layoutCache, cache.time == snapshot.time { return cache.layout }
        let layout = PanelLayout(snapshot: snapshot, width: Self.panelWidth)
        layoutCache = (snapshot.time, layout)
        return layout
    }

    func drawPanel(size: CGSize, context ctx: CGContext, now: Date, snapshot: ActivitySnapshot, mouse: CGPoint?) {
        let dark = Palette.isDark
        let layout = layout(for: snapshot)
        let tile = layout.riverTile
        let river = panelRiver
        river.prepare(snapshot: snapshot, height: tile.height)

        // Hover: a stream in the river, or a row of the table.
        var focus: String?, stream: String?
        var tipAt: CGPoint?
        if let mouse {
            let local = CGPoint(x: mouse.x - tile.minX, y: mouse.y - tile.minY)
            if tile.contains(mouse), local.x <= river.config.xNow + 4,
               let hit = river.hit(local, now: now) {
                focus = hit.sessionID
                stream = hit.key
                tipAt = mouse
            } else if let row = layout.rows.first(where: { $0.sessionID != nil && mouse.y >= $0.y && mouse.y < $0.y + $0.height
                                                          && mouse.x >= 10 && mouse.x <= size.width - 10 }) {
                focus = row.sessionID
            }
        }
        focusSession = focus
        focusStream = stream

        let key = "\(snapshot.time.timeIntervalSinceReferenceDate)|\(dark)|\(focus ?? "")|\(size.width)x\(size.height)|\(Offscreen.scale(of: ctx))"
        if key != panelChromeKey, panelChrome.image == nil || panelChrome.size != size || budget.take(),
           let c = panelChrome.begin(size: size, like: ctx) {
            panelChromeKey = key
            Offscreen.withAppKit(c) {
                drawChrome(c, size: size, layout: layout, snapshot: snapshot, dark: dark)
            }
            panelChrome.finish()
        }
        // The chrome covers the whole panel, so it replaces the cleared bitmap rather than blending into it.
        panelChrome.draw(in: ctx, at: .zero, blend: .copy)

        if layout.empty { return }
        ctx.saveGState()
        ctx.translateBy(x: tile.minX, y: tile.minY)
        ctx.clip(to: CGRect(origin: .zero, size: tile.size))
        river.draw(in: ctx, now: now, snapshot: snapshot, height: tile.height, focus: focus, focusStream: stream, dark: dark)
        ctx.restoreGState()

        if let stream, let tipAt { drawTooltip(ctx, key: stream, at: tipAt, snapshot: snapshot, bounds: tile) }
    }

    /// The panel's text, tiles and table: everything that only changes with the snapshot or the hover.
    private func drawChrome(_ c: CGContext, size: CGSize, layout: PanelLayout, snapshot: ActivitySnapshot, dark: Bool) {
        let inner = CGRect(x: 10, y: 0, width: size.width - 20, height: size.height)
        Text.draw(Text.make("Claude Code Activity", .systemFont(ofSize: 13, weight: .bold), .labelColor), x: inner.minX + 2, midY: 15)
        let range = Text.make("last 30 min", .systemFont(ofSize: 11), .secondaryLabelColor)
        Text.draw(range, x: inner.maxX - 2 - range.size().width, midY: 15.5)

        // Stat tiles.
        let cache = snapshot.inputTotal > 0 ? "\(Int((snapshot.cacheHitRate * 100).rounded()))%" : "—"
        let stats: [(String, String?, String)] = [
            ("\(snapshot.agentsRunning)", nil, "running now"),
            ("\(snapshot.agentsRecent)", nil, "agents, 30m"),
            ("\(snapshot.peakParallel)", nil, "peak"),
            (ActivityFormat.tokens(snapshot.outputPerMinute), "/m", "output"),
            (ActivityFormat.tokens(snapshot.inputPerMinute), "/m", "input"),
            (cache, nil, "cache hits"),
        ]
        let gap: CGFloat = 4
        let tileWidth = (inner.width - gap * 5) / 6
        for (i, stat) in stats.enumerated() {
            let rect = CGRect(x: inner.minX + CGFloat(i) * (tileWidth + gap), y: layout.kpiY, width: tileWidth, height: PanelLayout.kpiHeight)
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            let value = NSMutableAttributedString(attributedString:
                Text.make(stat.0, .monospacedDigitSystemFont(ofSize: 14, weight: .semibold), .labelColor))
            if let unit = stat.1 { value.append(Text.make(unit, .systemFont(ofSize: 10, weight: .medium), .secondaryLabelColor)) }
            Text.draw(value, x: rect.minX + 7, midY: rect.minY + 12.5, maxWidth: rect.width - 9)
            Text.draw(Text.make(stat.2, .systemFont(ofSize: 10), .secondaryLabelColor), x: rect.minX + 7, midY: rect.minY + 27,
                      maxWidth: rect.width - 9)
        }

        // The river's tile, grid, labels and axis (the streams themselves are drawn over it every frame).
        let tile = layout.riverTile
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8).fill()
        if layout.empty {
            let text = Text.make("No sessions", .systemFont(ofSize: 11), .tertiaryLabelColor)
            Text.draw(text, x: tile.midX - text.size().width / 2, midY: tile.midY)
            return
        }
        c.saveGState()
        c.translateBy(x: tile.minX, y: tile.minY)
        drawRiverOverlay(c, snapshot: snapshot, dark: dark)
        c.restoreGState()

        drawLegend(layout: layout, snapshot: snapshot, inner: inner)
        drawTable(c, layout: layout, inner: inner)
    }

    /// Session labels in the gutter at each stream's position now, the time grid and axis.
    private func drawRiverOverlay(_ c: CGContext, snapshot: ActivitySnapshot, dark: Bool) {
        guard let geo = panelRiver.geometry else { return }
        let cfg = panelRiver.config
        let pps = panelRiver.pps
        let x = { (ago: Double) -> CGFloat in cfg.xNow - CGFloat(ago) * pps }

        // Faint grid every 10 minutes.
        NSColor.labelColor.withAlphaComponent(dark ? 0.06 : 0.07).setFill()
        for m in stride(from: 600.0, to: cfg.window, by: 600) {
            NSBezierPath(rect: CGRect(x: x(m).rounded() - 0.25, y: geo.riverTop - 2, width: 0.5, height: geo.riverH + 4)).fill()
        }

        // Labels, pushed apart so they don't overlap, with a leader to their stream.
        struct Label { var y: CGFloat; let want: CGFloat; let lane: Lane }
        let last = geo.colT.count - 1
        var labels = geo.lanes.filter(\.live).map { Label(y: $0.center[last], want: $0.center[last], lane: $0) }
        labels.sort { $0.want < $1.want }
        let two = CGFloat(labels.count) * 24 <= geo.riverH
        let h: CGFloat = two ? 24 : 12
        for i in labels.indices.dropFirst() { labels[i].y = max(labels[i].y, labels[i - 1].y + h) }
        let bottom = geo.riverTop + geo.riverH - 2
        if let lastLabel = labels.last, lastLabel.y + h / 2 > bottom {
            labels[labels.count - 1].y = bottom - h / 2
            for i in labels.indices.dropLast().reversed() { labels[i].y = min(labels[i].y, labels[i + 1].y - h) }
        }
        let lx = cfg.xNow + 12
        let maxWidth = panelRiver.width - lx - 4
        for label in labels {
            let dimmed = focusSession != nil && focusSession != label.lane.sessionID
            let leader = NSBezierPath()
            leader.move(to: CGPoint(x: cfg.xNow + 4, y: label.want))
            leader.curve(to: CGPoint(x: lx - 3, y: label.y), controlPoint1: CGPoint(x: cfg.xNow + 8, y: label.want),
                         controlPoint2: CGPoint(x: cfg.xNow + 6, y: label.y))
            leader.lineWidth = 0.75
            NSColor.labelColor.withAlphaComponent(dimmed ? 0.06 : 0.16).setStroke()
            leader.stroke()
            Text.draw(Text.make(label.lane.name, .systemFont(ofSize: 10.5, weight: .semibold), dimmed ? .tertiaryLabelColor : .labelColor),
                      x: lx, midY: label.y - (two ? 5.5 : 0), maxWidth: maxWidth)
            if two {
                Text.draw(Text.make(label.lane.status, .systemFont(ofSize: 10), dimmed ? .tertiaryLabelColor : .secondaryLabelColor),
                          x: lx, midY: label.y + 7, maxWidth: maxWidth)
            }
        }

        // Time axis under the strip.
        let font = NSFont.systemFont(ofSize: 9.5)
        let axisY = panelRiver.height - 8
        for m in [20, 10] {
            let text = Text.make("−\(m)m", font, .tertiaryLabelColor)
            Text.draw(text, x: x(Double(m) * 60) - text.size().width / 2, midY: axisY)
        }
        Text.draw(Text.make("−30m", font, .tertiaryLabelColor), x: cfg.stripLeft, midY: axisY)
        let nowText = Text.make("now", font, .tertiaryLabelColor)
        Text.draw(nowText, x: cfg.xNow - nowText.size().width, midY: axisY)
        if geo.stripH > 0 {
            Text.draw(Text.make("sessions × 30 s", font, .tertiaryLabelColor), x: lx, midY: geo.stripTop + min(geo.stripH, 20) / 2,
                      maxWidth: maxWidth)
        }
    }

    /// Model dots with the number of threads running on each.
    private func drawLegend(layout: PanelLayout, snapshot: ActivitySnapshot, inner: CGRect) {
        let y = layout.legendY + 7
        var x = inner.minX + 2
        let font = NSFont.systemFont(ofSize: 10.5)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        let right = Text.make("running threads", font, .secondaryLabelColor)
        let rightX = inner.maxX - 2 - right.size().width
        Text.draw(right, x: rightX, midY: y)
        for model in layout.models {
            let item = NSMutableAttributedString(attributedString: Text.make(ClaudeModel.name(model) + " ", font, .secondaryLabelColor))
            item.append(Text.make("\(snapshot.runningByModel[model] ?? 0)", bold, .labelColor))
            let width = item.size().width
            if x + 11 + width > rightX - 8 { break }
            ClaudeModel.color(model).setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: y - 3.5, width: 7, height: 7)).fill()
            Text.draw(item, x: x + 11, midY: y)
            x += 11 + width + 12
        }
    }

    private func drawTable(_ c: CGContext, layout: PanelLayout, inner: CGRect) {
        let columns = PanelLayout.columns(in: inner)
        let headerFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let titles = ["Session", "Model", "Agents", "In", "Out", "Cache", "Out/min"]
        let headY = layout.tableY + 9
        for (i, title) in titles.enumerated() {
            let text = Text.make(title, headerFont, .secondaryLabelColor)
            let col = columns[i]
            Text.draw(text, x: i == 0 ? col.minX + 4 : col.maxX - 4 - text.size().width, midY: headY)
        }
        func separator(_ y: CGFloat) {
            NSColor.separatorColor.setFill()
            NSBezierPath(rect: CGRect(x: inner.minX, y: y - 0.25, width: inner.width, height: 0.5)).fill()
        }
        separator(layout.tableY + 17.5)

        let regular = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let semibold = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        for (index, row) in layout.rows.enumerated() {
            let rect = CGRect(x: inner.minX, y: row.y, width: inner.width, height: row.height)
            if let sid = row.sessionID, sid == focusSession {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
            if (row.kind == .session && index > 0) || row.kind == .total { separator(row.y) }
            let midY = rect.midY
            let base: NSColor = row.ended ? .tertiaryLabelColor : (row.kind == .workflow ? .secondaryLabelColor : .labelColor)
            let muted: NSColor = .tertiaryLabelColor
            let font = row.kind == .total ? semibold : regular

            // First column: a dot for sessions, an indent for workflows.
            let first = columns[0]
            switch row.kind {
            case .session:
                let dot = CGRect(x: first.minX + 4, y: midY - 3.5, width: 7, height: 7)
                let color = ClaudeModel.color(row.model)
                if row.busy {
                    color.withAlphaComponent(0.25).setFill()
                    NSBezierPath(ovalIn: dot.insetBy(dx: -2.5, dy: -2.5)).fill()
                }
                color.withAlphaComponent(row.ended ? 0.5 : 1).setFill()
                NSBezierPath(ovalIn: dot).fill()
                Text.draw(Text.make(row.name, .systemFont(ofSize: 11, weight: .semibold), base), x: first.minX + 16, midY: midY,
                          maxWidth: first.width - 18)
            case .workflow:
                Text.draw(Text.make("↳ " + row.name, .systemFont(ofSize: 11), base), x: first.minX + 15, midY: midY,
                          maxWidth: first.width - 17)
            case .total:
                Text.draw(Text.make(row.name, .systemFont(ofSize: 11, weight: .semibold), base), x: first.minX + 4, midY: midY)
            case .more:
                Text.draw(Text.make(row.name, .systemFont(ofSize: 11), muted), x: first.minX + 16, midY: midY)
                continue
            }

            func right(_ text: NSAttributedString, _ column: Int) {
                Text.draw(text, x: columns[column].maxX - 4 - text.size().width, midY: midY)
            }
            right(Text.make(row.modelText, font, base), 1)
            if let total = row.agentsTotal, total > 0 {
                let agents = NSMutableAttributedString()
                let run = row.agentsRunning
                agents.append(Text.make("\(run)", run > 0 ? semibold : font, run > 0 && !row.ended ? base : muted))
                agents.append(Text.make("/\(total)", font, muted))
                right(agents, 2)
            } else {
                right(Text.make("—", font, muted), 2)
            }
            right(Text.make(row.input, font, base), 3)
            right(Text.make(row.output, font, base), 4)
            right(Text.make(row.cache, font, base), 5)
            right(Text.make(row.rate, font, row.rateMuted ? muted : base), 6)
        }
    }

    /// A small box near the mouse describing the stream under it.
    private func drawTooltip(_ ctx: CGContext, key: String, at point: CGPoint, snapshot: ActivitySnapshot, bounds: CGRect) {
        if tooltip?.key != key || tooltip?.time != snapshot.time {
            tooltip = (key, snapshot.time, Self.tooltipLines(key: key, snapshot: snapshot, overflow: panelRiver.overflow))
        }
        guard let lines = tooltip?.lines, !lines.isEmpty else { return }
        let width = (lines.map { $0.size().width }.max() ?? 0) + 14
        let height = CGFloat(lines.count) * 14 + 9
        var x = point.x + 10
        if x + width > bounds.maxX - 4 { x = max(bounds.minX + 4, point.x - width - 10) }
        let y = min(max(point.y + 12, bounds.minY + 4), bounds.maxY - height - 4)
        let rect = CGRect(x: x, y: y, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        shape.fill()
        NSColor.labelColor.withAlphaComponent(0.15).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        for (i, line) in lines.enumerated() {
            Text.draw(line, x: rect.minX + 7, midY: rect.minY + 11.5 + CGFloat(i) * 14)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func tooltipLines(key: String, snapshot: ActivitySnapshot, overflow: Set<String>) -> [NSAttributedString] {
        let bold = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        func title(_ name: String, _ detail: String) -> NSAttributedString {
            let s = NSMutableAttributedString(attributedString: Text.make(name, bold, .labelColor))
            s.append(Text.make("  " + detail, font, .secondaryLabelColor))
            return s
        }
        func line(_ text: String) -> NSAttributedString { Text.make(text, font, .secondaryLabelColor) }

        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [] }
        switch parts[0] {
        case "m":
            guard let s = snapshot.session(parts[1]) else { return [] }
            let status = s.isBusy ? "busy" : s.isOpen ? "idle" : "ended"
            let rate = ActivityFormat.tokens(s.threads.reduce(0) { $0 + River.lastMinute($1.buckets) })
            return [title(s.name, ClaudeModel.name(s.model)),
                    line("\(status) · \(rate) out/min · ctx \(ActivityFormat.tokens(Double(s.main.contextTokens)))")]
        case "b":
            guard let s = snapshot.session(parts[1]) else { return [] }
            let others = s.agents.filter { overflow.contains($0.id) }
            let running = others.filter(\.isRunning).count
            let out = others.reduce(0) { $0 + $1.outputTokens }
            return [title("+\(others.count) agents", others.first.map { ClaudeModel.name($0.model) } ?? ""),
                    line(s.name),
                    line("\(running) running · \(ActivityFormat.tokens(Double(out))) out")]
        default:
            guard let s = snapshot.sessions.first(where: { $0.agents.contains { $0.id == parts[1] } }),
                  let a = s.agents.first(where: { $0.id == parts[1] }) else { return [] }
            var context = s.name
            if let wid = a.workflowID, let wf = s.workflows.first(where: { $0.id == wid }) { context += " › " + wf.name }
            if a.depth > 1 { context += " · depth \(a.depth)" }
            let state: String
            if let end = a.end {
                state = "done in " + ActivityFormat.duration(end.timeIntervalSince(a.start))
            } else {
                state = a.state == .waiting ? "waiting" : a.state == .idle ? "idle" : "running"
            }
            let input = Double(a.inputTokens + a.cacheReadTokens + a.cacheWriteTokens)
            return [title(a.label, ClaudeModel.name(a.model)), line(context),
                    line("\(state) · \(ActivityFormat.tokens(Double(a.outputTokens))) out · \(ActivityFormat.tokens(input)) in")]
        }
    }
}

// MARK: - Panel layout

/// Where things go in the panel, and the table's rows. Built once per snapshot; the panel's size only
/// changes when sessions or workflows come or go.
private struct PanelLayout {
    static let kpiHeight: CGFloat = 38
    static let riverHeight: CGFloat = 150

    struct Row {
        enum Kind { case session, workflow, total, more }
        var kind: Kind
        var sessionID: String?
        var y: CGFloat = 0
        var height: CGFloat = 17
        var name = ""
        var model = ""
        var modelText = ""
        var ended = false
        var busy = false
        var agentsRunning = 0
        var agentsTotal: Int?
        var input = ""
        var output = ""
        var cache = ""
        var rate = ""
        var rateMuted = false
    }

    var size: CGSize
    var kpiY: CGFloat = 29
    var riverTile: CGRect
    var legendY: CGFloat = 0
    var tableY: CGFloat = 0
    var rows: [Row] = []
    var models: [String] = []
    var empty: Bool

    static func columns(in inner: CGRect) -> [CGRect] {
        let fractions: [CGFloat] = [0.30, 0.12, 0.11, 0.11, 0.11, 0.10, 0.15]
        var x = inner.minX
        return fractions.map { f in
            defer { x += inner.width * f }
            return CGRect(x: x, y: 0, width: inner.width * f, height: 0)
        }
    }

    init(snapshot: ActivitySnapshot, width: CGFloat) {
        let visible = River.visibleSessions(snapshot, window: River.Config.panel.window)
        empty = visible.isEmpty
        let riverY = kpiY + Self.kpiHeight + 8
        let tileHeight = empty ? 64 : River.Config.panel.height(rows: visible.count)
        riverTile = CGRect(x: 10, y: riverY, width: width - 20, height: tileHeight)
        guard !empty else {
            size = CGSize(width: width, height: (riverTile.maxY + 10).rounded())
            return
        }
        legendY = riverTile.maxY + 5
        tableY = legendY + 18

        // Models in use, in a fixed order by family so the legend doesn't reshuffle.
        var seen = Set<String>(snapshot.runningByModel.keys)
        for s in snapshot.sessions { for t in s.threads { seen.insert(t.model) } }
        seen.remove("")
        models = seen.sorted { a, b in
            let ra = River.familyRank(a), rb = River.familyRank(b)
            return ra != rb ? ra < rb : a > b
        }

        // Table rows: sessions (open first, as the snapshot orders them), each with its workflows.
        var rows: [Row] = []
        var total = Row(kind: .total, name: "All sessions")
        var totalRunning = 0, totalAgents = 0
        var inSum = 0.0, outSum = 0.0, cacheSum = 0.0, rateSum = 0.0
        let maxRows = 14
        var hidden = 0
        for s in snapshot.sessions {
            let threads = s.threads
            let input = threads.reduce(0.0) { $0 + Double($1.inputTokens + $1.cacheReadTokens + $1.cacheWriteTokens) }
            let cacheRead = threads.reduce(0.0) { $0 + Double($1.cacheReadTokens) }
            let output = threads.reduce(0.0) { $0 + Double($1.outputTokens) }
            let rate = threads.reduce(0.0) { $0 + River.lastMinute($1.buckets) }
            totalRunning += s.runningAgents; totalAgents += s.agents.count
            inSum += input; outSum += output; cacheSum += cacheRead; rateSum += s.isOpen ? rate : 0
            guard rows.count < maxRows else { hidden += 1; continue }
            var row = Row(kind: .session, sessionID: s.id)
            row.name = s.name
            row.model = s.model
            row.modelText = ClaudeModel.family(s.model)
            row.ended = !s.isOpen
            row.busy = s.isBusy
            row.agentsRunning = s.runningAgents
            row.agentsTotal = s.agents.count
            row.input = ActivityFormat.tokens(input)
            row.output = ActivityFormat.tokens(output)
            row.cache = Self.percent(cacheRead, input)
            if !s.isOpen { row.rate = "ended"; row.rateMuted = true }
            else if rate >= 1 { row.rate = ActivityFormat.tokens(rate) }
            else { row.rate = "idle"; row.rateMuted = true }
            rows.append(row)

            let workflows = s.workflows.sorted { $0.isRunning && !$1.isRunning }.prefix(3)
            for wf in workflows where rows.count < maxRows {
                let agents = s.agents.filter { $0.workflowID == wf.id }
                let wIn = agents.reduce(0.0) { $0 + Double($1.inputTokens + $1.cacheReadTokens + $1.cacheWriteTokens) }
                let wCache = agents.reduce(0.0) { $0 + Double($1.cacheReadTokens) }
                let families = Set(agents.map { ClaudeModel.family($0.model) })
                var w = Row(kind: .workflow, sessionID: s.id)
                w.name = wf.name
                w.modelText = families.count > 1 ? "mixed" : families.first ?? ""
                w.ended = !s.isOpen
                w.agentsRunning = wf.runningCount
                w.agentsTotal = wf.agentCount
                w.input = ActivityFormat.tokens(wIn)
                w.output = ActivityFormat.tokens(agents.reduce(0.0) { $0 + Double($1.outputTokens) })
                w.cache = Self.percent(wCache, wIn)
                w.rate = wf.isRunning ? ActivityFormat.tokens(agents.reduce(0.0) { $0 + River.lastMinute($1.buckets) }) : "done"
                w.rateMuted = !wf.isRunning
                rows.append(w)
            }
        }
        if hidden > 0 { rows.append(Row(kind: .more, name: "\(hidden) more")) }
        total.agentsRunning = totalRunning
        total.agentsTotal = totalAgents
        total.input = ActivityFormat.tokens(inSum)
        total.output = ActivityFormat.tokens(outSum)
        total.cache = Self.percent(cacheSum, inSum)
        total.rate = ActivityFormat.tokens(rateSum)
        rows.append(total)

        var y = tableY + 18
        for i in rows.indices {
            rows[i].y = y
            rows[i].height = rows[i].kind == .total ? 19 : 17
            y += rows[i].height
        }
        self.rows = rows
        size = CGSize(width: width, height: (y + 7).rounded())
    }

    static func percent(_ part: Double, _ whole: Double) -> String {
        whole > 0 ? "\(Int((100 * part / whole).rounded()))%" : "—"
    }
}

// MARK: - River

/// Which side of the main stream each subagent branches to, shared by the box and the panel so a branch
/// sits on the same side in both. Each agent keeps the lowest slot not held by an agent that overlaps its
/// start, assigned once, so branches don't swap sides as others come and go.
private final class SlotBook {
    private var slots: [String: Int] = [:]

    func slot(_ id: String) -> Int { slots[id] ?? 0 }

    func assign(_ agents: [AgentActivity]) {
        let sorted = agents.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        for a in sorted where slots[a.id] == nil {
            var used = Set<Int>()
            for b in sorted where b.id != a.id {
                guard let s = slots[b.id] else { continue }
                if b.start <= a.start && (b.end.map { $0 > a.start } ?? true) { used.insert(s) }
            }
            var j = 0
            while used.contains(j) { j += 1 }
            slots[a.id] = j
        }
    }

    /// Forgets agents that are no longer in the snapshot.
    func prune(keeping ids: Set<String>) {
        if slots.count > ids.count + 64 { slots = slots.filter { ids.contains($0.key) } }
    }
}

/// Slot j → signed rank: 0 → −1 (above), 1 → +1 (below), 2 → −2, …
private func slotRank(_ j: Int) -> CGFloat { CGFloat(j % 2 == 0 ? -1 : 1) * CGFloat(j / 2 + 1) }

private func smoothstep(_ x: Double) -> Double {
    let x = min(1, max(0, x))
    return x * x * (3 - 2 * x)
}

/// A dash drifting along a stream: its x, its place across the stream (−1…1), speed factor and twinkle phase.
private struct Particle {
    var x: CGFloat
    var u: CGFloat
    var v: CGFloat
    var phase: CGFloat
}

/// A stream's outline: center, half width and glow (how busy it is, 0–1) at a list of times, in seconds
/// relative to the snapshot time.
private struct Stream {
    enum Kind { case main, agent, band }
    var key: String
    var sessionID: String
    var kind: Kind
    var color: Int
    var depth: Int
    var live: Bool
    var active: Bool
    var t: [Double] = []
    var y: [CGFloat] = []
    var h: [CGFloat] = []
    var g: [CGFloat] = []

    func sample(_ time: Double) -> (y: CGFloat, h: CGFloat, g: CGFloat) {
        let n = t.count
        if time <= t[0] { return (y[0], h[0], g[0]) }
        if time >= t[n - 1] { return (y[n - 1], h[n - 1], g[n - 1]) }
        var lo = 0, hi = n - 1
        while hi - lo > 1 {
            let m = (lo + hi) >> 1
            if t[m] <= time { lo = m } else { hi = m }
        }
        let span = t[hi] - t[lo]
        let k = CGFloat(span > 0 ? (time - t[lo]) / span : 0)
        return (y[lo] + (y[hi] - y[lo]) * k, h[lo] + (h[hi] - h[lo]) * k, g[lo] + (g[hi] - g[lo]) * k)
    }
}

/// A session's lane: where its stream runs, per column.
private struct Lane {
    var sessionID: String
    var name: String
    var status: String
    var live: Bool
    var center: [CGFloat]
    var half: [CGFloat]
}

/// One square of the strip.
private struct Cell {
    var row: Int
    var b0: Double
    var b1: Double
    var value: CGFloat
    var agents: Bool
    var color: Int
    var sessionID: String
}

/// Where a workflow's delta opens, for its tag in the panel.
private struct WorkflowTag {
    var lane: Int
    var start: Double
    var label: String
    var sessionID: String
}

/// The river's layout in time coordinates, rebuilt once per snapshot.
private struct Geometry {
    var time: Date
    /// Column times: evenly spaced centers, then the snapshot time itself.
    var colT: [Double]
    var t0: Double
    var step: Double
    var lanes: [Lane]
    var streams: [Stream]
    var models: [String]
    var pitch: CGFloat
    var stripH: CGFloat
    var stripTop: CGFloat
    var riverTop: CGFloat
    var riverH: CGFloat
    var cells: [Cell]
    var tags: [WorkflowTag]

    /// Linear interpolation of a per-column array at time `t`.
    func interp(_ a: [CGFloat], _ t: Double) -> CGFloat {
        let n = colT.count
        if t <= t0 { return a[0] }
        let lastCenter = colT[n - 2]
        if t >= lastCenter {
            let span = colT[n - 1] - lastCenter
            let k = CGFloat(span > 0 ? min(1, (t - lastCenter) / span) : 1)
            return a[n - 2] + (a[n - 1] - a[n - 2]) * k
        }
        let f = (t - t0) / step
        let i = Int(f)
        let k = CGFloat(f - Double(i))
        return a[i] * (1 - k) + a[i + 1] * k
    }
}

/// Allows one heavy redraw (a river image or the panel's text) per frame, so that when a snapshot arrives the
/// box's river, the panel's river and the panel's text are redrawn on successive frames instead of all in one,
/// which would take long enough to drop a frame. Reset by `tick`, which runs once per frame.
private final class FrameBudget {
    private var available = true

    func reset() { available = true }

    func take() -> Bool {
        defer { available = false }
        return available
    }
}

/// RGB components of a color resolved for the current appearance, for mixing.
private struct RGB {
    var r: CGFloat, g: CGFloat, b: CGFloat

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        r = c.redComponent; g = c.greenComponent; b = c.blueComponent
    }

    func cg(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: max(0, min(1, alpha))) }
    func mixWhite(_ k: CGFloat, _ alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: r + (1 - r) * k, green: g + (1 - g) * k, blue: b + (1 - b) * k, alpha: max(0, min(1, alpha)))
    }
    func mixBlack(_ k: CGFloat, _ alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: r * (1 - k), green: g * (1 - k), blue: b * (1 - k), alpha: max(0, min(1, alpha)))
    }
}

private enum Palette {
    static var isDark: Bool { NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// The river for one surface (the box or the panel): its geometry, cached image and particles.
private final class River {
    struct Config {
        var window: Double
        var bucketsPerColumn: Int
        var cellSeconds: Double
        var width: CGFloat
        var xNow: CGFloat
        var xLeft: CGFloat = 0
        var stripLeft: CGFloat
        var riverTop: CGFloat
        var bottom: CGFloat
        var stripGap: CGFloat
        var stripMax: CGFloat
        var pitchMin: CGFloat
        var pitchMax: CGFloat
        /// The river's height when it is fixed (the panel, whose strip grows below it), or nil when the
        /// whole height is fixed and the river gets what the strip leaves (the box).
        var fixedRiverH: CGFloat?
        var unitMax: CGFloat
        var rankW: CGFloat = 0.42
        var rankExp: CGFloat = 0.85
        var spMax: CGFloat
        var hIdle: CGFloat
        var hMax: CGFloat
        var hFrac: CGFloat = 0.42
        var aIdle: CGFloat
        var aMax: CGFloat
        var rateRef: Double = 42
        var cellRef: Double = 30
        var sessionRamp: Double
        var agentRamp: Double
        var glow: CGFloat
        var core: CGFloat
        var source: CGFloat
        var particleGapMain: CGFloat
        var particleGapAgent: CGFloat
        var particleSpeed: CGFloat
        var particleLength: CGFloat
        var particleSize: CGFloat
        var fade: CGFloat
        /// At most this many filaments per session; agents beyond them merge into one band.
        var filaments: Int
        var workflowTags: Bool

        static let box = Config(
            window: 600, bucketsPerColumn: 1, cellSeconds: 10, width: 310, xNow: 301, stripLeft: 9, riverTop: 3, bottom: 7,
            stripGap: 4, stripMax: 20, pitchMin: 2, pitchMax: 5, fixedRiverH: nil, unitMax: 20, spMax: 3.2,
            hIdle: 0.45, hMax: 4.2, aIdle: 0.3, aMax: 1.3, sessionRamp: 30, agentRamp: 20, glow: 3.2, core: 0.7, source: 4.5,
            particleGapMain: 9, particleGapAgent: 9, particleSpeed: 16, particleLength: 2.6, particleSize: 1.05, fade: 26,
            filaments: 6, workflowTags: false)

        static let panel = Config(
            window: 1800, bucketsPerColumn: 2, cellSeconds: 30, width: 480, xNow: 388, stripLeft: 8, riverTop: 8, bottom: 18,
            stripGap: 8, stripMax: 48, pitchMin: 3, pitchMax: 7, fixedRiverH: PanelLayout.riverHeight, unitMax: 34, spMax: 5,
            hIdle: 0.6, hMax: 6.5, aIdle: 0.45, aMax: 1.8, sessionRamp: 70, agentRamp: 30, glow: 4.5, core: 0.8, source: 6,
            particleGapMain: 8, particleGapAgent: 7, particleSpeed: 22, particleLength: 3.4, particleSize: 1.25, fade: 30,
            filaments: 10, workflowTags: true)

        var maxRows: Int { Int(stripMax / pitchMin) }

        func stripRows(_ count: Int) -> (pitch: CGFloat, height: CGFloat) {
            let rows = min(count, maxRows)
            guard rows > 0 else { return (0, 0) }
            let budget = fixedRiverH == nil ? stripMax : min(stripMax, CGFloat(rows) * pitchMax)
            let pitch = min(pitchMax, max(pitchMin, budget / CGFloat(rows)))
            return (pitch, CGFloat(rows) * pitch)
        }

        /// The panel's river height for `rows` sessions.
        func height(rows: Int) -> CGFloat {
            riverTop + (fixedRiverH ?? 0) + stripGap + stripRows(rows).height + bottom
        }
    }

    /// Agents merged into bands in the last build, for the band's tooltip.
    private(set) var overflow = Set<String>()

    let config: Config
    private let slots: SlotBook
    private(set) var geometry: Geometry?
    private(set) var height: CGFloat = 0
    var width: CGFloat { config.width }
    var pps: CGFloat { (config.xNow - config.xLeft) / CGFloat(config.window) }

    private let image = Offscreen()
    private var imageKey = ""
    /// When the image was drawn; it is shifted left by the time since.
    private var imageDate = Date.distantPast
    private var colorModels: [String] = []
    /// Workflow tags, each a small cached bitmap, and where they go when the image isn't shifted.
    private var tagSprites: [(sprite: Offscreen, origin: CGPoint)] = []
    private var spriteCache: [String: Offscreen] = [:]
    private let budget: FrameBudget
    /// The time (relative to the geometry's snapshot) the image was drawn for.
    private var imageNow: Double = 0
    private var colors: [RGB] = []
    private var gradients: [CGGradient] = []
    private var colorsDark: Bool?
    private var pools: [String: [Particle]] = [:]
    private var lastDraw: Date?
    private var rng = SystemRandomNumberGenerator()

    init(config: Config, slots: SlotBook, budget: FrameBudget) {
        self.config = config
        self.slots = slots
        self.budget = budget
    }

    func reset() {
        pools.removeAll()
        lastDraw = nil
    }

    // MARK: Data helpers

    static func familyRank(_ id: String) -> Int {
        if id.contains("opus") { return 0 }
        if id.contains("sonnet") { return 1 }
        if id.contains("haiku") { return 2 }
        if id.contains("fable") { return 3 }
        return 4
    }

    /// Output over the last minute of a thread's history.
    static func lastMinute(_ buckets: [ActivityBucket]) -> Double {
        buckets.suffix(Int(60 / ActivitySnapshot.bucketSeconds)).reduce(0) { $0 + $1.output }
    }

    /// When a session ended, relative to `time`, or nil while it's open.
    static func end(of s: SessionActivity, time: Date) -> Double? {
        if s.isOpen { return nil }
        return (s.endedAt ?? s.main.lastActivity).timeIntervalSince(time)
    }

    /// Sessions with a stream in the last `window` seconds, in the order they started.
    static func visibleSessions(_ snapshot: ActivitySnapshot, window: Double) -> [SessionActivity] {
        let left = -(window + 15)
        return snapshot.sessions
            .filter { s in
                s.startedAt.timeIntervalSince(snapshot.time) < 0 && (end(of: s, time: snapshot.time).map { $0 > left } ?? true)
            }
            .sorted { $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt : $0.id < $1.id }
    }

    // MARK: Building

    /// Rebuilds the geometry when the snapshot or the height changed.
    func prepare(snapshot: ActivitySnapshot, height: CGFloat) {
        if let geometry, geometry.time == snapshot.time, self.height == height { return }
        self.height = height
        geometry = build(snapshot)
        imageKey = ""
        let keys = Set(geometry?.streams.map(\.key) ?? [])
        pools = pools.filter { keys.contains($0.key) }
    }

    private func build(_ snapshot: ActivitySnapshot) -> Geometry {
        let cfg = config
        let bucketSeconds = ActivitySnapshot.bucketSeconds
        let bucketCount = ActivitySnapshot.bucketCount
        let per = cfg.bucketsPerColumn
        let step = Double(per) * bucketSeconds
        let nc = min(bucketCount / per, Int(((cfg.window + step * 3) / step).rounded(.up)))
        let firstBucket = bucketCount - nc * per
        let t0 = -Double(bucketCount - firstBucket) * bucketSeconds + step / 2
        var colT = (0..<nc).map { t0 + Double($0) * step }
        colT.append(0)
        let n = colT.count
        let tLeft = -(cfg.window + step * 3)

        /// Output tokens per second per column, lightly smoothed (the last point repeats the last column).
        func rates(_ buckets: [ActivityBucket]) -> [CGFloat] {
            var r = [CGFloat](repeating: 0, count: n)
            if buckets.count == bucketCount {
                for j in 0..<nc {
                    var sum = 0.0
                    let b = firstBucket + j * per
                    for k in b..<(b + per) { sum += buckets[k].output }
                    r[j] = CGFloat(sum / step)
                }
            }
            r[n - 1] = r[n - 2]
            var s = [CGFloat](repeating: 0, count: n)
            for i in 0..<n {
                let a = r[max(0, i - 2)], b = r[max(0, i - 1)], c = r[i], d = r[min(n - 1, i + 1)], e = r[min(n - 1, i + 2)]
                s[i] = (a + 4 * b + 6 * c + 4 * d + e) / 16
            }
            return s
        }
        let rateRef = CGFloat(cfg.rateRef)
        func glow(_ rate: CGFloat) -> CGFloat { min(1, (max(0, rate) / rateRef).squareRoot()) }

        let sessions = Self.visibleSessions(snapshot, window: cfg.window)
        var allIDs = Set<String>()
        var models: [String] = []
        var modelIndex: [String: Int] = [:]
        func color(_ model: String) -> Int {
            if let i = modelIndex[model] { return i }
            models.append(model)
            modelIndex[model] = models.count - 1
            return models.count - 1
        }

        /// A subagent's lifetime and how it eases in and out.
        struct Agent {
            var activity: AgentActivity
            var start: Double
            var end: Double?
            var ramp: Double
            var slot: Int
            var parent: Int?
            var rates: [CGFloat]

            func envelope(_ t: Double) -> Double {
                if t < start { return 0 }
                if let end, t > end { return 0 }
                let a = smoothstep((t - start) / ramp)
                return end.map { a * smoothstep(($0 - t) / ramp) } ?? a
            }
        }

        /// Per session: presence and branch demand per column, its kept agents and its band.
        struct SessionLayout {
            var session: SessionActivity
            var start: Double
            var end: Double?
            var presence: [Double]
            var demand: [CGFloat]
            var agents: [Agent]
            var overflow: [Agent]
            var rates: [CGFloat]
            var center: [CGFloat] = []
            var half: [CGFloat] = []
            var spread: [CGFloat] = []
        }

        var overflowIDs = Set<String>()
        var layouts: [SessionLayout] = []
        for s in sessions {
            for a in s.agents { allIDs.insert(a.id) }
            slots.assign(s.agents)
            let start = s.startedAt.timeIntervalSince(snapshot.time)
            let end = Self.end(of: s, time: snapshot.time)
            var kept: [Agent] = [], overflow: [Agent] = []
            var keptIndex: [String: Int] = [:]
            for a in s.agents {
                let aStart = a.start.timeIntervalSince(snapshot.time)
                let aEnd = a.end.map { $0.timeIntervalSince(snapshot.time) }
                if let aEnd, aEnd <= tLeft { continue }
                let life = aEnd.map { $0 - aStart } ?? .infinity
                var agent = Agent(activity: a, start: aStart, end: aEnd, ramp: max(2, min(cfg.agentRamp, life / 2.2)),
                                  slot: slots.slot(a.id), parent: nil, rates: rates(a.buckets))
                if agent.slot < cfg.filaments {
                    if let p = a.parentID { agent.parent = keptIndex[p] }
                    keptIndex[a.id] = kept.count
                    kept.append(agent)
                } else {
                    overflow.append(agent)
                    overflowIDs.insert(a.id)
                }
            }
            var presence = [Double](repeating: 0, count: n)
            var demand = [CGFloat](repeating: 0, count: n)
            let bandRank = abs(slotRank(cfg.filaments))
            for i in 0..<n {
                let t = colT[i]
                var p = smoothstep((t - start) / cfg.sessionRamp)
                if let end { p *= smoothstep((end - t) / cfg.sessionRamp) }
                presence[i] = p
                var m: CGFloat = 0
                for a in kept {
                    let e = a.envelope(t)
                    if e > 0 { m = max(m, abs(slotRank(a.slot)) * CGFloat(e)) }
                }
                for a in overflow {
                    let e = a.envelope(t)
                    if e > 0 { m = max(m, bandRank * CGFloat(e)) }
                }
                demand[i] = m
            }
            layouts.append(SessionLayout(session: s, start: start, end: end, presence: presence, demand: demand,
                                         agents: kept, overflow: overflow, rates: rates(s.main.buckets)))
        }
        overflow = overflowIDs
        slots.prune(keeping: allIDs)

        // Strip rows: one per session, dropping the oldest ended ones first when there are too many.
        var rowSessions = sessions
        while rowSessions.count > cfg.maxRows {
            let k = rowSessions.firstIndex { !$0.isOpen } ?? 0
            rowSessions.remove(at: k)
        }
        let strip = cfg.stripRows(rowSessions.count)
        let riverTop = cfg.riverTop
        let riverH: CGFloat
        if let fixed = cfg.fixedRiverH { riverH = fixed } else {
            riverH = height - riverTop - strip.height - cfg.stripGap - cfg.bottom
        }
        let stripTop = riverTop + riverH + cfg.stripGap

        // Lanes: each session's share of the height, wider while its branches are out.
        for i in 0..<n {
            var total: CGFloat = 0
            var demands = [CGFloat](repeating: 0, count: layouts.count)
            for (k, L) in layouts.enumerated() {
                let d = CGFloat(L.presence[i]) * (1 + cfg.rankW * pow(L.demand[i], cfg.rankExp))
                demands[k] = d
                total += d
            }
            let unit = min(cfg.unitMax, riverH / max(total, 1))
            var y = riverTop + (riverH - unit * total) / 2
            for k in layouts.indices {
                if i == 0 {
                    layouts[k].center = [CGFloat](repeating: 0, count: n)
                    layouts[k].half = [CGFloat](repeating: 0, count: n)
                    layouts[k].spread = [CGFloat](repeating: 0, count: n)
                }
                let h = unit * demands[k]
                layouts[k].center[i] = y + h / 2
                layouts[k].half[i] = h / 2
                let rd = layouts[k].demand[i]
                layouts[k].spread[i] = min(cfg.spMax, rd > 0 ? (h / 2) / (pow(rd, cfg.rankExp) + 0.55) : cfg.spMax)
                y += h
            }
        }

        let geoBase = Geometry(time: snapshot.time, colT: colT, t0: t0, step: step, lanes: [], streams: [], models: [],
                               pitch: strip.pitch, stripH: strip.height, stripTop: stripTop, riverTop: riverTop, riverH: riverH,
                               cells: [], tags: [])

        var streams: [Stream] = []
        var lanes: [Lane] = []
        for L in layouts {
            let s = L.session
            // The main stream.
            var main = Stream(key: "m:" + s.id, sessionID: s.id, kind: .main, color: color(s.model), depth: 0,
                              live: s.isOpen, active: s.isBusy)
            for i in 0..<n {
                let p = L.presence[i]
                let near = (i > 0 && L.presence[i - 1] > 0.001) || (i < n - 1 && L.presence[i + 1] > 0.001)
                if p <= 0.001 && !near { continue }
                let gv = glow(L.rates[i])
                let hMax = min(cfg.hMax, L.half[i] * cfg.hFrac)
                main.t.append(colT[i])
                main.y.append(L.center[i])
                main.h.append(CGFloat(p) * (cfg.hIdle + (hMax - cfg.hIdle) * gv))
                main.g.append(gv * CGFloat(p))
            }
            if main.t.count > 1 { streams.append(main) }

            let status: String
            let running = s.runningAgents
            if running > 0 { status = running == 1 ? "1 agent" : "\(running) agents" }
            else { status = s.isBusy ? "busy" : s.isOpen ? "idle" : "ended" }
            lanes.append(Lane(sessionID: s.id, name: s.name, status: status, live: s.isOpen, center: L.center, half: L.half))

            // Branches.
            func offset(_ index: Int, _ t: Double) -> CGFloat {
                let a = L.agents[index]
                let sp = geoBase.interp(L.spread, min(t, 0))
                var base: CGFloat = 0
                if let p = a.parent, L.agents[p].envelope(t) > 0 { base = offset(p, t) }
                return base + CGFloat(a.envelope(t)) * (slotRank(a.slot) * sp - base)
            }
            func times(start: Double, end: Double?, ramp: Double) -> [Double]? {
                let ta = max(start, colT[0]), tb = end.map { min($0, 0) } ?? 0
                guard tb > ta else { return nil }
                var times = [ta]
                for t in colT where t > ta + 0.3 && t < tb - 0.3 { times.append(t) }
                for k in [0.33, 0.66] {
                    if start + ramp * k > ta { times.append(start + ramp * k) }
                    if let end, end - ramp * k < tb { times.append(end - ramp * k) }
                }
                times.append(tb)
                return times.sorted()
            }
            for (index, a) in L.agents.enumerated() {
                guard let ts = times(start: a.start, end: a.end, ramp: a.ramp) else { continue }
                let act = a.activity
                var st = Stream(key: "a:" + act.id, sessionID: s.id, kind: .agent, color: color(act.model), depth: act.depth,
                                live: act.isRunning, active: act.isRunning && (act.state == .generating || act.state == .tool))
                for t in ts {
                    let gv = glow(geoBase.interp(a.rates, t))
                    let e = CGFloat(a.envelope(t))
                    st.t.append(t)
                    st.y.append(geoBase.interp(L.center, min(t, 0)) + offset(index, t))
                    st.h.append((cfg.aIdle + (cfg.aMax - cfg.aIdle) * gv) * e.squareRoot())
                    st.g.append(gv * e)
                }
                streams.append(st)
            }
            // Agents beyond the filament cap share one band on the outermost slot.
            if !L.overflow.isEmpty {
                let start = L.overflow.map(\.start).min() ?? 0
                let end: Double? = L.overflow.contains { $0.end == nil } ? nil : L.overflow.compactMap(\.end).max()
                let ramp = L.overflow.map(\.ramp).max() ?? cfg.agentRamp
                if let ts = times(start: start, end: end, ramp: ramp) {
                    var rate = [CGFloat](repeating: 0, count: n)
                    for a in L.overflow { for i in 0..<n { rate[i] += a.rates[i] } }
                    var counts: [String: Int] = [:]
                    for a in L.overflow { counts[a.activity.model, default: 0] += 1 }
                    let model = counts.max { $0.value < $1.value }?.key ?? s.model
                    let rank = slotRank(cfg.filaments)
                    var st = Stream(key: "b:" + s.id, sessionID: s.id, kind: .band, color: color(model), depth: 1,
                                    live: end == nil,
                                    active: L.overflow.contains { $0.activity.isRunning && ($0.activity.state == .generating || $0.activity.state == .tool) })
                    for t in ts {
                        let e = CGFloat(L.overflow.reduce(0) { max($0, $1.envelope(t)) })
                        let gv = glow(geoBase.interp(rate, t))
                        st.t.append(t)
                        st.y.append(geoBase.interp(L.center, min(t, 0)) + e * rank * geoBase.interp(L.spread, min(t, 0)))
                        st.h.append((cfg.aIdle * 1.5 + (cfg.aMax * 1.7 - cfg.aIdle * 1.5) * gv) * e.squareRoot())
                        st.g.append(gv * e)
                    }
                    streams.append(st)
                }
            }
        }
        // Deeper branches draw over the main channel so the delta reads on top.
        streams = streams.enumerated().sorted { $0.element.depth != $1.element.depth ? $0.element.depth < $1.element.depth : $0.offset < $1.offset }
            .map(\.element)

        // Squares: each session's output (subagents included) in cells aligned to whole multiples of the
        // cell size, so they stay put as the snapshot time moves on.
        var cells: [Cell] = []
        let cs = cfg.cellSeconds
        let refAbs = snapshot.time.timeIntervalSinceReferenceDate
        let firstCell = ((refAbs - cfg.window - 2 * cs) / cs).rounded(.down) * cs
        let cellCount = Int(((refAbs - firstCell) / cs).rounded(.up))
        let windowStartAbs = refAbs - Double(bucketCount) * bucketSeconds
        for (row, s) in rowSessions.enumerated() {
            var out = [Double](repeating: 0, count: cellCount)
            var running = [Double](repeating: 0, count: cellCount)
            func spread(_ a: Double, _ b: Double, _ amount: Double, into array: inout [Double], perSecond: Bool) {
                guard b > a else { return }
                var k = max(0, Int((a - firstCell) / cs))
                while k < cellCount {
                    let c0 = firstCell + Double(k) * cs, c1 = c0 + cs
                    if c0 >= b { break }
                    let overlap = min(b, c1) - max(a, c0)
                    if overlap > 0 { array[k] += perSecond ? overlap : amount * overlap / (b - a) }
                    k += 1
                }
            }
            for thread in s.threads where thread.buckets.count == bucketCount {
                for (i, bucket) in thread.buckets.enumerated() where bucket.output > 0 {
                    let a = windowStartAbs + Double(i) * bucketSeconds
                    if a + bucketSeconds < firstCell { continue }
                    spread(a, a + bucketSeconds, bucket.output, into: &out, perSecond: false)
                }
            }
            for a in s.agents {
                let start = a.start.timeIntervalSinceReferenceDate
                let end = (a.end ?? snapshot.time).timeIntervalSinceReferenceDate
                spread(max(start, firstCell), end, 0, into: &running, perSecond: true)
            }
            let sStart = s.startedAt.timeIntervalSinceReferenceDate
            let sEnd = Self.end(of: s, time: snapshot.time).map { $0 + refAbs }
            let colorIndex = color(s.model)
            for k in 0..<cellCount {
                let b0 = firstCell + Double(k) * cs
                let b1 = min(b0 + cs, refAbs)
                if b1 <= sStart { continue }
                if let sEnd, b0 >= sEnd { continue }
                let span = b1 - b0
                guard span > 0.5 else { continue }
                let v = min(1, (out[k] / max(1, span) / cfg.cellRef).squareRoot())
                cells.append(Cell(row: row, b0: b0 - refAbs, b1: b1 - refAbs, value: CGFloat(v), agents: running[k] / span >= 0.5,
                                  color: colorIndex, sessionID: s.id))
            }
        }

        // Workflow tags where each delta opens.
        var tags: [WorkflowTag] = []
        if cfg.workflowTags {
            for (laneIndex, L) in layouts.enumerated() {
                for wf in L.session.workflows {
                    let starts = L.session.agents.filter { $0.workflowID == wf.id }.map(\.start)
                    guard let first = starts.min() else { continue }
                    tags.append(WorkflowTag(lane: laneIndex, start: first.timeIntervalSince(snapshot.time),
                                            label: "\(wf.name) ×\(wf.agentCount)", sessionID: L.session.id))
                }
            }
        }

        var geo = geoBase
        geo.lanes = lanes
        geo.streams = streams
        geo.models = models
        geo.cells = cells
        geo.tags = tags
        return geo
    }

    // MARK: Hit testing

    /// The stream under a point, preferring thin branches over the main channel they overlap.
    func hit(_ point: CGPoint, now: Date) -> Stream? {
        guard let geo = geometry else { return nil }
        let nowT = now.timeIntervalSince(geo.time)
        let t = nowT - Double((config.xNow - point.x) / pps)
        var best: Stream?
        var bestD: CGFloat = .greatestFiniteMagnitude
        for st in geo.streams {
            let last = st.t[st.t.count - 1]
            let end = st.live ? max(last, nowT) : last
            if t < st.t[0] - 2 || t > end + 2 { continue }
            let q = st.sample(t)
            let d = abs(q.y - point.y) - q.h
            let priority: CGFloat = st.kind == .main ? 0.6 : 0
            if d < 4 && d + priority < bestD {
                bestD = d + priority
                best = st
            }
        }
        return best
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, now: Date, snapshot: ActivitySnapshot, height: CGFloat, focus: String?, focusStream: String?,
              dark: Bool) {
        prepare(snapshot: snapshot, height: height)
        guard let geo = geometry else { return }
        let dt = CGFloat(min(0.1, max(0, lastDraw.map { now.timeIntervalSince($0) } ?? 0)))
        lastDraw = now
        let nowT = now.timeIntervalSince(geo.time)
        if colorsDark != dark || colorModels != geo.models { resolveColors(geo.models, dark: dark) }

        // Redraw the cached image when something it shows changed, or when time has moved on so far that the
        // live streams' extension past now would run out. Unless there's no image yet, it waits for a frame
        // with nothing else heavy to do (see `FrameBudget`) and the old one stands in meanwhile.
        let scale = Offscreen.scale(of: ctx)
        let key = "\(geo.time.timeIntervalSinceReferenceDate)|\(focus ?? "")|\(focusStream ?? "")|\(dark)|\(scale)|\(height)"
        let stale = now.timeIntervalSince(imageDate) > 3 || now < imageDate.addingTimeInterval(-0.5)
        if (key != imageKey || stale) && (image.image == nil || stale || budget.take()) {
            imageKey = key
            imageDate = now
            renderImage(geo, like: ctx, nowT: nowT, dark: dark, focus: focus, focusStream: focusStream)
        }
        // Shifted by whole device pixels, so the image is copied rather than resampled. The image is redrawn
        // at exact positions with every snapshot, so the rounding never shows.
        let shift = (-CGFloat(now.timeIntervalSince(imageDate)) * pps * scale).rounded() / scale
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: config.xNow + 1, height: height))
        image.draw(in: ctx, at: CGPoint(x: shift, y: 0))
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: config.xNow + 6, height: geo.stripTop - 1))
        drawParticles(ctx, geo: geo, nowT: nowT, dt: dt, realT: now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600),
                      dark: dark, focus: focus, focusStream: focusStream)
        ctx.restoreGState()

        // Workflow tags go over the particles so they stay legible.
        for tag in tagSprites {
            tag.sprite.draw(in: ctx, at: CGPoint(x: tag.origin.x + shift, y: tag.origin.y))
        }
    }

    private func resolveColors(_ models: [String], dark: Bool) {
        colorsDark = dark
        colorModels = models
        colors = models.map { RGB(ClaudeModel.color($0)) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        gradients = colors.compactMap { c in
            let center = dark ? c.mixWhite(0.7, 0.95) : c.mixWhite(0.15, 0.9)
            return CGGradient(colorsSpace: space, colors: [center, c.cg(0.5), c.cg(0)] as CFArray, locations: [0, 0.35, 1])
        }
    }

    private func dim(_ st: Stream, focus: String?, focusStream: String?) -> CGFloat {
        (focus != nil && st.sessionID != focus ? 0.22 : 1) * (focusStream == st.key ? 1.5 : 1)
    }

    /// Draws the streams and squares into the cached image for time `nowT`, and lays out the workflow tags.
    private func renderImage(_ geo: Geometry, like ctx: CGContext, nowT: Double, dark: Bool, focus: String?, focusStream: String?) {
        let size = CGSize(width: config.xNow + 8, height: height)
        guard let c = image.begin(size: size, like: ctx) else { return }
        let cfg = config
        let pps = self.pps
        let X = { (t: Double) -> CGFloat in cfg.xNow - CGFloat(nowT - t) * pps }
        let tMin = nowT - Double((cfg.xNow - cfg.xLeft + 6) / pps)

        struct Visible { let stream: Stream; var xs: [CGFloat]; var alpha: CGFloat }
        var visible: [Visible] = []
        for st in geo.streams {
            let n = st.t.count
            guard st.t[n - 1] >= tMin || st.live else { continue }
            var i0 = 0
            while i0 < n - 1 && st.t[i0 + 1] < tMin { i0 += 1 }
            var xs: [CGFloat] = []
            xs.reserveCapacity(n - i0)
            for i in i0..<n {
                var t = st.t[i]
                // Live streams reach a little past now, so the image still reaches the edge as it shifts.
                if i == n - 1 && st.live { t = max(t, nowT + 4) }
                xs.append(X(t))
            }
            var v = Visible(stream: st, xs: xs, alpha: dim(st, focus: focus, focusStream: focusStream))
            if i0 > 0 {
                v = Visible(stream: Stream(key: st.key, sessionID: st.sessionID, kind: st.kind, color: st.color, depth: st.depth,
                                           live: st.live, active: st.active, t: Array(st.t[i0...]), y: Array(st.y[i0...]),
                                           h: Array(st.h[i0...]), g: Array(st.g[i0...])), xs: xs, alpha: v.alpha)
            }
            visible.append(v)
        }

        func band(_ v: Visible, extra: CGFloat) -> CGPath {
            let path = CGMutablePath()
            let st = v.stream, m = v.xs.count
            for i in 0..<m {
                let e = st.h[i] + (st.h[i] > 0.05 ? extra * (0.2 + 0.8 * st.g[i]) : 0)
                let p = CGPoint(x: v.xs[i], y: st.y[i] - e)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            for i in stride(from: m - 1, through: 0, by: -1) {
                let e = st.h[i] + (st.h[i] > 0.05 ? extra * (0.2 + 0.8 * st.g[i]) : 0)
                path.addLine(to: CGPoint(x: v.xs[i], y: st.y[i] + e))
            }
            path.closeSubpath()
            return path
        }

        c.saveGState()
        c.clip(to: CGRect(x: 0, y: 0, width: size.width, height: geo.stripTop - 1))
        // 1. Glow: additive in dark mode, a soft tint in light mode.
        c.setBlendMode(dark ? .plusLighter : .normal)
        for v in visible {
            let col = colors[v.stream.color]
            c.setFillColor(col.cg((dark ? 0.09 : 0.045) * v.alpha))
            c.addPath(band(v, extra: dark ? cfg.glow : cfg.glow * 0.7))
            c.fillPath()
            c.setFillColor(col.cg((dark ? 0.14 : 0.09) * v.alpha))
            c.addPath(band(v, extra: cfg.glow * (dark ? 0.45 : 0.3)))
            c.fillPath()
        }
        // 2. Bodies, each with a hairline core so idle threads stay visible.
        c.setBlendMode(.normal)
        c.setLineJoin(.round)
        for v in visible {
            let col = colors[v.stream.color]
            let a = min(1, v.alpha)
            c.setFillColor(col.cg((dark ? 0.62 : 0.72) * a))
            c.addPath(band(v, extra: 0))
            c.fillPath()
            c.setStrokeColor(dark ? col.mixWhite(0.35, 0.55 * a) : col.mixBlack(0.15, 0.6 * a))
            c.setLineWidth(v.stream.kind == .main ? cfg.core : cfg.core * 0.8)
            c.beginPath()
            for i in 0..<v.xs.count {
                let p = CGPoint(x: v.xs[i], y: v.stream.y[i])
                if i == 0 { c.move(to: p) } else { c.addLine(to: p) }
            }
            c.strokePath()
        }
        c.restoreGState()

        // 3. The strip of squares.
        if geo.stripH > 0 {
            c.saveGState()
            c.clip(to: CGRect(x: cfg.stripLeft, y: geo.stripTop - 1, width: cfg.xNow + 1 - cfg.stripLeft, height: geo.stripH + 2))
            let gap: CGFloat = geo.pitch >= 4 ? 1 : 0.6
            let empty = NSColor.labelColor.withAlphaComponent(dark ? 0.08 : 0.07)
            for cell in geo.cells {
                let x0 = X(cell.b0), x1 = X(cell.b1)
                if x1 < cfg.stripLeft { continue }
                let y = geo.stripTop + CGFloat(cell.row) * geo.pitch
                let a: CGFloat = focus != nil && cell.sessionID != focus ? 0.3 : 1
                if cell.value <= 0.02 {
                    c.setFillColor(empty.withAlphaComponent(empty.alphaComponent * a).cgColor)
                } else {
                    c.setFillColor(colors[cell.color].cg((0.22 + 0.78 * cell.value) * a))
                }
                let w = max(0.5, x1 - x0 - gap)
                c.fill(CGRect(x: x0 + gap / 2, y: y, width: w, height: geo.pitch - gap))
                if cell.agents && geo.pitch >= 3 {
                    c.setFillColor(CGColor(gray: 1, alpha: (dark ? 0.7 : 0.85) * a))
                    c.fill(CGRect(x: x0 + gap / 2 + w / 2 - 0.5, y: y + (geo.pitch - gap) / 2 - 0.5, width: 1, height: 1))
                }
            }
            c.restoreGState()
        }

        // 4. Fade the far past out at the left edge.
        if cfg.fade > 0, let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                              colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray,
                                              locations: [0, 1]) {
            c.saveGState()
            c.setBlendMode(.destinationOut)
            c.clip(to: CGRect(x: 0, y: 0, width: cfg.xLeft + cfg.fade, height: size.height))
            c.drawLinearGradient(fade, start: CGPoint(x: cfg.xLeft - 4, y: 0), end: CGPoint(x: cfg.xLeft + cfg.fade, y: 0),
                                 options: [.drawsBeforeStartLocation])
            c.restoreGState()
        }

        image.finish()

        // 5. Workflow tags where each delta opens, just above the session's highest branch along the tag.
        var sprites: [(sprite: Offscreen, origin: CGPoint)] = []
        var used = Set<String>()
        let font = NSFont.systemFont(ofSize: 9.5)
        for tag in geo.tags {
            let x = X(tag.start)
            if x < 40 || x > cfg.xNow - 10 { continue }
            let dimmed = focus != nil && focus != tag.sessionID
            let text = Text.make(tag.label, font, dimmed ? NSColor.labelColor.withAlphaComponent(0.25) : .secondaryLabelColor)
            let w = ceil(text.size().width) + 4
            let lx = min(x + 2, cfg.xNow - w)
            let tStart = nowT - Double((cfg.xNow - lx) / pps), tEnd = nowT - Double((cfg.xNow - lx - w) / pps)
            // The room above and below the session's own streams along the tag, up to its neighbors' streams.
            var top = CGFloat.greatestFiniteMagnitude, bottom = -CGFloat.greatestFiniteMagnitude
            var ceiling = geo.riverTop - 6, floor = geo.riverTop + geo.riverH + 6
            let laneOrder = Dictionary(uniqueKeysWithValues: geo.lanes.enumerated().map { ($0.element.sessionID, $0.offset) })
            for st in geo.streams {
                guard let lane = laneOrder[st.sessionID] else { continue }
                let lastT = st.live ? max(st.t[st.t.count - 1], nowT) : st.t[st.t.count - 1]
                for k in 0...6 {
                    let t = tStart + (tEnd - tStart) * Double(k) / 6
                    guard t >= st.t[0], t <= lastT else { continue }
                    let q = st.sample(t)
                    if q.h < 0.05 && st.kind != .main { continue }
                    let upper = q.y - q.h - 1, lower = q.y + q.h + 1
                    if lane == tag.lane { top = min(top, upper); bottom = max(bottom, lower) }
                    else if lane < tag.lane { ceiling = max(ceiling, lower) }
                    else { floor = min(floor, upper) }
                }
            }
            guard top < .greatestFiniteMagnitude else { continue }
            let height: CGFloat = 11
            let above = top - ceiling, below = floor - bottom
            let y: CGFloat
            if above >= height { y = top - 12 }
            else if below >= height { y = bottom - 1 }
            else if above >= below { y = (top + ceiling) / 2 - 6.5 }
            else { y = (bottom + floor) / 2 - 6.5 }
            let key = "\(tag.label)|\(dimmed)|\(dark)|\(Offscreen.scale(of: ctx))"
            used.insert(key)
            let sprite = spriteCache[key] ?? {
                let sprite = Offscreen()
                if let t = sprite.begin(size: CGSize(width: w, height: 13), like: ctx) {
                    Offscreen.withAppKit(t) {
                        // A halo in the panel's background color, so the tag reads over the streams.
                        if !dimmed {
                            var attrs = text.attributes(at: 0, effectiveRange: nil)
                            attrs[.strokeColor] = NSColor.windowBackgroundColor.withAlphaComponent(0.8)
                            attrs[.strokeWidth] = 28
                            Text.draw(NSAttributedString(string: tag.label, attributes: attrs), x: 2, midY: 6.5)
                        }
                        Text.draw(text, x: 2, midY: 6.5)
                    }
                    sprite.finish()
                }
                spriteCache[key] = sprite
                return sprite
            }()
            sprites.append((sprite, CGPoint(x: lx - 2, y: y)))
        }
        spriteCache = spriteCache.filter { used.contains($0.key) }
        tagSprites = sprites
    }

    /// Particles drifting along busy stretches, and sources glowing at the right edge where threads produce
    /// tokens now. Drawn every frame; particles of one color and brightness go into one path.
    private func drawParticles(_ ctx: CGContext, geo: Geometry, nowT: Double, dt: CGFloat, realT: Double, dark: Bool,
                               focus: String?, focusStream: String?) {
        let cfg = config
        let pps = self.pps
        let X = { (t: Double) -> CGFloat in cfg.xNow - CGFloat(nowT - t) * pps }
        let T = { (x: CGFloat) -> Double in nowT - Double((cfg.xNow - x) / pps) }
        let levels = 5
        // Paths by color, variant (light mode draws on wide streams in white) and alpha level.
        var paths: [Int: CGMutablePath] = [:]
        let realTf = CGFloat(realT)
        // Each particle is a short dash along its stream, filled as a thin parallelogram (much cheaper than
        // stroking hundreds of tiny segments).
        let size = cfg.particleSize, half = size / 2

        for st in geo.streams {
            let n = st.t.count
            let last = st.live ? max(st.t[n - 1], nowT) : st.t[n - 1]
            let xa = max(X(st.t[0]), cfg.xLeft - 4), xb = min(X(last), cfg.xNow)
            if xb - xa < 2 { continue }
            let a0 = min(1, dim(st, focus: focus, focusStream: focusStream))
            var pool = pools[st.key] ?? []
            let gapPx = st.kind == .main ? cfg.particleGapMain : cfg.particleGapAgent
            let want = min(48, max(1, Int(((xb - xa) / gapPx).rounded())))
            while pool.count < want {
                pool.append(Particle(x: xa + CGFloat.random(in: 0...1, using: &rng) * (xb - xa),
                                     u: CGFloat.random(in: -1...1, using: &rng), v: CGFloat.random(in: 0.75...1.35, using: &rng),
                                     phase: CGFloat.random(in: 0...6.28, using: &rng)))
            }
            if pool.count > want { pool.removeLast(pool.count - want) }
            for k in pool.indices {
                var p = pool[k]
                p.x -= cfg.particleSpeed * p.v * dt
                if p.x < xa || p.x > xb { p.x = xb - CGFloat.random(in: 0...6, using: &rng) }
                pool[k] = p
                let q = st.sample(T(p.x))
                if q.g < 0.04 { continue }
                let len = cfg.particleLength * p.v
                let q2 = st.sample(T(p.x + len))
                let twinkle = 0.75 + 0.25 * sin(realTf * 3 + p.phase)
                let edge = CGFloat(smoothstep(Double((p.x - cfg.xLeft + 4) / (cfg.fade + 4))))
                let a = min(1, pow(q.g, 0.7) * twinkle * a0) * edge
                let level = min(levels - 1, Int(a * CGFloat(levels)))
                if a < 0.03 { continue }
                let variant = !dark && q.h > 1.5 ? 1 : 0
                let key = (st.color * 2 + variant) * levels + level
                let path = paths[key] ?? CGMutablePath()
                let lat = p.u * 0.7
                let y1 = q.y + lat * q.h - half, y2 = q2.y + lat * q2.h - half
                path.addLines(between: [CGPoint(x: p.x, y: y1), CGPoint(x: p.x + len, y: y2),
                                        CGPoint(x: p.x + len, y: y2 + size), CGPoint(x: p.x, y: y1 + size)])
                path.closeSubpath()
                paths[key] = path
            }
            pools[st.key] = pool
        }

        // Normal blending even in dark mode: additive fills of many small shapes are several times slower,
        // and a light dash over its stream reads the same.
        ctx.setBlendMode(.normal)
        for (key, path) in paths {
            let level = key % levels
            let variant = (key / levels) % 2
            let color = colors[key / levels / 2]
            let a = (CGFloat(level) + 0.5) / CGFloat(levels)
            let stroke: CGColor
            if dark { stroke = color.mixWhite(0.6, 0.85 * a) }
            else if variant == 1 { stroke = CGColor(gray: 1, alpha: 0.85 * a) }
            else { stroke = color.mixBlack(0.35, 0.9 * a) }
            ctx.setFillColor(stroke)
            ctx.addPath(path)
            ctx.fillPath()
        }

        // Sources at now.
        ctx.setBlendMode(dark ? .plusLighter : .normal)
        for st in geo.streams where st.live && st.active {
            let n = st.t.count
            let y = st.y[n - 1]
            let gv = max(0.35, st.g[n - 1])
            let r = cfg.source * (0.7 + 0.6 * gv) * (0.88 + 0.12 * CGFloat(sin(realT * 4 + Double(y))))
            let a = min(1, dim(st, focus: focus, focusStream: focusStream))
            ctx.saveGState()
            ctx.setAlpha(a)
            let center = CGPoint(x: cfg.xNow, y: y)
            ctx.drawRadialGradient(gradients[st.color], startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
            ctx.restoreGState()
        }
        ctx.setBlendMode(.normal)
    }
}

// MARK: - Drawing helpers

/// An offscreen bitmap at the target's scale, drawn with a flipped context like the targets.
private final class Offscreen {
    private var context: CGContext?
    private(set) var size = CGSize.zero
    private(set) var image: CGImage?

    static func scale(of ctx: CGContext) -> CGFloat {
        let s = abs(ctx.ctm.a)
        return s > 0 ? s : 2
    }

    /// Runs `body` with AppKit drawing (NSColor.set, NSBezierPath, attributed strings) going to `c`.
    static func withAppKit(_ c: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A cleared context of `size` points at `target`'s scale and color space.
    func begin(size: CGSize, like target: CGContext) -> CGContext? {
        let scale = Self.scale(of: target)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        let space = target.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if context?.width != width || context?.height != height || context?.colorSpace != space {
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.translateBy(x: 0, y: CGFloat(height))
            context?.scaleBy(x: scale, y: -scale)
        }
        guard let context else { return nil }
        self.size = size
        context.saveGState()
        context.clear(CGRect(origin: .zero, size: size))
        return context
    }

    func finish() {
        context?.restoreGState()
        image = context?.makeImage()
    }

    /// Draws the image with its top-left corner at `origin` in a flipped context.
    func draw(in ctx: CGContext, at origin: CGPoint, blend: CGBlendMode = .normal) {
        guard let image else { return }
        ctx.saveGState()
        ctx.setBlendMode(blend)
        ctx.translateBy(x: origin.x, y: origin.y + size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }
}

/// Single lines of text in a flipped context.
private enum Text {
    static func make(_ string: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// Draws `text` from `x`, vertically centered on `midY`, truncated to `maxWidth`.
    static func draw(_ text: NSAttributedString, x: CGFloat, midY: CGFloat, maxWidth: CGFloat = .greatestFiniteMagnitude) {
        let size = text.size()
        let rect = CGRect(x: x, y: Drawing.pixelAligned(midY - size.height / 2), width: min(size.width + 1, maxWidth), height: size.height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
