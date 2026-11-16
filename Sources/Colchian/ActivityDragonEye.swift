import AppKit

/// The "Dragon Eye" activity design: a polar heat map shaped like the dragon's iris.
///
/// Time runs clockwise around the iris and one turn is the snapshot's 30-minute window, so a radar hand
/// points at "now" and sweeps once every half hour (straight up on the hour and the half hour). Each session
/// is a ring of cells, newest innermost: a new session is born at the pupil and pushes the others outward.
/// Its subagents are thin arcs in a band just outside the ring, each on a lane it keeps while it's in view.
/// The slit pupil widens with the number of threads at work.
///
/// What changes only with the snapshot is drawn into offscreen bitmaps about once a second: the text, ticks
/// and gradients into one, the cells and arcs into another (also redrawn while the rings move). Each frame
/// only copies those and draws the hand, the sweep, the sparks and the pupil.
final class DragonEyeDesign: ActivityDesign {
    let boxHeight: CGFloat = 104

    private let boxIris = Iris(geometry: .box)
    private let panelIris = Iris(geometry: .panel)
    private let boxChrome = Offscreen()
    private let panelChrome = Offscreen()
    private var boxChromeKey: Int?
    private var panelChromeKey: Int?
    private var summary = Summary(.empty)
    private var summaryTime: Date?
    private var palettes: [Bool: Palette] = [:]
    /// The session IDs of the table's rows, top to bottom, for hover.
    private var rowIDs: [String] = []
    private var readout: (key: String, text: NSAttributedString)?

    func tick(dt: Double, now: Date, snapshot: ActivitySnapshot) {
        ingest(snapshot, now: now)
        boxIris.layout(dt: dt)
        // The panel's iris is laid out even while the panel is hidden, so it opens without its rings growing in.
        panelIris.layout(dt: dt)
    }

    func reset() {
        boxIris.reset()
        panelIris.reset()
        panelIris.highlight = nil
        summaryTime = nil
        readout = nil
    }

    private func ingest(_ snapshot: ActivitySnapshot, now: Date) {
        if summaryTime != snapshot.time {
            summary = Summary(snapshot)
            summaryTime = snapshot.time
        }
        if boxIris.snapshotTime != snapshot.time { boxIris.ingest(snapshot, now: now) }
        if panelIris.snapshotTime != snapshot.time { panelIris.ingest(snapshot, now: now) }
    }

    private func palette() -> Palette {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if let palette = palettes[dark] { return palette }
        let palette = Palette(dark: dark)
        palettes[dark] = palette
        return palette
    }

    // MARK: Box

    func drawBox(size: CGSize, context ctx: CGContext, now: Date, snapshot: ActivitySnapshot, mouse: CGPoint?) {
        if boxIris.snapshotTime == nil { ingest(snapshot, now: now); boxIris.layout(dt: 0) }
        let palette = palette()
        if mouse != nil {
            // Hovered, the tile is at 10 % instead of 7 %, like a highlighted row.
            ctx.setFillColor(palette.ink(0.03))
            ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
        }
        var hasher = Hasher()
        hasher.combine(summaryTime)
        hasher.combine(palette.dark)
        hasher.combine(size.width)
        let key = hasher.finalize()
        if key != boxChromeKey || boxChrome.image == nil {
            boxChromeKey = key
            boxChrome.render(size: size, matching: ctx) { ctx in
                boxIris.drawFloor(ctx, origin: .zero, now: now, palette: palette)
                drawBoxChrome(size: size, ctx: ctx, snapshot: snapshot, palette: palette)
            }
        }
        boxChrome.draw(in: ctx, at: .zero)
        boxIris.draw(in: ctx, origin: .zero, now: now, palette: palette)
    }

