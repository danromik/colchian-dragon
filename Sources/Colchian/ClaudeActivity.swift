import AppKit

// MARK: - Snapshot

/// Activity in one time bucket of an agent's history.
struct ActivityBucket {
    /// Output tokens produced in the bucket (thinking included).
    var output: Double = 0
    /// Input tokens read in the bucket, cache reads and writes included.
    var input: Double = 0
    /// Seconds of the bucket the agent spent generating.
    var generating: Double = 0
    /// Seconds of the bucket the agent spent waiting for a tool call to return.
    var tool: Double = 0
}

/// What an agent is doing at the time of a snapshot.
enum AgentState {
    case generating
    case tool
    /// A session's main thread whose tool call is a subagent or workflow that is still running.
    case waiting
    case idle
    case finished
}

/// A session's main thread, or one of its subagents.
struct AgentActivity: Identifiable {
    enum Kind { case main, subagent, workflowAgent }

    let id: String
    let sessionID: String
    /// The agent that started this one: the main thread's ID for top-level agents and workflow agents,
    /// nil for the main thread itself.
    var parentID: String?
    /// 0 for the main thread, 1 for the agents it starts, 2 for theirs, and so on.
    var depth: Int
    var kind: Kind
    /// A short label: the session's name for the main thread, otherwise the agent's description
    /// (e.g. "Explore", "design-3:radial").
    var label: String
    var workflowID: String?
    var model: String
    var start: Date
    /// When a finished agent last did something; nil while it runs.
    var end: Date?
    var state: AgentState
    var lastActivity: Date
    /// Totals over the last 30 minutes.
    var outputTokens = 0
    var thinkingTokens = 0
    var inputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    /// The size of the agent's latest request: input plus cache reads and writes.
    var contextTokens = 0
    /// Model requests made, and tool calls among them.
    var steps = 0
    var toolCalls = 0
    /// The agent's history, `ActivitySnapshot.bucketCount` buckets ending at the snapshot time.
    var buckets: [ActivityBucket]

    var isRunning: Bool { end == nil }

    /// The share of bucket `i` the agent spent working (0–1). A subagent works from its start to its end;
    /// a main thread only while it generates or waits for a tool call, since it stays open between turns.
    func workingFraction(inBucket i: Int, of snapshot: ActivitySnapshot) -> Double {
        if kind == .main {
            let b = buckets[i]
            return min(1, (b.generating + b.tool) / ActivitySnapshot.bucketSeconds)
        }
        let p0 = snapshot.bucketPosition(of: start), p1 = snapshot.bucketPosition(of: end ?? snapshot.time)
        return max(0, min(p1, Double(i + 1)) - max(p0, Double(i)))
    }
}

/// A workflow started from a session: a group of agents that run side by side.
struct WorkflowActivity: Identifiable {
    let id: String
    let sessionID: String
    var name: String
    var agentIDs: [String]
    /// The number of agents the workflow has started so far.
    var agentCount: Int
    var runningCount: Int
    var isRunning: Bool
}

/// A Claude Code session: its main thread and the agents it started.
struct SessionActivity: Identifiable {
    let id: String
    /// The name Claude Code gives the session (e.g. "colchian-12"), or its folder's name.
    var name: String
    var cwd: String
    /// The Claude config directory, e.g. "~/.claude".
    var configDirectory: String
    var model: String
    var startedAt: Date
    /// When an ended session last did something; nil while its process runs.
    var endedAt: Date?
    var isOpen: Bool
    /// Whether a turn is in progress.
    var isBusy: Bool
    var main: AgentActivity
    /// The subagents, depth-first in the order they started (children right after their parent).
    var agents: [AgentActivity]
    var workflows: [WorkflowActivity]

    var runningAgents: Int { agents.filter(\.isRunning).count }
    /// The main thread followed by the agents.
    var threads: [AgentActivity] { [main] + agents }
}

/// Claude Code activity over the last 30 minutes, read from the transcripts.
struct ActivitySnapshot {
    static let bucketSeconds: TimeInterval = 5
    static let bucketCount = 360
    static var window: TimeInterval { bucketSeconds * Double(bucketCount) }

