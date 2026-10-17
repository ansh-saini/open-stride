import Foundation

/// Any text-generation backend: MLX on device, Ollama on a Mac or server.
public protocol LLMClient: Sendable {
    var name: String { get }
    /// Returns the model's raw text. `schema` is a JSON schema the backend should constrain output to, if it can.
    func complete(system: String, user: String, schema: [String: any Sendable]) async throws -> String
}

/// What the runner actually did last week against what was planned.
public struct WeekReview: Codable, Hashable, Sendable {
    public var plannedKm: Double
    public var completedKm: Double
    public var plannedRuns: Int
    public var completedRuns: Int
    public var compliancePct: Int

    public static func make(previous: WeekPlan?, runs: [Run], calendar: Calendar = .coach) -> WeekReview? {
        guard let prev = previous else { return nil }
        let end = calendar.date(byAdding: .day, value: 7, to: prev.weekStart)!
        let done = runs.filter { $0.start >= prev.weekStart && $0.start < end }
        let planned = prev.plannedKm
        let km = done.map(\.distanceKm).reduce(0, +)
        let plannedRuns = prev.sessions.filter { $0.type != .rest }.count
        return WeekReview(
            plannedKm: planned, completedKm: (km * 10).rounded() / 10, plannedRuns: plannedRuns, completedRuns: done.count,
            compliancePct: planned > 0 ? Int((min(km / planned, 1.5) * 100).rounded()) : 100
        )
    }
}

public struct CoachDecision: Codable, Hashable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case keep, make_easy, shorten, drop
    }

    public struct Change: Codable, Hashable, Sendable {
        public var day: String
        public var action: Action
        public var reason: String
    }

    public var assessment: String
    public var volumeChangePct: Int
    public var easyPaceAdjustSec: Int
    public var changes: [Change]
    public var message: String

    enum CodingKeys: String, CodingKey {
        case assessment, changes, message
        case volumeChangePct = "volume_change_pct"
        case easyPaceAdjustSec = "slow_easy_pace_by_sec"
    }

    public init(assessment: String, volumeChangePct: Int, easyPaceAdjustSec: Int, changes: [Change], message: String) {
        self.assessment = assessment
        self.volumeChangePct = volumeChangePct
        self.easyPaceAdjustSec = easyPaceAdjustSec
        self.changes = changes
        self.message = message
    }

    /// Lenient: without a schema-constrained decoder (MLX), small models drift from the shape.
    /// Numbers may come as strings, changes as "Thu: make_easy (reason)", missing keys default to no change.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        assessment = (try? c.decode(String.self, forKey: .assessment)) ?? message
        volumeChangePct = Self.int(c, .volumeChangePct)
        easyPaceAdjustSec = Self.int(c, .easyPaceAdjustSec)
        changes = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .changes) {
            while !list.isAtEnd {
                if let change = try? list.decode(Change.self) {
                    changes.append(change)
                } else if let text = try? list.decode(String.self), let change = Change(text: text) {
                    changes.append(change)
                } else {
                    _ = try? list.decode(Skip.self)
                }
            }
        }
        guard c.contains(.volumeChangePct) || c.contains(.changes) else {
            throw DecodingError.dataCorruptedError(forKey: .volumeChangePct, in: c, debugDescription: "not a decision")
        }
    }

    private struct Skip: Decodable {}

    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int {
        if let i = try? c.decode(Int.self, forKey: key) { return i }
        if let d = try? c.decode(Double.self, forKey: key) { return Int(d.rounded()) }
        if let s = try? c.decode(String.self, forKey: key),
           let r = s.range(of: #"-?\d+"#, options: .regularExpression) { return Int(s[r]) ?? 0 }
        return 0
    }
}