    /// The box's text and the chart of working agents per model, redrawn when the snapshot changes.
    private func drawBoxChrome(size: CGSize, ctx: CGContext, snapshot: ActivitySnapshot, palette: Palette) {
        let x0: CGFloat = 108, x1 = size.width - 9
        Text.draw(Text.make("Agents", .systemFont(ofSize: 12, weight: .bold), .labelColor), x: x0, midY: 14.5)
        // The rate, and a chevron toward the panel, which opens to the left of the menu.
        let chevron = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.tertiaryLabelColor])))
        var right = x1
        if let chevron {
            let s = chevron.size
            chevron.draw(in: CGRect(x: right - s.width, y: Drawing.pixelAligned(14.5 - s.height / 2), width: s.width, height: s.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            right -= s.width + 4
        }
        let rate = ActivityFormat.tokens(snapshot.outputPerMinute) + " tok/min"
        Text.draw(Text.make(rate, .monospacedDigitSystemFont(ofSize: 11, weight: .regular), .secondaryLabelColor), x: right, midY: 14.5, alignRight: true)

        // Two big numbers with captions on a shared baseline.
        let bigFont = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        let captionFont = NSFont.systemFont(ofSize: 11)
        var x = x0
        for (value, caption) in [(snapshot.agentsRunning, "running"), (snapshot.agentsRecent, "last 30 min")] {
            x += Text.draw(Text.make("\(value)", bigFont, .labelColor, kern: -0.3), x: x, baseline: 43) + 4
            x += Text.draw(Text.make(caption, captionFont, .secondaryLabelColor), x: x, baseline: 43) + 14
        }

        // Working agents (main threads and subagents) per model over the window, stacked: the same 30 minutes as one turn of the iris.
        let y1: CGFloat = 82, height: CGFloat = 24
        ctx.setFillColor(palette.ink(0.08))
        ctx.fill(CGRect(x: x0, y: y1, width: x1 - x0, height: 0.5))
        let series = summary.runningSeries
        if !series.isEmpty {
            let n = series[0].values.count
            var total = [Double](repeating: 0, count: n)
            for s in series { for i in 0..<n { total[i] += s.values[i] } }
            let peak = max(4, total.max() ?? 0) * 1.08
            let step = (x1 - x0) / CGFloat(n)
            var base = [Double](repeating: 0, count: n)
            for s in series {
                let path = CGMutablePath()
                for i in 0..<n {
                    let px = min(x1, x0 + step * (CGFloat(i) + 0.5))
                    let py = y1 - height * CGFloat((base[i] + s.values[i]) / peak)
                    if i == 0 { path.move(to: CGPoint(x: x0, y: py)) }
                    path.addLine(to: CGPoint(x: px, y: py))
                    if i == n - 1 { path.addLine(to: CGPoint(x: x1, y: py)) }
                }
                for i in stride(from: n - 1, through: 0, by: -1) {
                    let px = min(x1, x0 + step * (CGFloat(i) + 0.5))
                    let py = y1 - height * CGFloat(base[i] / peak)
                    if i == n - 1 { path.addLine(to: CGPoint(x: x1, y: py)) }
                    path.addLine(to: CGPoint(x: px, y: py))
                    if i == 0 { path.addLine(to: CGPoint(x: x0, y: py)) }
                }
                path.closeSubpath()
                ctx.setFillColor(palette.model(s.model).color.copy(alpha: palette.dark ? 0.62 : 0.55)!)
                ctx.addPath(path)
                ctx.fillPath()
                for i in 0..<n { base[i] += s.values[i] }
            }
        }
        // "Now", matching the iris's hand.
        ctx.setFillColor(palette.accent.copy(alpha: 0.9)!)
        ctx.fill(CGRect(x: x1 - 0.5, y: y1 - height, width: 1, height: height + 0.5))

        // Legend: working agents per model.
        let legendFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        if summary.runningFamilies.isEmpty {
            let text = snapshot.sessions.isEmpty ? "No sessions" : "No agents running"
            Text.draw(Text.make(text, legendFont, .secondaryLabelColor), x: x0, midY: 91)
        } else {
            var lx = x0
            for family in summary.runningFamilies {
                let text = Text.make("\(family.name) \(family.count)", legendFont, .secondaryLabelColor)
                guard lx + 9 + text.size().width <= x1 else { break }
                ctx.setFillColor(palette.model(family.model).color)
                ctx.fillEllipse(in: CGRect(x: lx, y: 88, width: 6, height: 6))
                lx += 9 + Text.draw(text, x: lx + 9, midY: 91) + 8
            }
        }
    }

    // MARK: Panel

    /// Panel layout: a 300 × 318 tile for the iris on the left, the stats column to its right,
    /// and the session table below both.
    private enum PanelLayout {
        static let width: CGFloat = 512
        static let tile = CGRect(x: 9, y: 33, width: 300, height: 318)
        static let column: CGFloat = 319
        static let columnRight: CGFloat = 503
        static let tableTop: CGFloat = 359
        static let rowsTop: CGFloat = 379
        static let rowHeight: CGFloat = 18
        static let maxRows = 9
    }

    func panelSize(for snapshot: ActivitySnapshot) -> CGSize {
        let count = snapshot.sessions.count
        let rows = max(1, min(count, PanelLayout.maxRows))
        let more: CGFloat = count > PanelLayout.maxRows ? 16 : 0
        return CGSize(width: PanelLayout.width, height: PanelLayout.rowsTop + CGFloat(rows) * PanelLayout.rowHeight + more + 8)
    }

    func drawPanel(size: CGSize, context ctx: CGContext, now: Date, snapshot: ActivitySnapshot, mouse: CGPoint?) {
        if panelIris.snapshotTime == nil { ingest(snapshot, now: now); panelIris.layout(dt: 0) }
        let palette = palette()
        let tile = PanelLayout.tile

        // What the mouse is over: a ring or arc in the iris, or a row of the table.
        var hit: (highlight: Highlight, time: Double)?
        var rowHover: Int?
        if let mouse {
            if tile.contains(mouse) {
                hit = panelIris.hit(CGPoint(x: mouse.x - tile.minX, y: mouse.y - tile.minY), now: now)
            } else if mouse.y >= PanelLayout.rowsTop, mouse.x >= tile.minX, mouse.x <= PanelLayout.columnRight {
                let row = Int((mouse.y - PanelLayout.rowsTop) / PanelLayout.rowHeight)
                if row < rowIDs.count { rowHover = row }
            }
        }
        let highlight = hit?.highlight ?? rowHover.map { Highlight(session: rowIDs[$0], agent: nil) }
        panelIris.highlight = highlight

        var hasher = Hasher()
        hasher.combine(summaryTime)
        hasher.combine(palette.dark)
        hasher.combine(size.height)
        let key = hasher.finalize()
        if key != panelChromeKey || panelChrome.image == nil {
            panelChromeKey = key
            panelChrome.render(size: size, matching: ctx) { ctx in
                drawPanelChrome(size: size, ctx: ctx, snapshot: snapshot, palette: palette)
                panelIris.drawFloor(ctx, origin: tile.origin, now: now, palette: palette)
            }
        }
        // The panel's bitmap is empty at this point, so the chrome is copied rather than blended.
        panelChrome.draw(in: ctx, at: .zero, blendMode: .copy)
        // The hovered row, slipped in behind the chrome's text.
        if let id = highlight?.session, let row = rowIDs.firstIndex(of: id) {
            ctx.saveGState()
            ctx.setBlendMode(.destinationOver)
            ctx.setFillColor(palette.ink(0.1))
            let rect = CGRect(x: tile.minX, y: PanelLayout.rowsTop + CGFloat(row) * PanelLayout.rowHeight,
                              width: PanelLayout.columnRight - tile.minX, height: PanelLayout.rowHeight)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        panelIris.draw(in: ctx, origin: tile.origin, now: now, palette: palette)

        // The readout under the iris: what's under the mouse, or the window's time span.
        let readoutKey: String
        let text: () -> NSAttributedString
        if let highlight, let session = snapshot.session(highlight.session) {
            let when = hit.map { h -> String in
                let ago = EyeClock.seconds(now) - h.time
                return ago < 20 ? " · now" : " · −" + ActivityFormat.duration(ago)
            } ?? ""
            if let agentID = highlight.agent, let agent = session.agents.first(where: { $0.id == agentID }) {
                let state: String
                switch agent.state {
                case .generating: state = "generating"
                case .tool: state = "tool"
                case .waiting: state = "waiting"
                case .idle: state = "idle"
                case .finished: state = "done " + ActivityFormat.duration((agent.end ?? snapshot.time).timeIntervalSince(agent.start))
                }
                let bold = session.name + " › " + agent.label
                let rest = " · \(ClaudeModel.name(agent.model)) · \(state) · \(ActivityFormat.tokens(Double(agent.outputTokens))) out" + when
                readoutKey = bold + "\u{1}" + rest
                text = { Text.readout(bold: bold, rest: rest) }
            } else {
                let status = session.isBusy ? "busy" : session.isOpen ? "idle" : "ended"
                let agents = session.runningAgents > 0 ? "\(session.runningAgents)/\(session.agents.count)" : "\(session.agents.count)"
                let rest = " · \(ClaudeModel.name(session.model)) · \(status) · \(agents) agents" + when
                readoutKey = session.name + "\u{1}" + rest
                text = { Text.readout(bold: session.name, rest: rest) }
            }
        } else {
            let f = Text.timeFormatter
            let rest = f.string(from: snapshot.time.addingTimeInterval(-ActivitySnapshot.window)) + " – " + f.string(from: snapshot.time)
                + " · one turn = 30 min"
            readoutKey = "\u{1}" + rest
            text = { Text.readout(bold: "", rest: rest) }
        }
        let fullKey = readoutKey + (palette.dark ? "d" : "l")
        if readout?.key != fullKey { readout = (fullKey, text()) }
        if let readout {
            Text.draw(readout.text, x: tile.minX + 9, midY: tile.maxY - 13.5, maxWidth: tile.width - 18)
        }
    }

    /// Everything in the panel that changes only with the snapshot: header, stats, models and the table.
    private func drawPanelChrome(size: CGSize, ctx: CGContext, snapshot: ActivitySnapshot, palette: Palette) {
        let tile = PanelLayout.tile, col = PanelLayout.column, colRight = PanelLayout.columnRight
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        Text.draw(Text.make("Claude Code Activity", .systemFont(ofSize: 13, weight: .bold), .labelColor), x: 11, midY: 19)
        Text.draw(Text.make("\(snapshot.openSessions) open · \(snapshot.busySessions) busy", digits, .secondaryLabelColor),
                  x: size.width - 11, midY: 19.5, alignRight: true)

        ctx.setFillColor(palette.ink(0.07))
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()

        // Stats column.
        let heading = NSFont.systemFont(ofSize: 11, weight: .semibold)
        Text.draw(Text.make("Agents", heading, .secondaryLabelColor), x: col, midY: 42)
        let bigFont = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
        let small = NSFont.systemFont(ofSize: 10)
        let third = (colRight - col - 20) / 3
        for (i, (value, caption)) in [(snapshot.agentsRunning, "running"), (snapshot.agentsRecent, "last 30 min"),
                                      (snapshot.peakParallel, "peak")].enumerated() {
            let x = col + CGFloat(i) * (third + 10)
            Text.draw(Text.make("\(value)", bigFont, .labelColor, kern: -0.3), x: x, midY: 63)
            Text.draw(Text.make(caption, small, .secondaryLabelColor), x: x, midY: 81)
        }

        Text.draw(Text.make("Tokens · 30 min", heading, .secondaryLabelColor), x: col, midY: 104)
        let rows: [(String, Double)] = [("Output", snapshot.outputTotal), ("Thinking", snapshot.thinkingTotal),
                                        ("Input", snapshot.inputTotal), ("Cache reads", snapshot.cacheReadTotal)]
        let body = NSFont.systemFont(ofSize: 11)
        for (i, (name, value)) in rows.enumerated() {
            let y = 122 + CGFloat(i) * 16
            Text.draw(Text.make(name, body, .labelColor), x: col, midY: y)
            var right = colRight
            if i == 0 {
                right -= Text.draw(Text.make(" · " + ActivityFormat.tokens(snapshot.outputPerMinute) + "/min", digits, .secondaryLabelColor),
                                   x: right, midY: y, alignRight: true)
            }
            Text.draw(Text.make(ActivityFormat.tokens(value), digits, .labelColor), x: right, midY: y, alignRight: true)
        }

        Text.draw(Text.make("Models", heading, .secondaryLabelColor), x: col, midY: 194)
        let models = summary.models.prefix(6)
        if models.isEmpty {
            Text.draw(Text.make("None", body, .tertiaryLabelColor), x: col, midY: 212)
        }
        let maxOut = max(1, models.map(\.output).max() ?? 1)
        for (i, model) in models.enumerated() {
            let y = 212 + CGFloat(i) * 22
            let color = palette.model(model.id).color
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: col, y: y - 3, width: 6, height: 6))
            Text.draw(Text.make(model.name, body, .labelColor), x: col + 9, midY: y)
            let detail = (model.running > 0 ? "\(model.running) running · " : "") + ActivityFormat.tokens(model.output)
            Text.draw(Text.make(detail, digits, .secondaryLabelColor), x: colRight, midY: y, alignRight: true)
            let bar = CGRect(x: col, y: y + 7.5, width: colRight - col, height: 3)
            ctx.setFillColor(palette.ink(0.07))
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.fillPath()
            let fill = CGRect(x: bar.minX, y: bar.minY, width: max(3, bar.width * CGFloat((model.output / maxOut).squareRoot())), height: 3)
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: fill, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.fillPath()
        }

        // Session table, in ring order from the pupil outward.
        ctx.setFillColor(NSColor.separatorColor.cgColor)
        ctx.fill(CGRect(x: tile.minX, y: PanelLayout.tableTop, width: colRight - tile.minX, height: 0.5))
        // Column right edges (the name column is left-aligned after the dot).
        let x0 = tile.minX + 4
        let nameX = x0 + 14, rights: [CGFloat] = [x0 + 274, x0 + 338, x0 + 400, x0 + 446, x0 + 486]
        let headFont = NSFont.systemFont(ofSize: 10)
        Text.draw(Text.make("Session · inner → outer", headFont, .tertiaryLabelColor), x: nameX, midY: 371)
        for (i, title) in ["Model", "Status", "Agents", "Out", "Ctx"].enumerated() {
            Text.draw(Text.make(title, headFont, .tertiaryLabelColor), x: rights[i], midY: 371, alignRight: true)
        }
        let sessions = summary.ringOrder
        rowIDs = sessions.prefix(PanelLayout.maxRows).map(\.id)
        if sessions.isEmpty {
            Text.draw(Text.make("No sessions", body, .tertiaryLabelColor), x: nameX, midY: PanelLayout.rowsTop + 9)
        }
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        for (i, session) in sessions.prefix(PanelLayout.maxRows).enumerated() {
            let y = PanelLayout.rowsTop + CGFloat(i) * PanelLayout.rowHeight + 9
            if !session.isOpen { ctx.setAlpha(0.5) }
            let color = palette.model(session.model).color
            ctx.setFillColor(color.copy(alpha: session.isBusy ? 1 : 0.55)!)
            ctx.fillEllipse(in: CGRect(x: x0, y: y - 3, width: 6, height: 6))
            Text.draw(Text.make(session.name, body, .labelColor), x: nameX, midY: y, maxWidth: rights[0] - 54 - nameX - 6)
            Text.draw(Text.make(ClaudeModel.family(session.model), body, .secondaryLabelColor), x: rights[0], midY: y, alignRight: true)
            if session.isBusy {
                let w = Text.draw(Text.make("busy", body, .labelColor), x: rights[1], midY: y, alignRight: true)
                ctx.setFillColor(palette.accent)
                ctx.fillEllipse(in: CGRect(x: rights[1] - w - 9, y: y - 2.5, width: 5, height: 5))
            } else {
                Text.draw(Text.make(session.isOpen ? "idle" : "ended", body, .secondaryLabelColor), x: rights[1], midY: y, alignRight: true)
            }
            var right = rights[2]
            right -= Text.draw(Text.make("\(session.agents.count)", digits, .secondaryLabelColor), x: right, midY: y, alignRight: true)
            if session.runningAgents > 0 {
                right -= Text.draw(Text.make(" / ", digits, .secondaryLabelColor), x: right, midY: y, alignRight: true)
                Text.draw(Text.make("\(session.runningAgents)", bold, .labelColor), x: right, midY: y, alignRight: true)
            }
            let output = Double(session.threads.reduce(0) { $0 + $1.outputTokens })
            Text.draw(Text.make(ActivityFormat.tokens(output), digits, .secondaryLabelColor), x: rights[3], midY: y, alignRight: true)
            Text.draw(Text.make(ActivityFormat.tokens(Double(session.main.contextTokens)), digits, .secondaryLabelColor),
                      x: rights[4], midY: y, alignRight: true)
            ctx.setAlpha(1)
        }
        if sessions.count > PanelLayout.maxRows {
            let y = PanelLayout.rowsTop + CGFloat(PanelLayout.maxRows) * PanelLayout.rowHeight + 8
            Text.draw(Text.make("+ \(sessions.count - PanelLayout.maxRows) more", headFont, .tertiaryLabelColor), x: nameX, midY: y)
        }
    }
}