    /// When the snapshot was taken. The last bucket ends here and is only partly filled.
    var time: Date
    /// Open sessions first, in the order they started, then ended ones, most recently ended first.
    var sessions: [SessionActivity]

    /// Agents working now across all sessions: busy main threads and running subagents.
    var agentsRunning = 0
    /// Agents that worked at some point in the last 30 minutes: main threads and subagents.
    var agentsRecent = 0
    /// The most agents working at once in the last 30 minutes.
    var peakParallel = 0
    var busySessions = 0
    var openSessions = 0
    var workflowsRunning = 0
    /// Over the last minute.
    var outputPerMinute: Double = 0
    var inputPerMinute: Double = 0
    /// Over the last 30 minutes.
    var outputTotal: Double = 0
    var inputTotal: Double = 0
    var thinkingTotal: Double = 0
    var cacheReadTotal: Double = 0
    /// Cache reads as a share of all input, over the last 30 minutes (0–1).
    var cacheHitRate: Double = 0
    /// Output over the last 30 minutes by model ID.
    var outputByModel: [String: Double] = [:]
    /// Threads (busy main threads and running subagents) per model ID.
    var runningByModel: [String: Int] = [:]
    /// Agents working in each bucket (main threads while generating or in a tool call, subagents from
    /// start to end), for charts of parallelism over time.
    var runningPerBucket: [Int] = []

    static let empty = ActivitySnapshot(time: Date(), sessions: [], runningPerBucket: Array(repeating: 0, count: bucketCount))

    /// When bucket `index` starts.
    func bucketStart(_ index: Int) -> Date {
        time.addingTimeInterval(-Double(Self.bucketCount - index) * Self.bucketSeconds)
    }

    /// The fractional bucket position of `date`: 0 at the start of the first bucket, `bucketCount` at the snapshot time.
    func bucketPosition(of date: Date) -> Double {
        Double(Self.bucketCount) - time.timeIntervalSince(date) / Self.bucketSeconds
    }

    func session(_ id: String) -> SessionActivity? { sessions.first { $0.id == id } }
}

// MARK: - Models

/// Names and colors for Claude models, from IDs like "claude-opus-5-5".
enum ClaudeModel {
    /// "Opus", "Sonnet", "Haiku", "Fable", or the ID's first word.
    static func family(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        return parts.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Claude"
    }

    /// "Opus 5.5": the family and its version, without any date suffix.
    static func name(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        let version = parts.dropFirst().prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        return version.isEmpty ? family(id) : family(id) + " " + version.joined(separator: ".")
    }

    static func color(_ id: String) -> NSColor {
        if id.contains("opus") { return .claude }
        if id.contains("sonnet") { return .systemIndigo }
        if id.contains("haiku") { return .systemTeal }
        if id.contains("fable") { return .systemPurple }
        return .systemGray
    }
}

/// Number formats shared by the activity designs.
enum ActivityFormat {
    /// "950", "12.3k", "4.2M".
    static func tokens(_ value: Double) -> String {
        let v = abs(value)
        if v < 1000 { return String(Int(value.rounded())) }
        if v < 10_000 { return String(format: "%.1fk", value / 1000) }
        if v < 1_000_000 { return String(format: "%.0fk", value / 1000) }
        if v < 10_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        return String(format: "%.0fM", value / 1_000_000)
    }

    /// "45s", "3m 20s", "1h 05m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}

// MARK: - Monitor

/// Reads Claude Code activity from the transcripts in each Claude config directory, once a second
/// while something is showing it (the menu, or the preview in Settings).
///
/// Sessions come from `sessions/<pid>.json` (open sessions, with their name and busy state) and from
/// transcripts in `projects/` written to in the last 30 minutes. Subagents have transcripts of their own
/// in the session's `subagents/` folder. Only timestamps, models and token counts are read, never content.
/// The reading happens on a background queue; only the finished snapshot comes back to the main thread.
final class ClaudeActivityMonitor {
    static let shared = ClaudeActivityMonitor()

    private(set) var snapshot = ActivitySnapshot.empty
    private var users = 0
    private var readsWhileIdle = false
    private var timer: Timer?
    private var reading = false
    private let queue = DispatchQueue(label: "colchian.activity", qos: .utility)
    private let reader = ActivityReader()