extension CoachDecision.Change {
    enum Keys: String, CodingKey { case day, action, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let rawDay = try c.decode(String.self, forKey: .day)
        let rawAction = try c.decode(String.self, forKey: .action)
        guard let day = CoachAgent.dayNames.first(where: { rawDay.localizedCaseInsensitiveContains($0) }),
              let action = CoachDecision.Action(rawValue: rawAction.lowercased().replacingOccurrences(of: " ", with: "_"))
        else { throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "unknown day or action") }
        self.init(day: day, action: action, reason: (try? c.decode(String.self, forKey: .reason)) ?? "")
    }

    /// Parses "Thu: make_easy - reason" style strings.
    init?(text: String) {
        guard let day = CoachAgent.dayNames.first(where: { text.localizedCaseInsensitiveContains($0) }),
              let action = CoachDecision.Action.allCases.first(where: { text.localizedCaseInsensitiveContains($0.rawValue) })
        else { return nil }
        self.init(day: day, action: action, reason: text)
    }
}

public struct CoachResult: Sendable {
    public var week: WeekPlan
    public var decision: CoachDecision
    /// Model name, or "rules" when the fallback coach ran.
    public var source: String
    /// Every place a guardrail overrode the model, in plain words.
    public var guardrailHits: [String]
    public var rawOutput: String?
    public var error: String?
    public var latency: TimeInterval
}

public struct CoachAgent: Sendable {
    public var llm: LLMClient?

    public init(llm: LLMClient?) { self.llm = llm }

    public static let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Draft the week, ask the model to review it, apply guardrails. Never throws: falls back to rules.
    public func planWeek(goal: Goal, data: AthleteData, previous: WeekPlan? = nil, planStart: Date? = nil, now: Date = .now) async -> CoachResult {
        let metrics = MetricsCalculator.compute(data, now: now)
        let draft = PlanEngine.draftWeek(goal: goal, metrics: metrics, now: now, planStart: planStart)
        let review = WeekReview.make(previous: previous, runs: data.runs)
        let started = Date()

        if let llm {
            let prompt = Self.userPrompt(goal: goal, metrics: metrics, draft: draft, review: review)
            var raw: String?
            do {
                let out = try await llm.complete(system: Self.systemPrompt, user: prompt, schema: Self.schema)
                raw = out
                let decision = try Self.parse(out)
                var (week, hits) = Self.apply(decision, to: draft, metrics: metrics, review: review)
                week.coachSource = llm.name
                // Second call: explain the plan as it ended up after guardrails, from facts code computed.
                let facts = Self.noteFacts(draft: draft, final: week, metrics: metrics, review: review)
                if let note = try? await llm.complete(system: Self.noteSystemPrompt, user: facts, schema: [:]),
                   let clean = Self.cleanNote(note) {
                    let opening = Self.noteOpening(flagged: Self.signals(metrics, review: review).filter(\.flagged))
                    // Some models repeat the opening anyway; keep one copy.
                    week.coachSummary = clean.hasPrefix(String(opening.prefix(25))) ? clean : opening + " " + clean
                } else {
                    week.coachSummary = Self.ruleBased(draft: draft, metrics: metrics, review: review).week.coachSummary
                    week.coachSource = "\(llm.name), message from rules"
                }
                return CoachResult(week: week, decision: decision, source: llm.name, guardrailHits: hits,
                                   rawOutput: out, error: nil, latency: Date().timeIntervalSince(started))
            } catch {
                var result = Self.ruleBased(draft: draft, metrics: metrics, review: review)
                result.rawOutput = raw
                result.error = "\(error)"
                result.latency = Date().timeIntervalSince(started)
                return result
            }
        }
        return Self.ruleBased(draft: draft, metrics: metrics, review: review)
    }

    // MARK: Prompt