// MARK: - Summary

/// Figures derived from a snapshot that both the box and the panel use.
private struct Summary {
    struct Model {
        var id: String
        var name: String
        var running = 0
        var output: Double = 0
    }

    struct Series {
        var model: String
        var values: [Double]
    }

    /// Models by name (IDs that differ only in a date suffix are merged), in family order.
    var models: [Model] = []
    /// Working agents per model family, for the box's legend.
    var runningFamilies: [(name: String, model: String, count: Int)] = []
    /// Working agents per model family in 30 s buckets over the window, for the box's chart.
    var runningSeries: [Series] = []
    /// Sessions newest first: the iris's rings from the pupil outward.
    var ringOrder: [SessionActivity] = []

    static func rank(_ id: String) -> Int {
        ["opus", "fable", "sonnet", "haiku"].firstIndex { id.contains($0) } ?? 4
    }

    init(_ snapshot: ActivitySnapshot) {
        ringOrder = snapshot.sessions.sorted { $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id < $1.id }

        var byName: [String: Model] = [:]
        for (id, output) in snapshot.outputByModel where output > 0 {
            byName[ClaudeModel.name(id), default: Model(id: id, name: ClaudeModel.name(id))].output += output
        }
        var families: [String: (model: String, count: Int)] = [:]
        let buckets = ActivitySnapshot.bucketCount, perPoint = 6
        var series: [String: (model: String, values: [Double])] = [:]
        for session in snapshot.sessions {
            for agent in session.threads {
                let family = ClaudeModel.family(agent.model)
                if agent.kind == .main ? session.isBusy : agent.isRunning {
                    byName[ClaudeModel.name(agent.model), default: Model(id: agent.model, name: ClaudeModel.name(agent.model))].running += 1
                    families[family, default: (agent.model, 0)].count += 1
                }
                // Time working in each 30 s point, as a fraction of the point.
                var entry = series[family] ?? (agent.model, [Double](repeating: 0, count: buckets / perPoint))
                var any = false
                for j in 0..<buckets {
                    let f = agent.workingFraction(inBucket: j, of: snapshot)
                    if f > 0 { entry.values[j / perPoint] += f / Double(perPoint); any = true }
                }
                if any { series[family] = entry }
            }
        }
        models = byName.values.sorted { a, b in
            Self.rank(a.id) != Self.rank(b.id) ? Self.rank(a.id) < Self.rank(b.id) : a.output > b.output
        }
        runningFamilies = families.map { (name: $0.key, model: $0.value.model, count: $0.value.count) }
            .sorted { Self.rank($0.model) != Self.rank($1.model) ? Self.rank($0.model) < Self.rank($1.model) : $0.name < $1.name }
        runningSeries = series.values.filter { $0.values.contains { $0 > 0.01 } }
            .sorted { Self.rank($0.model) < Self.rank($1.model) }
            .map { Series(model: $0.model, values: $0.values) }
    }
}