    /// Reads once a minute while nothing shows the activity, so the transcripts' tails are already
    /// read when the menu opens and only a little new data is left to read then.
    func start() {
        readsWhileIdle = true
        if users == 0 { schedule(interval: 60) }
    }

    /// Stops the once-a-minute reading (when the activity box is turned off).
    func stop() {
        readsWhileIdle = false
        if users == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Reads every second, starting now, while at least one user holds it. Balance with `release()`.
    func retain() {
        users += 1
        guard users == 1 else { return }
        refresh()
        schedule(interval: 1)
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        if readsWhileIdle {
            schedule(interval: 60)
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if interval > 1 { refresh() }
    }

    private func refresh() {
        guard !reading else { return }
        reading = true
        queue.async { [reader] in
            let snapshot = reader.read(now: Date())
            DispatchQueue.main.async {
                self.snapshot = snapshot
                self.reading = false
            }
        }
    }

    /// Reads synchronously, for tools that render the designs offscreen.
    func readNow() -> ActivitySnapshot {
        let snapshot = queue.sync { reader.read(now: Date()) }
        self.snapshot = snapshot
        return snapshot
    }
}

// MARK: - Reading

/// Finds sessions and agents, keeps a tail reader per transcript, and builds snapshots.
/// Used only on the monitor's queue.
private final class ActivityReader {
    private struct Registration {
        let name: String
        let cwd: String
        let startedAt: Date
        let busy: Bool
    }

    /// A session found on disk.
    private struct SessionSource {
        let id: String
        let configDirectory: String
        let transcript: URL
        /// The folder next to the transcript that holds `subagents/` and `workflows/`.
        var folder: URL { transcript.deletingPathExtension() }
    }

    private var tails: [URL: TranscriptTail] = [:]
    private var metas: [URL: AgentMeta] = [:]
    private var sources: [String: SessionSource] = [:]
    private var registrations: [String: Registration] = [:]
    private var lastScan = Date.distantPast
    /// Each session's subagent transcripts, refreshed with the scan.
    private var agentFiles: [String: [URL]] = [:]

    func read(now: Date) -> ActivitySnapshot {
        let windowStart = now.addingTimeInterval(-ActivitySnapshot.window)
        if now.timeIntervalSince(lastScan) >= 4 { scan(now: now, since: windowStart) }

        var sessions: [SessionActivity] = []
        var used = Set<URL>()
        for source in sources.values {
            let registration = registrations[source.id]
            guard let session = buildSession(source, registration: registration, now: now,
                                             windowStart: windowStart, used: &used) else { continue }
            sessions.append(session)
        }
        // Forget transcripts that are no longer shown.
        tails = tails.filter { used.contains($0.key) }

        sessions.sort { a, b in
            if a.isOpen != b.isOpen { return a.isOpen }
            if a.isOpen { return a.startedAt < b.startedAt }
            return (a.endedAt ?? a.startedAt) > (b.endedAt ?? b.startedAt)
        }
        var snapshot = ActivitySnapshot(time: now, sessions: sessions)
        summarize(&snapshot)
        return snapshot
    }

    // MARK: Discovery

    private func scan(now: Date, since windowStart: Date) {
        lastScan = now
        let fm = FileManager.default
        var found: [String: SessionSource] = [:]
        var registered: [String: Registration] = [:]
        for directory in ClaudeHookInstaller.configDirectories() {
            // Open sessions, from Claude Code's registry of running processes.
            let registry = directory.url.appendingPathComponent("sessions")
            for file in (try? fm.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = json["sessionId"] as? String, let pid = json["pid"] as? Int,
                      Self.isAlive(pid_t(pid)) else { continue }
                let started = (json["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
                registered[id] = Registration(name: json["name"] as? String ?? "", cwd: json["cwd"] as? String ?? "",
                                              startedAt: started, busy: json["status"] as? String == "busy")
            }
            // Transcripts written to in the window, plus those of open sessions.
            let projects = directory.url.appendingPathComponent("projects")
            for project in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                let files = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    let id = file.deletingPathExtension().lastPathComponent
                    let modified = Self.modified(file)
                    guard modified >= windowStart || registered[id] != nil else { continue }
                    found[id] = SessionSource(id: id, configDirectory: directory.displayName, transcript: file)
                }
            }
        }
        sources = found
        registrations = registered

        agentFiles = [:]
        for source in found.values {
            var files: [URL] = []
            let subagents = source.folder.appendingPathComponent("subagents")
            var folders = [subagents]
            let workflows = subagents.appendingPathComponent("workflows")
            folders += ((try? fm.contentsOfDirectory(at: workflows, includingPropertiesForKeys: nil)) ?? [])
            for folder in folders {
                for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("agent-") {
                    if Self.modified(file) >= windowStart { files.append(file) }
                }
            }
            agentFiles[source.id] = files
        }
        metas = metas.filter { url, _ in agentFiles.values.contains { $0.contains(url) } }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func tail(_ url: URL) -> TranscriptTail {
        if let tail = tails[url] { return tail }
        let tail = TranscriptTail(url: url)
        tails[url] = tail
        return tail
    }

    // MARK: Building

    private func buildSession(_ source: SessionSource, registration: Registration?, now: Date,
                              windowStart: Date, used: inout Set<URL>) -> SessionActivity? {
        let mainTail = tail(source.transcript)
        mainTail.update(windowStart: windowStart)
        used.insert(source.transcript)
        let isOpen = registration != nil
        guard isOpen || (mainTail.lastTime ?? .distantPast) >= windowStart else { return nil }

        let cwd = registration?.cwd ?? mainTail.cwd ?? ""
        var name = registration?.name ?? ""
        if name.isEmpty { name = (cwd as NSString).lastPathComponent }
        if name.isEmpty { name = String(source.id.prefix(8)) }
        let model = mainTail.model ?? "claude"
        let startedAt = registration?.startedAt ?? mainTail.firstTime ?? now

        // Workflow names and states, from the session's workflows folder.
        var workflowInfo: [String: (name: String, running: Bool)] = [:]
        let workflowFolder = source.folder.appendingPathComponent("workflows")
        for file in (try? FileManager.default.contentsOfDirectory(at: workflowFolder, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let status = json["status"] as? String ?? "running"
            workflowInfo[file.deletingPathExtension().lastPathComponent] =
                (json["workflowName"] as? String ?? "workflow", !["completed", "failed", "cancelled", "killed"].contains(status))
        }

        // Subagents.
        var agents: [AgentActivity] = []
        var toolUseOwners: [String: String] = [:]
        for id in mainTail.agentToolUseIDs { toolUseOwners[id] = source.id }
        var pending: [(AgentActivity, AgentMeta)] = []
        for file in agentFiles[source.id] ?? [] {
            let agentTail = tail(file)
            agentTail.update(windowStart: windowStart)
            used.insert(file)
            let meta = self.meta(for: file)
            let agentID = String(file.deletingPathExtension().lastPathComponent.dropFirst("agent-".count))
            let workflowID = file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "workflows"
                ? file.deletingLastPathComponent().lastPathComponent : nil
            for id in agentTail.agentToolUseIDs { toolUseOwners[id] = agentID }
            let finishedByWorkflow = workflowID.map { workflowInfo[$0]?.running == false } ?? false
            let finished = meta.finished || finishedByWorkflow || !isOpen || agentTail.endedTurn(now: now)
            let kind: AgentActivity.Kind = workflowID == nil ? .subagent : .workflowAgent
            var label = meta.description ?? meta.agentType ?? "agent"
            if label.isEmpty { label = "agent" }
            let agent = agentTail.activity(id: agentID, sessionID: source.id, kind: kind, label: label,
                                           model: agentTail.model ?? meta.model ?? model, finished: finished,
                                           now: now, windowStart: windowStart)
            var withWorkflow = agent
            withWorkflow.workflowID = workflowID
            pending.append((withWorkflow, meta))
        }
        // Parents: the agent whose transcript holds the tool call that started it, else the main thread.
        for (agent, meta) in pending {
            var agent = agent
            agent.parentID = meta.toolUseID.flatMap { toolUseOwners[$0] } ?? source.id
            if agent.parentID == agent.id { agent.parentID = source.id }
            agents.append(agent)
        }
        agents = Self.treeOrder(agents, root: source.id)

        var main = mainTail.activity(id: source.id, sessionID: source.id, kind: .main, label: name, model: model,
                                     finished: !isOpen, now: now, windowStart: windowStart)
        let anyRunning = agents.contains { $0.isRunning && $0.parentID == source.id }
        if isOpen {
            if registration?.busy == true, main.state == .idle { main.state = .generating }
            if registration?.busy == false, main.state != .finished { main.state = .idle }
            if main.state == .tool, anyRunning { main.state = .waiting }
        }

        let workflows: [WorkflowActivity] = Dictionary(grouping: agents.filter { $0.workflowID != nil }, by: { $0.workflowID! })
            .map { id, members in
                let running = members.filter(\.isRunning).count
                return WorkflowActivity(id: id, sessionID: source.id, name: workflowInfo[id]?.name ?? "workflow",
                                        agentIDs: members.map(\.id), agentCount: members.count, runningCount: running,
                                        isRunning: (workflowInfo[id]?.running ?? false) && isOpen || running > 0)
            }
            .sorted { a, b in
                let sa = agents.first { $0.id == a.agentIDs.first }?.start ?? now
                let sb = agents.first { $0.id == b.agentIDs.first }?.start ?? now
                return sa < sb
            }

        return SessionActivity(id: source.id, name: name, cwd: cwd, configDirectory: source.configDirectory, model: model,
                               startedAt: startedAt, endedAt: isOpen ? nil : (mainTail.lastTime ?? startedAt), isOpen: isOpen,
                               isBusy: isOpen && (registration?.busy ?? false), main: main, agents: agents, workflows: workflows)
    }

    /// Depth-first order, each agent's children right after it, siblings in the order they started.
    private static func treeOrder(_ agents: [AgentActivity], root: String) -> [AgentActivity] {
        let children = Dictionary(grouping: agents, by: { $0.parentID ?? root })
        var ordered: [AgentActivity] = []
        var seen = Set<String>()
        func visit(_ parent: String, depth: Int) {
            for var child in (children[parent] ?? []).sorted(by: { $0.start < $1.start }) where !seen.contains(child.id) {
                seen.insert(child.id)
                child.depth = depth
                ordered.append(child)
                visit(child.id, depth: depth + 1)
            }
        }
        visit(root, depth: 1)
        // Anything in a cycle or with a missing parent goes under the main thread.
        for var agent in agents where !seen.contains(agent.id) {
            agent.parentID = root
            agent.depth = 1
            ordered.append(agent)
        }
        return ordered
    }

    private func meta(for transcript: URL) -> AgentMeta {
        if let meta = metas[transcript], meta.finished { return meta }
        let url = transcript.deletingPathExtension().appendingPathExtension("meta.json")
        var meta = AgentMeta()
        if let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            meta.agentType = json["agentType"] as? String
            meta.description = json["description"] as? String
            meta.toolUseID = json["toolUseId"] as? String
            meta.model = json["pickedEffortModel"] as? String
            meta.finished = json["finished"] as? Bool ?? false
        }
        metas[transcript] = meta
        return meta
    }

    // MARK: Totals

    private func summarize(_ snapshot: inout ActivitySnapshot) {
        let count = ActivitySnapshot.bucketCount
        var running = [Int](repeating: 0, count: count)
        let perMinuteBuckets = Int(60 / ActivitySnapshot.bucketSeconds)
        for session in snapshot.sessions {
            if session.isOpen { snapshot.openSessions += 1 }
            if session.isBusy { snapshot.busySessions += 1 }
            snapshot.workflowsRunning += session.workflows.filter(\.isRunning).count
            for thread in session.threads {
                for (i, bucket) in thread.buckets.enumerated() {
                    snapshot.outputTotal += bucket.output
                    snapshot.inputTotal += bucket.input
                    snapshot.outputByModel[thread.model, default: 0] += bucket.output
                    if i >= count - perMinuteBuckets {
                        snapshot.outputPerMinute += bucket.output
                        snapshot.inputPerMinute += bucket.input
                    }
                }
                snapshot.thinkingTotal += Double(thread.thinkingTokens)
                snapshot.cacheReadTotal += Double(thread.cacheReadTokens)
                let busy = thread.kind == .main ? session.isBusy : thread.isRunning
                if busy {
                    snapshot.runningByModel[thread.model, default: 0] += 1
                    snapshot.agentsRunning += 1
                }
                var worked = busy || thread.kind != .main
                for i in 0..<count where thread.workingFraction(inBucket: i, of: snapshot) > 0 {
                    running[i] += 1
                    worked = true
                }
                if worked { snapshot.agentsRecent += 1 }
            }
        }
        snapshot.runningPerBucket = running
        snapshot.peakParallel = running.max() ?? 0
        let allInput = snapshot.sessions.flatMap(\.threads).reduce(0.0) {
            $0 + Double($1.inputTokens + $1.cacheReadTokens + $1.cacheWriteTokens)
        }
        snapshot.cacheHitRate = allInput > 0 ? snapshot.cacheReadTotal / allInput : 0
    }
}

/// What an agent's `.meta.json` says about it.
private struct AgentMeta {
    var agentType: String?
    var description: String?
    var toolUseID: String?
    var model: String?
    var finished = false
}

// MARK: - Transcript tail

/// Reads a transcript incrementally from where it last stopped, keeping what the activity
/// designs need from each line: when it was written, whether it was a request, a tool call or
/// a tool result, and the token counts. The first read skips all but the last 32 MB (tool results
/// with screenshots make transcripts large), so the start time comes from the first line separately.
private final class TranscriptTail {
    private static let initialReadLimit: UInt64 = 32 << 20
    /// Lines longer than this are tool results with large content (such as images); they're not parsed
    /// as JSON, which would be slow, only searched for their timestamp.
    private static let largeLine = 256 << 10

    enum Kind {
        /// A prompt or tool result: the model starts generating.
        case input
        /// A response that calls tools.
        case toolCall(count: Int)
        /// A response that ends the turn (or a block of one that doesn't call tools).
        case response(endsTurn: Bool)
    }

    struct Event {
        let time: Date
        let kind: Kind
        /// Output tokens this line adds to its message (responses repeat their message's usage on each block).
        var output = 0
        var thinking = 0
        var input = 0
        var cacheRead = 0
        var cacheWrite = 0
        var isNewMessage = false
    }

    let url: URL
    private var offset: UInt64 = 0
    private var remainder = Data()
    private(set) var events: [Event] = []
    private(set) var model: String?
    private(set) var cwd: String?
    private(set) var firstTime: Date?
    private(set) var lastTime: Date?
    /// IDs of the Agent and Task tool calls this transcript made, to find each subagent's parent.
    private(set) var agentToolUseIDs: [String] = []
    /// Output already counted per message ID.
    private var counted: [String: Int] = [:]

    init(url: URL) {
        self.url = url
    }

    func update(windowStart: Date) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {  // rewritten: start over
            offset = 0
            remainder = Data()
            events = []
            counted = [:]
        }
        var skipPartialLine = false
        if offset == 0, size > Self.initialReadLimit {
            firstTime = Self.firstLineTime(handle)
            offset = size - Self.initialReadLimit
            skipPartialLine = true
        }
        // In chunks, so a first read of a large transcript doesn't hold it all in memory at once.
        try? handle.seek(toOffset: offset)
        while offset < size, let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            if skipPartialLine {
                guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
                skipPartialLine = false
                consume(chunk[(newline + 1)...])
            } else {
                consume(chunk)
            }
        }
        // Keep a little more than the window, so the state at its start is known.
        let keepAfter = windowStart.addingTimeInterval(-600)
        if let firstKept = events.firstIndex(where: { $0.time >= keepAfter }), firstKept > 0 {
            events.removeFirst(firstKept)
        }
        if counted.count > 4000 { counted = [:] }
    }

    private func consume<D: DataProtocol>(_ data: D) {
        var buffer = remainder
        buffer.append(contentsOf: data)
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            parse(buffer[start..<newline])
            start = buffer.index(after: newline)
        }
        // A real copy: a slice would keep the whole (possibly 32 MB) buffer alive.
        remainder = start == buffer.endIndex ? Data() : buffer[start...].withUnsafeBytes { Data($0) }
    }