    public static let systemPrompt = """
    You are an experienced, careful running coach. You get one runner's signals and next week's draft plan. The draft is already built for this runner. Your job is to decide if it needs small adjustments.

    How to decide:
    - Look at SIGNALS. Each one is OK or FLAG, with what to do when flagged.
    - If every signal is OK, keep the plan: volume_change_pct 0, slow_easy_pace_by_sec 0, changes [].
    - Only act on FLAG signals. Do not invent problems. Do not repeat numbers that are not in the data.
    - volume_change_pct: whole number from -40 to 10. Negative means less running.
    - slow_easy_pace_by_sec: 0 to 30. How many seconds per km slower easy runs should be.
    - changes: only days you change, and only days listed in the draft. Actions: make_easy (turn a hard day easy), shorten (cut that run by a quarter), drop (remove that run). Each change is {"day": "Mon", "action": "shorten", "reason": "..."}; the reason cites a number from SIGNALS.

    Respond with one JSON object only. When every signal is OK it looks like this:
    {"assessment": "All signals in range.", "volume_change_pct": 0, "slow_easy_pace_by_sec": 0, "changes": []}
    """

    public static let noteSystemPrompt = """
    You are a running coach writing a short weekly note to your runner. Use only the facts given. Do not add numbers that are not in the facts.
    The first sentence is already written. Continue it with 1-2 short sentences in second person, plain words, warm but not gushing.
    No greeting, no preamble, no exclamation marks, no lists, no markdown. Plain text only.
    """

    /// Facts for the note, computed by diffing the draft against the final plan, so the note matches what the runner sees.
    public static func noteFacts(draft: WeekPlan, final: WeekPlan, metrics m: Metrics, review: WeekReview?) -> String {
        let flagged = signals(m, review: review).filter(\.flagged)
        var lines = ["FLAGGED SIGNALS:"]
        lines += flagged.isEmpty ? ["- none, all in range"] : flagged.map { "- \($0.title): \($0.value) (\($0.guidance))" }

        var changes: [String] = []
        if abs(final.plannedKm - draft.plannedKm) >= 0.5 {
            let pct = Int(((final.plannedKm / draft.plannedKm - 1) * 100).rounded())
            changes.append("weekly distance \(Format.km(draft.plannedKm)) -> \(Format.km(final.plannedKm)) (\(pct)%)")
        }
        for d in draft.sessions {
            let day = dayNames[d.weekday - 1]
            guard let f = final.sessions.first(where: { $0.id == d.id }) else {
                changes.append("\(day) \(d.type.rawValue) run removed")
                continue
            }
            if f.type != d.type { changes.append("\(day) \(d.type.rawValue) changed to \(f.type.rawValue) run") }
        }
        if let a = draft.sessions.first(where: { $0.type == .easy })?.pace, let b = final.sessions.first(where: { $0.type == .easy })?.pace, b.slow > a.slow {
            changes.append("easy pace \(Int(b.slow - a.slow)) s/km slower, now \(Format.paceRange(b))")
        }
        lines.append("")
        lines.append("WHAT CHANGED FROM THE STANDARD PLAN:")
        lines += changes.isEmpty ? ["- nothing, the week builds as planned"] : changes.map { "- " + $0 }
        lines.append("")
        let long = final.sessions.first { $0.type == .long }.map { ", long run \(Format.km($0.distanceKm)) on \(dayNames[$0.weekday - 1])" } ?? ""
        lines.append("WEEK: \(final.phase.rawValue) phase, \(final.sessions.count) runs, \(Format.km(final.plannedKm)) total\(long).")
        lines.append("")
        lines.append("THE NOTE ALREADY STARTS WITH: \"\(noteOpening(flagged: flagged))\"")
        lines.append(flagged.isEmpty
            ? "Write the next 1-2 sentences: the focus of this week."
            : "Write the next 1-2 sentences: what changed this week and why. Do not repeat the opening.")
        return lines.joined(separator: "\n")
    }

    /// The first sentence is written by code so it is always right; the model continues from it.
    public static func noteOpening(flagged: [Signal]) -> String {
        if let top = flagged.first { return top.spoken + "." }
        return "Your signals are all in range, so this week builds as planned."
    }