// MARK: - Iris

/// Local clock time in seconds, so that the hand points straight up on the hour and the half hour.
private enum EyeClock {
    static let turn = ActivitySnapshot.window
    static let offset = Double(TimeZone.current.secondsFromGMT())
    /// A recent multiple of the turn, subtracted from every time so that angles stay small numbers.
    static let epoch: Double = ((Date().timeIntervalSinceReferenceDate + offset) / turn).rounded(.down) * turn

    static func seconds(_ date: Date) -> Double { date.timeIntervalSinceReferenceDate + offset - epoch }
    /// Clockwise from 12 o'clock, in the flipped context's angles.
    static func angle(_ t: Double) -> CGFloat { CGFloat(-Double.pi / 2 + 2 * Double.pi * t / turn) }
    /// Seconds since local midnight.
    static func timeOfDay(_ t: Double) -> Double {
        let s = (t + epoch).truncatingRemainder(dividingBy: 86_400)
        return s < 0 ? s + 86_400 : s
    }
}

/// What the mouse is over in the panel: a session's ring, or one of its subagents' arcs.
private struct Highlight: Hashable {
    var session: String
    var agent: String?
}

/// A cell of a thread's history, aligned to the clock so it stays put as the hand moves.
private struct Cell {
    var start: Double
    var end: Double
    var value: Double
}

/// A session's ring and its animated layout.
private final class Ring {
    let id: String
    var session: SessionActivity
    /// Animated: 0 while a ring is born or dies, 1 when settled.
    var weight: CGFloat = 0
    var main: CGFloat = 0
    var band: CGFloat = 0
    /// Each visible subagent's lane: it keeps the lane it got when it appeared.
    var lanes: [String: Int] = [:]
    var laneCount = 0
    var visible: [AgentActivity] = []
    var dead = false
    var phase: Double
    /// Radii: the ring from r0 to r1, its subagent band from b0 to b1 with lanes `pitch` apart.
    var r0: CGFloat = 0, r1: CGFloat = 0, b0: CGFloat = 0, b1: CGFloat = 0, pitch: CGFloat = 0

    init(_ session: SessionActivity) {
        id = session.id
        self.session = session
        phase = hashPhase(session.id)
    }

    func laneRadius(_ lane: Int) -> CGFloat { b0 + (CGFloat(lane) + 0.5) * pitch }
    func laneWidth(_ lane: CGFloat) -> CGFloat { max(0.6, min(pitch * 0.72, lane * 0.8)) }
}

/// A pulse phase from an ID, so that sparks don't pulse in step.
private func hashPhase(_ id: String) -> Double {
    var h = 0
    for byte in id.utf8 { h = (h &* 31 &+ Int(byte)) & 0x7FFF_FFFF }
    return Double(h % 628) / 100
}

/// Fades with age over the window, to at most 62 %, like a radar's persistence.
private func ageFade(_ age: Double) -> CGFloat {
    CGFloat(1 - 0.62 * pow(max(0, min(1, age / EyeClock.turn)), 1.15))
}

/// The polar heat map, used twice: compact in the box and large in the panel, each with its own layout.
private final class Iris {
    struct Geometry {
        var size: CGSize
        var cx: CGFloat, cy: CGFloat, rOut: CGFloat, rPupil: CGFloat
        /// A busy session's ring thickness, a subagent lane's, and the most lanes before the band is squeezed.
        var main: CGFloat, lane: CGFloat, maxLanes: Int
        var gap: CGFloat
        /// Seconds per cell: a multiple of the snapshot's 5 s buckets.
        var cell: Double
        /// A gap of this many seconds just ahead of the hand, between the newest and the oldest data.
        var lead: Double
        var cellGap: CGFloat, tickWidth: CGFloat, handWidth: CGFloat
        /// Output tokens per cell that count as full brightness (log scale).
        var outRef: Double
        var ticks: Bool

        static let box = Geometry(size: CGSize(width: 104, height: 104), cx: 52, cy: 52, rOut: 46.5, rPupil: 9, main: 5, lane: 1.6,
                                  maxLanes: 6, gap: 1.2, cell: 30, lead: 25, cellGap: 0.6, tickWidth: 0.6, handWidth: 1.1,
                                  outRef: 1500, ticks: false)
        static let panel = Geometry(size: CGSize(width: 300, height: 300), cx: 150, cy: 148, rOut: 118, rPupil: 22, main: 11, lane: 3,
                                    maxLanes: 9, gap: 2.5, cell: 15, lead: 20, cellGap: 0.9, tickWidth: 0.8, handWidth: 1.4,
                                    outRef: 900, ticks: true)
    }

    let g: Geometry
    var highlight: Highlight?
    private(set) var snapshotTime: Date?
    private var rings: [String: Ring] = [:]
    /// Rings from the pupil outward (newest session first), including dying ones.
    private var order: [Ring] = []
    private var initialized = false
    private var fit: CGFloat?
    private var pupilWidth: CGFloat = 0
    private var flashes: [(id: String, start: Double)] = []
    private var dataEnd: Double = 0
    private var mainCells: [String: [Cell]] = [:]
    private var agentCells: [String: [Cell]] = [:]
    private var threadsActive = 0
    private let image = Offscreen()
    private var imageKey: (data: Int?, layout: Int?) = (nil, nil)
    private var imageTime: Double = -.infinity
    private var labels: [String: NSAttributedString] = [:]
    private var nowLabel: (dark: Bool, text: NSAttributedString)?
    /// The radar sweep's wedges behind a hand at angle 0, rotated into place each frame.
    private lazy var wedges: [CGPath] = (0..<10).map { i in
        let path = CGMutablePath()
        addSector(path, center: .zero, r0: g.rPupil + 1, r1: g.rOut + 1, a0: -0.05 * CGFloat(i + 1), a1: -0.05 * CGFloat(i))
        return path
    }

    init(geometry: Geometry) {
        g = geometry
    }

    func reset() {
        rings = [:]
        order = []
        initialized = false
        fit = nil
        flashes = []
        snapshotTime = nil
        imageKey = (nil, nil)
    }

    // MARK: Data

    func ingest(_ snapshot: ActivitySnapshot, now: Date) {
        let nowT = EyeClock.seconds(now)
        let oldest = nowT - EyeClock.turn + g.lead
        var present = Set<String>()
        for session in snapshot.sessions {
            present.insert(session.id)
            let ring: Ring
            if let existing = rings[session.id] {
                ring = existing
            } else {
                ring = Ring(session)
                ring.r0 = g.rPupil + 2
                ring.r1 = ring.r0
                rings[session.id] = ring
                if session.startedAt > now.addingTimeInterval(-5) { flashes.append((session.id, nowT)) }
            }
            ring.session = session
            ring.dead = false
            assignLanes(ring, oldest: oldest, now: nowT)
        }
        for ring in rings.values where !present.contains(ring.id) { ring.dead = true }
        order = rings.values.sorted {
            $0.session.startedAt != $1.session.startedAt ? $0.session.startedAt > $1.session.startedAt : $0.id < $1.id
        }

        dataEnd = EyeClock.seconds(snapshot.time)
        mainCells.removeAll(keepingCapacity: true)
        agentCells.removeAll(keepingCapacity: true)
        threadsActive = 0
        for ring in order where !ring.dead {
            mainCells[ring.id] = cells(ring.session.main, agent: false)
            for agent in ring.visible { agentCells[agent.id] = cells(agent, agent: true) }
            let main = ring.session.main.state
            if ring.session.isOpen, main == .generating || main == .tool || main == .waiting { threadsActive += 1 }
            threadsActive += ring.session.agents.filter { $0.isRunning && $0.state != .idle }.count
        }
        snapshotTime = snapshot.time
    }