    private func parse(_ line: Data) {
        if line.count > Self.largeLine, line.range(of: Data(#""type":"assistant""#.utf8)) == nil {
            // A user line with a large tool result: only its time matters.
            guard let time = Self.timestamp(in: line) else { return }
            if firstTime == nil { firstTime = time }
            lastTime = time
            events.append(Event(time: time, kind: .input))
            return
        }
        guard !line.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = json["type"] as? String, type == "user" || type == "assistant",
              let stamp = json["timestamp"] as? String, let time = Self.date(stamp),
              let message = json["message"] as? [String: Any] else { return }
        if cwd == nil { cwd = json["cwd"] as? String }
        if firstTime == nil { firstTime = time }
        lastTime = time
        let content = message["content"]

        if type == "user" {
            if json["isMeta"] as? Bool == true { return }
            events.append(Event(time: time, kind: .input))
            return
        }

        if let model = message["model"] as? String, model.hasPrefix("claude") { self.model = model }
        let blocks = content as? [[String: Any]] ?? []
        let toolUses = blocks.filter { $0["type"] as? String == "tool_use" }
        for use in toolUses {
            let name = use["name"] as? String ?? ""
            if name == "Agent" || name == "Task", let id = use["id"] as? String { agentToolUseIDs.append(id) }
        }
        let kind: Kind = toolUses.isEmpty
            ? .response(endsTurn: (message["stop_reason"] as? String).map { $0 == "end_turn" || $0 == "stop_sequence" } ?? false)
            : .toolCall(count: toolUses.count)
        var event = Event(time: time, kind: kind)
        if let usage = message["usage"] as? [String: Any] {
            let id = message["id"] as? String ?? UUID().uuidString
            let output = usage["output_tokens"] as? Int ?? 0
            let already = counted[id]
            event.isNewMessage = already == nil
            event.output = max(0, output - (already ?? 0))
            counted[id] = max(output, already ?? 0)
            if already == nil {
                event.input = usage["input_tokens"] as? Int ?? 0
                event.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                event.cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
            }
            if let details = usage["output_tokens_details"] as? [String: Any], already == nil {
                event.thinking = details["thinking_tokens"] as? Int ?? 0
            }
        }
        events.append(event)
    }

    /// Whether the agent's last response ended its turn a while ago: a finished background agent.
    func endedTurn(now: Date) -> Bool {
        guard let last = events.last else { return true }
        if now.timeIntervalSince(last.time) > 900 { return true }
        if case .response(let ends) = last.kind { return ends && now.timeIntervalSince(last.time) > 20 }
        return false
    }

    /// The agent's activity: totals, current state and history buckets.
    func activity(id: String, sessionID: String, kind: AgentActivity.Kind, label: String, model: String,
                  finished: Bool, now: Date, windowStart: Date) -> AgentActivity {
        let count = ActivitySnapshot.bucketCount
        let width = ActivitySnapshot.bucketSeconds
        var buckets = [ActivityBucket](repeating: ActivityBucket(), count: count)
        var agent = AgentActivity(id: id, sessionID: sessionID, depth: 0, kind: kind, label: label, model: model,
                                  start: firstTime ?? now, state: .idle, lastActivity: lastTime ?? now, buckets: [])

        /// Adds `amount` spread evenly over [from, to] to the buckets, through `field`.
        func spread(_ amount: Double, from: Date, to: Date, _ field: WritableKeyPath<ActivityBucket, Double>, perSecond: Bool = false) {
            let a = max(from, windowStart), b = min(to, now)
            guard b > a else {
                if !perSecond, to >= windowStart, to <= now {
                    let i = min(count - 1, Int(to.timeIntervalSince(windowStart) / width))
                    buckets[i][keyPath: field] += amount
                }
                return
            }
            let total = to.timeIntervalSince(from)
            var t = a
            while t < b {
                let i = min(count - 1, Int(t.timeIntervalSince(windowStart) / width))
                let bucketEnd = windowStart.addingTimeInterval(Double(i + 1) * width)
                let segmentEnd = min(bucketEnd, b)
                let seconds = segmentEnd.timeIntervalSince(t)
                buckets[i][keyPath: field] += perSecond ? seconds : amount * seconds / max(total, 0.001)
                if segmentEnd <= t { break }
                t = segmentEnd
            }
        }

        var state: AgentState = .idle
        var since = events.first?.time ?? now
        var previous: Date?
        for event in events {
            // Close the interval of the previous state.
            switch state {
            case .generating: spread(0, from: since, to: event.time, \.generating, perSecond: true)
            case .tool, .waiting: spread(0, from: since, to: event.time, \.tool, perSecond: true)
            default: break
            }
            // Tokens arrive with the response; spread them over the time it took (at most two minutes).
            let from = max(previous ?? event.time, event.time.addingTimeInterval(-120))
            if event.output > 0 { spread(Double(event.output), from: from, to: event.time, \.output) }
            let input = event.input + event.cacheRead + event.cacheWrite
            if input > 0 { spread(Double(input), from: from, to: event.time, \.input) }

            let inWindow = event.time >= windowStart
            if inWindow {
                agent.outputTokens += event.output
                agent.thinkingTokens += event.thinking
                agent.inputTokens += event.input
                agent.cacheReadTokens += event.cacheRead
                agent.cacheWriteTokens += event.cacheWrite
            }
            if event.isNewMessage {
                if inWindow { agent.steps += 1 }
                agent.contextTokens = input
            }
            switch event.kind {
            case .input: state = .generating
            case .toolCall(let calls):
                state = .tool
                if inWindow { agent.toolCalls += calls }
            case .response(let ends): state = ends ? .idle : .generating
            }
            since = event.time
            previous = event.time
        }
        // The current state runs until now, unless it has gone quiet for a long time.
        if now.timeIntervalSince(since) > 900 { state = .idle }
        if !finished {
            switch state {
            case .generating: spread(0, from: since, to: now, \.generating, perSecond: true)
            case .tool, .waiting: spread(0, from: since, to: now, \.tool, perSecond: true)
            default: break
            }
        }
        agent.state = finished ? .finished : state
        agent.end = finished ? (lastTime ?? now) : nil
        agent.buckets = buckets
        return agent
    }

    /// The time of the file's first line, read on its own.
    private static func firstLineTime(_ handle: FileHandle) -> Date? {
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 1 << 20) else { return nil }
        let line = head.firstIndex(of: 0x0A).map { head[..<$0] } ?? head[...]
        return timestamp(in: Data(line))
    }