    static func cleanNote(_ text: String) -> String? {
        // Drop preambles like "Okay, here's the weekly note:".
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let body = lines.drop { $0.hasSuffix(":") || $0.lowercased().hasPrefix("okay") || $0.lowercased().hasPrefix("here") }
        var t = body.joined(separator: " ")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"`*"))
        t = t.replacingOccurrences(of: "!", with: ".")
        guard t.count >= 20, t.count <= 700, !t.contains("{") else { return nil }
        return t
    }

    public struct Signal: Codable, Hashable, Sendable {
        public var name: String
        public var value: String
        public var flagged: Bool
        /// What to do when flagged, or why it is fine.
        public var guidance: String

        public var title: String {
            switch name {
            case "acute_chronic_load_ratio": "Load ratio (7d vs 28d)"
            case "days_since_last_run": "Days since last run"
            case "easy_run_hr_drift": "HR drift on runs"
            case "last_week_completed": "Last week completed"
            default: name
            }
        }

        /// How a coach would say it out loud.
        public var spoken: String {
            switch name {
            case "acute_chronic_load_ratio": "Your training load ratio is \(value), so this week rose much faster than your usual load"
            case "days_since_last_run": "It has been \(value) days since your last run"
            case "easy_run_hr_drift": "Your heart rate drifted \(value) during recent runs"
            case "last_week_completed": "You completed " + value.replacingOccurrences(of: " (", with: " of last week's plan (")
            default: "\(title) is \(value)"
            }
        }
    }

    /// Thresholds live in code so even a small model only has to judge, not compute.
    public static func signals(_ m: Metrics, review: WeekReview?) -> [Signal] {
        var out: [Signal] = []
        if let a = m.acwr {
            let v = String(format: "%.2f", a)
            if a > 1.5 {
                out.append(.init(name: "acute_chronic_load_ratio", value: v, flagged: true, guidance: "above 1.5: injury risk. Cut volume 20-30% and keep at most one hard day."))
            } else if a > 1.3 {
                out.append(.init(name: "acute_chronic_load_ratio", value: v, flagged: true, guidance: "above 1.3: load rising fast. Cut volume about 10%."))
            } else if a < 0.8 {
                out.append(.init(name: "acute_chronic_load_ratio", value: v, flagged: false, guidance: "below 0.8: a lighter week than usual. Fine to build back up gradually."))
            } else {
                out.append(.init(name: "acute_chronic_load_ratio", value: v, flagged: false, guidance: "0.8-1.3 is a safe range."))
            }
        }
        if let g = m.daysSinceLastRun {
            out.append(g >= 14
                ? .init(name: "days_since_last_run", value: "\(g)", flagged: true, guidance: "14+ days off: make every hard day easy.")
                : .init(name: "days_since_last_run", value: "\(g)", flagged: false, guidance: "under 14 is fine."))
        }
        if let d = m.hrDriftPct {
            let v = String(format: "%.1f%%", d)
            out.append(d > 5
                ? .init(name: "easy_run_hr_drift", value: v, flagged: true, guidance: "above 5%: easy runs too fast. Slow easy pace 10-20 s/km.")
                : .init(name: "easy_run_hr_drift", value: v, flagged: false, guidance: "5% or less is normal."))
        }
        if let r = review {
            let v = "\(r.compliancePct)% (\(Format.km(r.completedKm)) of \(Format.km(r.plannedKm)))"
            out.append(r.compliancePct < 60
                ? .init(name: "last_week_completed", value: v, flagged: true, guidance: "under 60%: last week was too much. Cut volume 10-20%, do not progress.")
                : .init(name: "last_week_completed", value: v, flagged: false, guidance: "60% or more is on track."))
        }
        return out
    }

    public static let schema: [String: any Sendable] = [
        "type": "object",
        "properties": [
            "assessment": ["type": "string"],
            "volume_change_pct": ["type": "integer"],
            "slow_easy_pace_by_sec": ["type": "integer"],
            "changes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "day": ["type": "string", "enum": dayNames],
                        "action": ["type": "string", "enum": CoachDecision.Action.allCases.map(\.rawValue)],
                        "reason": ["type": "string"],
                    ] as [String: any Sendable],
                    "required": ["day", "action", "reason"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
        "required": ["assessment", "volume_change_pct", "slow_easy_pace_by_sec", "changes"],
    ]

    public static func userPrompt(goal: Goal, metrics m: Metrics, draft: WeekPlan, review: WeekReview?) -> String {
        // Full weeks only. The current partial week confuses small models.
        let weeks = m.weekly.dropLast().suffix(4).map { Format.km($0.km) }.joined(separator: ", ")
        var lines = [
            "GOAL: \(goal.race.rawValue) in \(draft.totalWeeks - draft.weekNumber + 1) weeks, \(goal.daysPerWeek) runs per week.",
            "PHASE: \(draft.phase.rawValue), week \(draft.weekNumber) of \(draft.totalWeeks)\(draft.isCutback ? ", planned cutback week" : "").",
            "RECENT WEEKS (oldest first): \(weeks). Baseline \(Format.km(m.baselineWeeklyKm))/week.",
            "",
            "SIGNALS:",
        ]
        for s in signals(m, review: review) {
            lines.append("- \(s.name) = \(s.value) -> \(s.flagged ? "FLAG" : "OK"): \(s.guidance)")
        }
        lines.append("")
        lines.append("DRAFT PLAN FOR NEXT WEEK (total \(Format.km(draft.plannedKm))):")
        for s in draft.sessions {
            let pace = s.pace.map { " @ \(Format.paceRange($0))" } ?? ""
            lines.append("- \(dayNames[s.weekday - 1]): \(s.type.rawValue) \(Format.km(s.distanceKm))\(pace)")
        }
        lines.append("")
        let days = draft.sessions.map { dayNames[$0.weekday - 1] }.joined(separator: ", ")
        lines.append("Days with runs: \(days). Return JSON with keys: assessment, volume_change_pct, slow_easy_pace_by_sec, changes.")
        return lines.joined(separator: "\n")
    }

    // MARK: Parse

    public enum ParseError: Error, CustomStringConvertible {
        case noJSON, decode(String)
        public var description: String {
            switch self {
            case .noJSON: "no JSON object in output"
            case let .decode(s): "decode failed: \(s)"
            }
        }
    }

    public static func parse(_ text: String) throws -> CoachDecision {
        // Small models sometimes wrap JSON in prose or code fences. Take the outermost object.
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else {
            throw ParseError.noJSON
        }
        let json = Data(text[open...close].utf8)
        do {
            return try JSONDecoder().decode(CoachDecision.self, from: json)
        } catch {
            throw ParseError.decode("\(error)")
        }
    }

    // MARK: Guardrails

    /// Applies the model's decision to the draft, then enforces safety rules the model cannot override.
    public static func apply(_ d: CoachDecision, to draft: WeekPlan, metrics m: Metrics, review: WeekReview?) -> (WeekPlan, [String]) {
        var week = draft
        var hits: [String] = []

        // Volume
        var pct = d.volumeChangePct
        if pct > 10 || pct < -40 {
            hits.append("volume change \(pct)% clamped to [-40, 10]")
            pct = min(max(pct, -40), 10)
        }
        let anyFlag = signals(m, review: review).contains(where: \.flagged)
        if !anyFlag, pct != 0 {
            hits.append("volume change \(pct)% ignored: no signal flagged")
            pct = 0
        }
        // Floors: the least a flagged signal requires, if the model under-reacted.
        if let acwr = m.acwr, acwr > 1.5, pct > -20 {
            hits.append("floor: volume \(pct)% -> -20% for load ratio \(acwr)")
            pct = -20
        } else if let acwr = m.acwr, acwr > 1.3, pct > -10 {
            hits.append("floor: volume \(pct)% -> -10% for load ratio \(acwr)")
            pct = -10
        }
        if let r = review, r.compliancePct < 60, pct > -10 {
            hits.append("floor: volume \(pct)% -> -10% for \(r.compliancePct)% completion")
            pct = -10
        }
        if let acwr = m.acwr, acwr > 1.3, pct > 0 {
            hits.append("volume increase blocked: acwr \(acwr) > 1.3")
            pct = 0
        }
        if let r = review, r.compliancePct < 60, pct > 0 {
            hits.append("volume increase blocked: compliance \(r.compliancePct)% < 60")
            pct = 0
        }
        if pct != 0 {
            let f = 1 + Double(pct) / 100
            for i in week.sessions.indices where week.sessions[i].type != .race {
                week.sessions[i].distanceKm = max(PlanEngine.roundHalf(week.sessions[i].distanceKm * f), 2)
            }
        }

        // Per-day changes. Without a flagged signal the draft stands.
        for c in d.changes where anyFlag || c.action == .keep {
            guard let day = dayNames.firstIndex(of: c.day).map({ $0 + 1 }),
                  let i = week.sessions.firstIndex(where: { $0.weekday == day }) else {
                if c.action != .keep { hits.append("ignored change for \(c.day): no session that day") }
                continue
            }
            let s = week.sessions[i]
            if s.type == .race {
                hits.append("ignored \(c.action.rawValue) on race day")
                continue
            }
            switch c.action {
            case .keep:
                continue
            case .make_easy:
                guard s.type.isHard || s.type == .long else { continue }
                var easy = PlanEngine.makeSession(type: s.type == .long ? .long : .easy, weekday: day, km: s.distanceKm, metrics: m)
                if s.type == .long { easy.distanceKm = PlanEngine.roundHalf(s.distanceKm * 0.8) }
                easy.id = s.id
                easy.note = c.reason
                week.sessions[i] = easy
            case .shorten:
                week.sessions[i].distanceKm = max(PlanEngine.roundHalf(s.distanceKm * 0.75), 2)
                week.sessions[i].note = c.reason
            case .drop:
                if s.type == .long {
                    hits.append("kept the long run: shortened instead of dropped")
                    week.sessions[i].distanceKm = max(PlanEngine.roundHalf(s.distanceKm * 0.75), 2)
                    week.sessions[i].note = c.reason
                } else if !anyFlag {
                    hits.append("ignored drop on \(c.day): no signal flagged")
                } else if draft.sessions.count - week.sessions.count >= 1 {
                    hits.append("ignored drop on \(c.day): at most one run dropped per week")
                } else {
                    week.sessions.remove(at: i)
                }
            }
        }

        // Easy pace adjustment (slower only).
        // Field means "slower by". A negative number is the same intent with the sign flipped.
        var adj = min(abs(d.easyPaceAdjustSec), 30)
        if adj != abs(d.easyPaceAdjustSec) { hits.append("easy pace slowdown \(d.easyPaceAdjustSec)s clamped to \(adj)s") }
        if let drift = m.hrDriftPct, drift > 5, adj < 10 {
            hits.append("floor: easy pace slowdown \(adj)s -> 10s for HR drift \(drift)%")
            adj = 10
        } else if m.hrDriftPct.map({ $0 <= 5 }) ?? true, !anyFlag, adj > 0 {
            hits.append("easy pace slowdown \(adj)s ignored: no signal flagged")
            adj = 0
        }
        if adj > 0 {
            for i in week.sessions.indices where [.easy, .long, .recovery].contains(week.sessions[i].type) {
                if let p = week.sessions[i].pace {
                    week.sessions[i].pace = PaceRange(fast: p.fast + Double(adj), slow: p.slow + Double(adj))
                }
            }
        }

        // Hard safety rules
        if let gap = m.daysSinceLastRun, gap >= 14 {
            for i in week.sessions.indices where week.sessions[i].type == .tempo || week.sessions[i].type == .intervals {
                hits.append("\(dayNames[week.sessions[i].weekday - 1]) \(week.sessions[i].type.rawValue) made easy: \(gap) days since last run")
                week.sessions[i] = easier(week.sessions[i], m, note: "Back after \(gap) days off. Easy running first.")
            }
        }
        let maxHard = (m.acwr ?? 0) > 1.5 ? 1 : 2
        let hard = week.sessions.indices.filter { week.sessions[$0].type == .tempo || week.sessions[$0].type == .intervals }
        for i in hard.dropFirst(maxHard) {
            hits.append("\(dayNames[week.sessions[i].weekday - 1]) \(week.sessions[i].type.rawValue) made easy: max \(maxHard) hard sessions")
            week.sessions[i] = easier(week.sessions[i], m, note: "Load is high, so one quality session this week.")
        }
        let cap = max(m.baselineWeeklyKm * 1.1 + 2, 12)
        if week.plannedKm > cap + 0.25, week.phase != .race {
            hits.append("weekly total \(Format.km(week.plannedKm)) trimmed to \(Format.km(cap))")
            let f = cap / week.plannedKm
            for i in week.sessions.indices { week.sessions[i].distanceKm = max(PlanEngine.roundHalf(week.sessions[i].distanceKm * f), 2) }
        }

        week.sessions.sort { $0.weekday < $1.weekday }
        return (week, hits)
    }

    static func easier(_ s: Session, _ m: Metrics, note: String) -> Session {
        var e = PlanEngine.makeSession(type: .easy, weekday: s.weekday, km: s.distanceKm, metrics: m)
        e.id = s.id
        e.note = note
        return e
    }

    // MARK: Rule-based fallback

    public static func ruleBased(draft: WeekPlan, metrics m: Metrics, review: WeekReview?) -> CoachResult {
        var changes: [CoachDecision.Change] = []
        var pct = 0, pace = 0
        var reasons: [String] = []
        let hardDays = draft.sessions.filter { $0.type == .tempo || $0.type == .intervals }.map { dayNames[$0.weekday - 1] }

        if let gap = m.daysSinceLastRun, gap >= 14 {
            reasons.append("It has been \(gap) days since your last run, so this week is easy running only.")
            changes += hardDays.map { .init(day: $0, action: .make_easy, reason: "\(gap) days since last run") }
        } else if let acwr = m.acwr, acwr > 1.5 {
            pct = -25
            reasons.append(String(format: "Your load ratio is %.2f, which is a big jump. We cut volume 25%% to let your body catch up.", acwr))
            changes += hardDays.dropFirst().map { .init(day: $0, action: .make_easy, reason: String(format: "acwr %.2f", acwr)) }
        } else if let acwr = m.acwr, acwr > 1.3 {
            pct = -10
            reasons.append(String(format: "Your load ratio is %.2f, a bit high. Volume is down 10%% this week.", acwr))
        }
        if let r = review, r.compliancePct < 60 {
            pct = min(pct, -15)
            reasons.append("You finished \(r.compliancePct)% of last week, so this week stays lighter.")
        }
        if let drift = m.hrDriftPct, drift > 5 {
            pace = 15
            reasons.append(String(format: "Your HR drifted %.1f%% on recent runs. Slow your easy runs by 15 s/km.", drift))
        }
        if reasons.isEmpty {
            reasons.append("Your recent training looks steady, so we progress as planned.")
        }

        let decision = CoachDecision(
            assessment: reasons.first!, volumeChangePct: pct, easyPaceAdjustSec: pace, changes: changes,
            message: reasons.joined(separator: " ")
        )
        var (week, hits) = apply(decision, to: draft, metrics: m, review: review)
        week.coachSummary = decision.message
        week.coachSource = "rules"
        return CoachResult(week: week, decision: decision, source: "rules", guardrailHits: hits, rawOutput: nil, error: nil, latency: 0)
    }
}