    /// Lanes: each subagent keeps the lane it got when it appeared; a lane is free again once its agents
    /// have left the window.
    private func assignLanes(_ ring: Ring, oldest: Double, now: Double) {
        let visible = ring.session.agents
            .filter { agent in agent.end.map { EyeClock.seconds($0) > oldest } ?? true }
            .sorted { $0.start < $1.start }
        let ids = Set(visible.map(\.id))
        ring.lanes = ring.lanes.filter { ids.contains($0.key) }
        var byLane: [Int: [AgentActivity]] = [:]
        for agent in visible { if let lane = ring.lanes[agent.id] { byLane[lane, default: []].append(agent) } }
        for agent in visible where ring.lanes[agent.id] == nil {
            let start = EyeClock.seconds(agent.start)
            var lane = 0
            while (byLane[lane] ?? []).contains(where: { ($0.end.map(EyeClock.seconds) ?? now) + 4 > start }) { lane += 1 }
            ring.lanes[agent.id] = lane
            byLane[lane, default: []].append(agent)
        }
        ring.visible = visible
        ring.laneCount = (ring.lanes.values.max() ?? -1) + 1
    }

    /// A thread's activity in clock-aligned cells. The snapshot's buckets end at the snapshot time, so each is
    /// split between the cells it overlaps; that keeps the cells still while the snapshots move on.
    private func cells(_ thread: AgentActivity, agent: Bool) -> [Cell] {
        let n = thread.buckets.count
        guard n > 0 else { return [] }
        let bucket = ActivitySnapshot.bucketSeconds, cell = g.cell
        let start = dataEnd - Double(n) * bucket
        let k0 = Int((start / cell).rounded(.down))
        let count = Int((dataEnd / cell).rounded(.down)) - k0 + 1
        var gen = [Double](repeating: 0, count: count), tool = gen, out = gen
        var any = false
        for (i, b) in thread.buckets.enumerated() where b.generating > 0 || b.tool > 0 || b.output > 0 {
            any = true
            let s = start + Double(i) * bucket
            let k = Int((s / cell).rounded(.down))
            let boundary = Double(k + 1) * cell
            let f = s + bucket <= boundary ? 1 : (boundary - s) / bucket
            let j = min(count - 1, max(0, k - k0))
            gen[j] += b.generating * f; tool[j] += b.tool * f; out[j] += b.output * f
            if f < 1, j + 1 < count {
                gen[j + 1] += b.generating * (1 - f); tool[j + 1] += b.tool * (1 - f); out[j + 1] += b.output * (1 - f)
            }
        }
        guard any else { return [] }
        var result: [Cell] = []
        let logRef = log1p(g.outRef)
        for j in 0..<count {
            let c0 = Double(k0 + j) * cell, c1 = c0 + cell
            let covered = min(c1, dataEnd) - max(c0, start)
            guard covered > 0.5 else { continue }
            let value: Double
            if agent {
                value = min(1, (gen[j] + 0.6 * tool[j]) / covered)
                guard value >= 0.05 else { continue }
            } else {
                let act = min(1, (gen[j] + 0.7 * tool[j]) / covered)
                let tok = min(1, log1p(out[j] * cell / max(covered, cell / 3)) / logRef)
                value = min(1, 0.6 * act + 0.5 * tok)
                guard value >= 0.02 else { continue }
            }
            result.append(Cell(start: c0, end: c1, value: value))
        }
        return result
    }

    // MARK: Layout

    private func ease(_ value: CGFloat, to target: CGFloat, _ k: CGFloat) -> CGFloat {
        let next = value + (target - value) * k
        return abs(target - next) < 0.004 ? target : next
    }

    /// Animates each ring toward its thickness: new rings grow from the pupil, closed ones shrink and go.
    func layout(dt: Double) {
        let k = CGFloat(1 - exp(-dt * 5))
        for ring in order {
            if ring.dead {
                ring.weight = ease(ring.weight, to: 0, k)
                continue
            }
            let s = ring.session
            let mainTarget = g.main * (s.isBusy ? 1 : s.isOpen ? 0.78 : 0.45)
            let bandTarget = ring.laneCount > 0 ? CGFloat(min(ring.laneCount, g.maxLanes)) * g.lane + g.lane * 0.6 : 0
            if !initialized {
                ring.main = mainTarget
                ring.band = bandTarget
                ring.weight = 1
            }
            ring.main = ease(ring.main, to: mainTarget, k)
            ring.band = ease(ring.band, to: bandTarget, k)
            ring.weight = ease(ring.weight, to: 1, k * 0.8)
        }
        initialized = true
        if order.contains(where: { $0.dead && $0.weight < 0.01 }) {
            for ring in order where ring.dead && ring.weight < 0.01 { rings[ring.id] = nil }
            order.removeAll { $0.dead && $0.weight < 0.01 }
        }

        // Fit: when the rings would overflow the iris, squeeze the subagent bands first (down to 40 %),
        // then scale everything. With few sessions, thicker rings and bigger cells.
        let available = g.rOut - g.rPupil - 2
        var fixed: CGFloat = 0, bands: CGFloat = 0
        for ring in order {
            fixed += ring.weight * (ring.main + g.gap)
            bands += ring.weight * ring.band
        }
        var bandScale: CGFloat = 1, scale: CGFloat = 1
        if fixed + bands > available {
            bandScale = bands > 0 ? max(0.4, (available - fixed) / bands) : 1
            if fixed + bands * bandScale > available { scale = available / (fixed + bands * bandScale) }
        } else if fixed + bands > 0 {
            scale = max(1, min(1.7, available * 0.8 / (fixed + bands)))
        }
        // The scale eases too, so a new session reflows smoothly; it never lags behind while shrinking.
        var eased = fit.map { ease($0, to: scale, k) } ?? scale
        if scale < eased { eased = scale }
        fit = eased
        scale = eased

        var radius = g.rPupil + 2
        for ring in order {
            let main = ring.main * ring.weight * scale, band = ring.band * bandScale * ring.weight * scale
            ring.r0 = radius
            ring.r1 = radius + main
            ring.b0 = ring.r1 + 0.6 * scale
            ring.b1 = ring.r1 + band
            ring.pitch = ring.laneCount > 0
                ? max(0.35, (band - g.lane * 0.6 * bandScale * scale) / CGFloat(max(1, ring.laneCount))) : 0
            radius += main + band + g.gap * ring.weight * scale
        }

        // The pupil dilates with the number of threads at work.
        let target = min(g.rPupil * 0.34, g.rPupil * 0.1 + g.rPupil * 0.06 * CGFloat(Double(threadsActive).squareRoot()))
        pupilWidth += (target - pupilWidth) * CGFloat(1 - exp(-dt * 3))
    }

    // MARK: Drawing

    /// Draws the iris with its canvas's top left at `origin`.
    func draw(in ctx: CGContext, origin: CGPoint, now: Date, palette: Palette) {
        let nowT = EyeClock.seconds(now)
        var data = Hasher(), layout = Hasher()
        data.combine(snapshotTime)
        data.combine(palette.dark)
        data.combine(highlight)
        for ring in order {
            data.combine(ring.id)
            for v in [ring.r0, ring.r1, ring.b1, ring.pitch, ring.weight] { layout.combine(Int((v * 20).rounded())) }
        }
        let dataKey = data.finalize(), layoutKey = layout.finalize()
        // Redrawn at once when the data or the highlight changes. While the rings move, at most 24 times a second
        // (a redraw costs a few milliseconds with many sessions), and every couple of seconds for the age fade.
        let due = dataKey != imageKey.data || nowT - imageTime > 2 || image.image == nil
            || layoutKey != imageKey.layout && nowT - imageTime >= 1 / 24.0
        if due {
            imageKey = (dataKey, layoutKey)
            imageTime = nowT
            image.render(size: g.size, matching: ctx) { ctx in drawStatic(ctx, now: nowT, palette: palette) }
        }

        let dark = palette.dark
        let center = CGPoint(x: g.cx, y: g.cy)
        let hand = EyeClock.angle(nowT)
        let quiet = !order.contains { !$0.dead && $0.session.isOpen }
        let time = now.timeIntervalSinceReferenceDate
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)