    /// Finds `"timestamp":"…"` in a line without parsing it as JSON.
    private static func timestamp(in line: Data) -> Date? {
        let key = Data(#""timestamp":""#.utf8)
        guard let range = line.range(of: key, options: .backwards) else { return nil }
        let start = range.upperBound
        guard let end = line[start...].firstIndex(of: UInt8(ascii: "\"")), end - start < 40 else { return nil }
        return date(String(decoding: line[start..<end], as: UTF8.self))
    }

    /// Parses "2026-11-03T19:42:45.200Z" quickly (ISO8601DateFormatter is slow for thousands of lines).
    private static func date(_ string: String) -> Date? {
        let u = Array(string.utf8)
        guard u.count >= 19 else { return nil }
        func num(_ from: Int, _ length: Int) -> Int {
            var value = 0
            for i in from..<(from + length) { value = value * 10 + Int(u[i] &- 48) }
            return value
        }
        var t = tm()
        t.tm_year = Int32(num(0, 4) - 1900)
        t.tm_mon = Int32(num(5, 2) - 1)
        t.tm_mday = Int32(num(8, 2))
        t.tm_hour = Int32(num(11, 2))
        t.tm_min = Int32(num(14, 2))
        t.tm_sec = Int32(num(17, 2))
        var seconds = Double(timegm(&t))
        if u.count > 20, u[19] == UInt8(ascii: ".") {
            var fraction = 0.0, scale = 0.1, i = 20
            while i < u.count, u[i] >= 48, u[i] <= 57 {
                fraction += Double(u[i] - 48) * scale
                scale /= 10
                i += 1
            }
            seconds += fraction
        }
        return Date(timeIntervalSince1970: seconds)
    }
}