        // Radar sweep behind the hand: wedges of decreasing alpha, under everything else.
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: hand)
        for (i, wedge) in wedges.enumerated() {
            let alpha = (dark ? 0.085 : 0.06) * pow(1 - CGFloat(i) / 10, 1.6) * (quiet ? 0.5 : 1)
            ctx.setFillColor(palette.accent.copy(alpha: alpha)!)
            ctx.addPath(wedge)
            ctx.fillPath()
        }
        ctx.restoreGState()

        image.draw(in: ctx, at: .zero)

        // The hand, under the sparks that ride it.
        ctx.setStrokeColor(palette.accent.copy(alpha: dark ? 0.95 : 0.9)!)
        ctx.setLineWidth(g.handWidth)
        ctx.setLineCap(.round)
        ctx.move(to: point(center, g.rPupil + 1, hand))
        ctx.addLine(to: point(center, g.rOut + 1.5, hand))
        ctx.strokePath()
        ctx.setLineCap(.butt)

        // Sparks at the hand: the main thread while it generates or runs a tool, and each running subagent.
        for ring in order where !ring.dead && ring.r1 - ring.r0 >= 0.3 {
            let s = ring.session
            let dim: CGFloat = highlight.map { $0.session == s.id ? 1 : 0.3 } ?? 1
            let state = s.main.state
            if s.isOpen, state == .generating || state == .tool {
                let pulse = state == .generating ? 0.8 + 0.2 * sin(time / 0.12 + ring.phase) : 0.7
                let r = (ring.r0 + ring.r1) / 2
                glowDot(ctx, at: point(center, r, hand), radius: max(1.3, (ring.r1 - ring.r0) * 0.45),
                        color: palette.model(s.model), alpha: CGFloat(pulse) * dim, palette: palette)
            }
            guard ring.laneCount > 0, ring.pitch > 0 else { continue }
            let lw = ring.laneWidth(g.lane)
            for agent in ring.visible where agent.isRunning {
                guard let lane = ring.lanes[agent.id] else { continue }
                let agentDim = highlight?.agent.map { $0 == agent.id ? dim : dim * 0.45 } ?? dim
                let pulse = agent.state == .generating ? 0.75 + 0.25 * sin(time / 0.14 + hashPhase(agent.id))
                    : agent.state == .tool ? 0.7 : 0.45
                glowDot(ctx, at: point(center, ring.laneRadius(lane), hand), radius: max(0.9, lw * 0.85),
                        color: palette.model(agent.model), alpha: CGFloat(pulse) * agentDim, palette: palette)
            }
        }

        // A ripple where a new session was born.
        flashes.removeAll { nowT - $0.start > 1.4 }
        for flash in flashes {
            guard let ring = rings[flash.id] else { continue }
            let p = CGFloat((nowT - flash.start) / 1.4)
            ctx.setStrokeColor(palette.accent.copy(alpha: 0.6 * (1 - p))!)
            ctx.setLineWidth(1 + 2 * (1 - p))
            ctx.strokeEllipse(in: circle(center, (ring.r0 + ring.r1) / 2 + p * g.rOut * 0.25))
        }

        // A bead that travels out along the hand every two seconds: motion even when nothing changes.
        if !quiet {
            let phase = time.truncatingRemainder(dividingBy: 2) / 2
            let r = g.rPupil + 2 + CGFloat(phase) * (g.rOut - g.rPupil - 2)
            glowDot(ctx, at: point(center, r, hand), radius: g.handWidth * 1.1, color: (key: 0, color: palette.accent),
                    alpha: 0.8 * CGFloat(sin(phase * .pi)), palette: palette)
        }

        // The slit pupil, pointed at both ends like the dragon's.
        let ry = g.rPupil * 0.98, rx = max(0.8, pupilWidth)
        let slit = CGMutablePath()
        slit.move(to: CGPoint(x: center.x, y: center.y - ry))
        slit.addQuadCurve(to: CGPoint(x: center.x, y: center.y + ry), control: CGPoint(x: center.x + 2 * rx, y: center.y))
        slit.addQuadCurve(to: CGPoint(x: center.x, y: center.y - ry), control: CGPoint(x: center.x - 2 * rx, y: center.y))
        slit.closeSubpath()
        ctx.setFillColor(dark ? CGColor(srgbRed: 8 / 255, green: 8 / 255, blue: 10 / 255, alpha: 0.92)
                              : CGColor(srgbRed: 30 / 255, green: 20 / 255, blue: 16 / 255, alpha: 0.86))
        ctx.addPath(slit)
        ctx.fillPath()
        ctx.setStrokeColor(palette.accent.copy(alpha: dark ? 0.7 : 0.55)!)
        ctx.setLineWidth(g.handWidth * 0.6)
        ctx.setLineJoin(.round)
        ctx.addPath(slit)
        ctx.strokePath()

        if g.ticks {
            if nowLabel?.dark != dark {
                nowLabel = (dark, Text.make("now", .systemFont(ofSize: 9.5, weight: .semibold), NSColor.claude))
            }
            if let text = nowLabel?.text {
                let size = text.size()
                let p = point(center, g.rOut + 9 + abs(cos(hand)) * size.width / 2 + abs(sin(hand)) * size.height / 2.6, hand)
                text.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2))
            }
        }
        ctx.restoreGState()
    }

    /// The parts that change only with the appearance and the clock: a faint warm wash, the limbus, the ticks
    /// and the pupil's well. The design draws them into its chrome bitmap, under the sweep, with the iris's
    /// canvas at `origin`. (Gradients are costly to draw, so they stay out of the bitmap that follows the layout.)
    func drawFloor(_ ctx: CGContext, origin: CGPoint, now: Date, palette: Palette) {
        let dark = palette.dark
        let accent = palette.accent
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        let center = CGPoint(x: g.cx, y: g.cy)
        if let wash = CGGradient(colorsSpace: nil, colors: [accent.copy(alpha: dark ? 0.16 : 0.10)!, accent.copy(alpha: dark ? 0.05 : 0.035)!,
                                                             accent.copy(alpha: 0)!] as CFArray, locations: [0, 0.35, 1]) {
            ctx.drawRadialGradient(wash, startCenter: center, startRadius: g.rPupil * 0.5, endCenter: center, endRadius: g.rOut + 2,
                                   options: [.drawsBeforeStartLocation])
        }
        ctx.setStrokeColor(palette.ink(dark ? 0.12 : 0.1))
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: circle(center, g.rOut + 1.5))
        if g.ticks { drawTicks(ctx, now: EyeClock.seconds(now), palette: palette) }
        let black = CGColor(gray: 0, alpha: 1)
        if let well = CGGradient(colorsSpace: nil, colors: [black.copy(alpha: dark ? 0.35 : 0.06)!, black.copy(alpha: 0)!] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawRadialGradient(well, startCenter: center, startRadius: 0, endCenter: center, endRadius: g.rPupil + 1, options: [])
        }
        ctx.restoreGState()
    }

    /// Everything that changes with the data or the layout: the rings' tracks and cells, and the subagents' arcs.
    private func drawStatic(_ ctx: CGContext, now: Double, palette: Palette) {
        let dark = palette.dark
        let center = CGPoint(x: g.cx, y: g.cy)
        let oldest = now - EyeClock.turn + g.lead
        let base: CGFloat = dark ? 0.1 : 0.14, gain: CGFloat = dark ? 0.9 : 0.86
        var cells = Batch(), bloom = Batch()
        for ring in order where !ring.dead && ring.r1 - ring.r0 >= 0.3 {
            let s = ring.session
            let dim: CGFloat = highlight.map { $0.session == s.id ? 1 : 0.3 } ?? 1
            let color = palette.model(s.model)
            let sStart = max(EyeClock.seconds(s.startedAt), oldest)
            let sEnd = s.endedAt.map { min(EyeClock.seconds($0), now) } ?? now
            // The track: the session's lifetime in the window.
            // (Filled rather than stroked: stroking wide arcs is several times slower.)
            if sEnd > sStart {
                ctx.setFillColor(palette.ink((dark ? 0.06 : 0.042) * dim))
                let path = CGMutablePath()
                addSector(path, center: center, r0: ring.r0, r1: ring.r1, a0: EyeClock.angle(sStart), a1: EyeClock.angle(sEnd))
                ctx.addPath(path)
                ctx.fillPath()
            }
            // The main thread's cells.
            for cell in mainCells[s.id] ?? [] {
                let t0 = max(cell.start, sStart), t1 = min(cell.end, sEnd, dataEnd)
                guard t1 > t0 else { continue }
                let v = CGFloat(cell.value)
                let age = now - t1
                let lit = CGFloat(exp(-age / 30))
                let alpha = dim * ageFade(age) * min(1, base + gain * v + 0.35 * lit * v)
                var a0 = EyeClock.angle(t0), a1 = EyeClock.angle(t1)
                let gap = g.cellGap / ring.r1
                if a1 - a0 > gap * 2.5 { a0 += gap / 2; a1 -= gap / 2 }
                if let path = cells.path(color, alpha: alpha) {
                    addCell(path, center: center, r0: ring.r0, r1: ring.r1, a0: a0, a1: a1)
                }
                // Bloom in the dark: a slightly larger, faint copy.
                if dark, v > 0.55, let path = bloom.path(color, alpha: 0.22 * (v - 0.55) / 0.45 * alpha) {
                    addCell(path, center: center, r0: ring.r0 - 0.8, r1: ring.r1 + 0.8, a0: a0 - 0.6 / ring.r1, a1: a1 + 0.6 / ring.r1)
                }
            }
        }
        cells.fill(ctx)
        bloom.fill(ctx)

        // Subagents: thin arcs on lanes outside their session's ring, with a spawn tick from the parent.
        for ring in order where !ring.dead && ring.r1 - ring.r0 >= 0.3 && ring.laneCount > 0 && ring.pitch > 0 {
            let dim: CGFloat = highlight.map { $0.session == ring.id ? 1 : 0.3 } ?? 1
            let lw = ring.laneWidth(g.lane)
            var ticks = Batch(), faint = Batch(), bright = Batch()
            for agent in ring.visible {
                guard let lane = ring.lanes[agent.id] else { continue }
                let rr = ring.laneRadius(lane)
                let agentDim = highlight?.agent.map { $0 == agent.id ? dim : dim * 0.45 } ?? dim
                let start = EyeClock.seconds(agent.start)
                let t0 = max(start, oldest), t1 = agent.end.map(EyeClock.seconds) ?? now
                guard t1 > t0 else { continue }
                let color = palette.model(agent.model)
                let running = agent.isRunning
                if start >= oldest {
                    let pr = agent.parentID.flatMap { ring.lanes[$0] }.map(ring.laneRadius) ?? ring.r1
                    let alpha = (dark ? 0.55 : 0.6) * agentDim * ageFade(now - start)
                    if let path = ticks.path(color, alpha: alpha) {
                        let a = EyeClock.angle(start), half = g.tickWidth / 2 / rr
                        addCell(path, center: center, r0: min(pr, rr), r1: max(pr, rr), a0: a - half, a1: a + half)
                    }
                }
                // The agent's whole life faintly, then brighter where it was generating or calling tools.
                let faintAlpha = (running ? (dark ? 0.32 : 0.3) : (dark ? 0.2 : 0.22)) * agentDim * ageFade(now - t1)
                if let path = faint.path(color, alpha: faintAlpha) {
                    addCell(path, center: center, r0: rr - lw / 2, r1: rr + lw / 2, a0: EyeClock.angle(t0), a1: EyeClock.angle(t1))
                }
                for cell in agentCells[agent.id] ?? [] {
                    let s0 = max(cell.start, t0), s1 = min(cell.end, t1, dataEnd)
                    guard s1 > s0 else { continue }
                    let alpha = agentDim * ageFade(now - s1) * (0.25 + 0.75 * CGFloat(cell.value)) * (running ? 1 : 0.8)
                    if let path = bright.path(color, alpha: alpha) {
                        addCell(path, center: center, r0: rr - lw / 2, r1: rr + lw / 2, a0: EyeClock.angle(s0), a1: EyeClock.angle(s1))
                    }
                }
            }
            ticks.fill(ctx)
            faint.fill(ctx)
            bright.fill(ctx)
        }

    }

    /// Ticks every 5 minutes outside the limbus, with clock times on the 10-minute ones.
    private func drawTicks(_ ctx: CGContext, now: Double, palette: Palette) {
        let center = CGPoint(x: g.cx, y: g.cy)
        let step = 300.0
        let first = ((now - EyeClock.turn + g.lead) / step).rounded(.up) * step
        var t = first
        while t <= now {
            let angle = EyeClock.angle(t)
            let major = Int((EyeClock.timeOfDay(t) / step).rounded()) % 2 == 0
            ctx.setStrokeColor(palette.ink(major ? 0.3 : 0.18))
            ctx.setLineWidth(1)
            ctx.move(to: point(center, g.rOut + 3, angle))
            ctx.addLine(to: point(center, g.rOut + (major ? 7 : 5), angle))
            ctx.strokePath()
            // Skip labels that would collide with "now", on either side of the hand.
            if major, now - t > 70, t - (now - EyeClock.turn) > 70 {
                let string = Text.clock(EyeClock.timeOfDay(t))
                let key = string + (palette.dark ? "d" : "l")
                let text = labels[key] ?? Text.make(string, .systemFont(ofSize: 9.5, weight: .medium), NSColor(cgColor: palette.ink(0.45)) ?? .secondaryLabelColor)
                labels[key] = text
                // Far enough out that the label's nearest edge clears the tick, whatever the angle.
                let size = text.size()
                let r = g.rOut + 9 + abs(cos(angle)) * size.width / 2 + abs(sin(angle)) * size.height / 2.6
                let p = point(center, r, angle)
                text.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2))
            }
            t += step
        }
    }

    // MARK: Hit testing

    /// The session ring or subagent arc at `p` (in the canvas), and the time there.
    func hit(_ p: CGPoint, now: Date) -> (highlight: Highlight, time: Double)? {
        let dx = p.x - g.cx, dy = p.y - g.cy, radius = (dx * dx + dy * dy).squareRoot()
        guard radius <= g.rOut + 2, radius >= g.rPupil else { return nil }
        let nowT = EyeClock.seconds(now)
        var angle = Double(atan2(dy, dx)) + .pi / 2  // 0 at 12 o'clock, clockwise
        angle = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if angle < 0 { angle += 2 * .pi }
        var handAngle = nowT.truncatingRemainder(dividingBy: EyeClock.turn) / EyeClock.turn * 2 * .pi
        if handAngle < 0 { handAngle += 2 * .pi }
        var back = handAngle - angle
        if back < 0 { back += 2 * .pi }
        let t = nowT - back / (2 * .pi) * EyeClock.turn
        for ring in order where !ring.dead {
            if radius >= ring.r0 - 0.5, radius <= ring.r1 + 0.3 { return (Highlight(session: ring.id), t) }
            if ring.laneCount > 0, ring.pitch > 0, radius > ring.r1, radius <= ring.b1 + 0.5 {
                let lane = Int(((radius - ring.b0) / ring.pitch).rounded(.down))
                for agent in ring.visible where ring.lanes[agent.id] == lane {
                    let end = agent.end.map(EyeClock.seconds) ?? nowT
                    if t >= EyeClock.seconds(agent.start) - 3, t <= end + 3 { return (Highlight(session: ring.id, agent: agent.id), t) }
                }
                return (Highlight(session: ring.id), t)
            }
        }
        return nil
    }
}

// MARK: - Drawing helpers

private func point(_ c: CGPoint, _ r: CGFloat, _ angle: CGFloat) -> CGPoint {
    CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
}

private func circle(_ c: CGPoint, _ r: CGFloat) -> CGRect {
    CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
}

/// An annular sector, clockwise from a0 to a1 in the flipped context.
private func addSector(_ path: CGMutablePath, center: CGPoint, r0: CGFloat, r1: CGFloat, a0: CGFloat, a1: CGFloat) {
    path.move(to: point(center, r1, a0))
    path.addArc(center: center, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
    path.addArc(center: center, radius: max(0, r0), startAngle: a1, endAngle: a0, clockwise: true)
    path.closeSubpath()
}

/// A cell: a sector, or for narrow ones a quadrilateral, which is much cheaper to fill and looks the same.
private func addCell(_ path: CGMutablePath, center: CGPoint, r0: CGFloat, r1: CGFloat, a0: CGFloat, a1: CGFloat) {
    guard a1 - a0 < 0.12 else { return addSector(path, center: center, r0: r0, r1: r1, a0: a0, a1: a1) }
    let c0 = cos(a0), s0 = sin(a0), c1 = cos(a1), s1 = sin(a1)
    path.move(to: CGPoint(x: center.x + c0 * r1, y: center.y + s0 * r1))
    path.addLine(to: CGPoint(x: center.x + c1 * r1, y: center.y + s1 * r1))
    path.addLine(to: CGPoint(x: center.x + c1 * r0, y: center.y + s1 * r0))
    path.addLine(to: CGPoint(x: center.x + c0 * r0, y: center.y + s0 * r0))
    path.closeSubpath()
}

/// A dot with a soft halo. The halo is a prerendered sprite (much cheaper than a gradient per dot), added
/// with plus-lighter in the dark so it glows, and drawn normally at a lower alpha in the light.
private func glowDot(_ ctx: CGContext, at p: CGPoint, radius r: CGFloat, color: (key: Int, color: CGColor), alpha a: CGFloat,
                     palette: Palette) {
    guard a > 0.01 else { return }
    let dark = palette.dark
    let halo = r * (dark ? 3.4 : 2.6)
    ctx.saveGState()
    ctx.setAlpha((dark ? 0.55 : 0.4) * a)
    if dark { ctx.setBlendMode(.plusLighter) }
    ctx.draw(palette.sprite(color), in: circle(p, halo))
    ctx.restoreGState()
    ctx.setFillColor(color.color.copy(alpha: min(1, a))!)
    ctx.fillEllipse(in: circle(p, r))
    if dark {
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85 * min(1, a)))
        ctx.fillEllipse(in: circle(p, r * 0.45))
    }
}

/// Paths grouped by color and (quantized) alpha, so that hundreds of cells take a few dozen fills.
private struct Batch {
    /// Alpha steps of about 4 %: invisible, and each step costs a fill.
    static let levels: CGFloat = 24
    private var paths: [Int: (color: CGColor, alpha: CGFloat, path: CGMutablePath)] = [:]
    private var keys: [Int] = []

    mutating func path(_ color: (key: Int, color: CGColor), alpha: CGFloat) -> CGMutablePath? {
        let level = Int((min(1, alpha) * Self.levels).rounded())
        guard level > 0 else { return nil }
        let key = color.key << 7 | level
        if let entry = paths[key] { return entry.path }
        let path = CGMutablePath()
        paths[key] = (color.color, CGFloat(level) / Self.levels, path)
        keys.append(key)
        return path
    }

    func fill(_ ctx: CGContext) {
        for key in keys {
            guard let entry = paths[key] else { continue }
            ctx.setFillColor(entry.color.copy(alpha: entry.alpha)!)
            ctx.addPath(entry.path)
            ctx.fillPath()
        }
    }
}

/// Colors resolved for one appearance, with a small key per color for `Batch`, and the glow sprites.
private final class Palette {
    let dark: Bool
    let label: CGColor
    let accent: CGColor
    private var models: [String: (key: Int, color: CGColor)] = [:]
    private var families: [String: Int] = [:]
    private var sprites: [Int: CGImage] = [:]

    /// Made while the appearance is current, so the semantic colors resolve for it.
    init(dark: Bool) {
        self.dark = dark
        label = NSColor.labelColor.cgColor
        accent = NSColor.claude.cgColor
    }

    /// labelColor's ink (black or white) at an alpha.
    func ink(_ alpha: CGFloat) -> CGColor { label.copy(alpha: alpha)! }

    func model(_ id: String) -> (key: Int, color: CGColor) {
        if let entry = models[id] { return entry }
        let family = ClaudeModel.family(id)
        let key: Int
        if let existing = families[family] {
            key = existing
        } else {
            key = families.count + 1  // 0 is the accent
            families[family] = key
        }
        let entry = (key, ClaudeModel.color(id).usingColorSpace(.sRGB)?.cgColor ?? ClaudeModel.color(id).cgColor)
        models[id] = entry
        return entry
    }

    /// A radial falloff in `color`, from opaque at the center to clear at the edge.
    func sprite(_ color: (key: Int, color: CGColor)) -> CGImage {
        if let sprite = sprites[color.key] { return sprite }
        let size = 64
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let c = CGPoint(x: Double(size) / 2, y: Double(size) / 2)
        let gradient = CGGradient(colorsSpace: nil, colors: [color.color.copy(alpha: 1)!, color.color.copy(alpha: 0)!] as CFArray,
                                  locations: [0, 1])!
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2, options: [])
        let image = ctx.makeImage()!
        sprites[color.key] = image
        return image
    }
}

/// An offscreen bitmap for parts of the drawing that change only now and then, blitted every frame.
private final class Offscreen {
    private var context: CGContext?
    private(set) var image: CGImage?
    private var size = CGSize.zero

    /// Draws with `draw` into a flipped bitmap of `size` points, at the resolution and color space of `target`.
    func render(size: CGSize, matching target: CGContext, draw: (CGContext) -> Void) {
        let scale = max(1, (target.ctm.a * target.ctm.a + target.ctm.b * target.ctm.b).squareRoot())
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        let space = target.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        image = nil  // so the context's memory isn't copied on write
        if context?.width != width || context?.height != height || context?.colorSpace != space {
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.translateBy(x: 0, y: CGFloat(height))
            context?.scaleBy(x: scale, y: -scale)
        }
        guard let context else { return }
        self.size = size
        context.clear(CGRect(origin: .zero, size: size))
        context.saveGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        image = context.makeImage()
    }

    /// Draws the bitmap with its top left at `origin` in a flipped context.
    func draw(in ctx: CGContext, at origin: CGPoint, blendMode: CGBlendMode = .normal) {
        guard let image else { return }
        ctx.saveGState()
        ctx.setBlendMode(blendMode)
        ctx.translateBy(x: origin.x, y: origin.y + size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()
    }
}

/// Text for the flipped contexts the design draws in.
private enum Text {
    static func make(_ string: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if kern != 0 { attributes[.kern] = kern }
        return NSAttributedString(string: string, attributes: attributes)
    }

    /// Draws one line vertically centered on `midY`, starting at `x` (or ending there), and returns its width.
    @discardableResult
    static func draw(_ text: NSAttributedString, x: CGFloat, midY: CGFloat, alignRight: Bool = false,
                     maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let size = text.size()
        let width = min(size.width, maxWidth)
        let rect = CGRect(x: alignRight ? x - width : x, y: Drawing.pixelAligned(midY - size.height / 2), width: width, height: size.height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return width
    }

    /// Draws one line with its baseline at `baseline`, and returns its width.
    @discardableResult
    static func draw(_ text: NSAttributedString, x: CGFloat, baseline: CGFloat) -> CGFloat {
        let size = text.size()
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 11)
        text.draw(with: CGRect(x: x, y: baseline - font.ascender, width: size.width, height: size.height),
                  options: [.usesLineFragmentOrigin])
        return size.width
    }

    /// The panel's readout: a bold name, then details in secondary color.
    static func readout(bold: String, rest: String) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: make(bold, .systemFont(ofSize: 10.5, weight: .semibold), .labelColor))
        result.append(make(rest, .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .secondaryLabelColor))
        return result
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static let uses24Hours = !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "a").contains("a")

    /// "12:10", without AM or PM, for the ticks.
    static func clock(_ secondsOfDay: Double) -> String {
        let minutes = Int(secondsOfDay.rounded()) / 60
        var hour = (minutes / 60) % 24
        if !uses24Hours { hour = hour % 12 == 0 ? 12 : hour % 12 }
        return String(format: uses24Hours ? "%02d:%02d" : "%d:%02d", hour, minutes % 60)
    }
}
