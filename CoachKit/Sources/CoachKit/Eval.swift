import Foundation

public struct Trial: Codable, Sendable {
    public var model: String
    public var persona: String
    public var valid: Bool
    public var directionOK: Bool
    public var hardOK: Bool
    public var paceOK: Bool
    public var citesNumber: Bool
    public var guardrailHits: [String]
    public var draftKm: Double
    public var finalKm: Double
    public var latency: Double
    public var message: String
    /// The model's own message was shown (guardrails did not have to replace it).
    public var messageKept: Bool
    public var error: String?

    public var pass: Bool { valid && directionOK && hardOK && paceOK }
    /// Passed without a guardrail floor stepping in: the model's own judgment was enough.
    public var modelPass: Bool { pass && !guardrailHits.contains { $0.hasPrefix("floor") } }
}

public func score(_ s: Synthetic.Scenario, _ r: CoachResult, model: String) -> Trial {
    let m = MetricsCalculator.compute(s.data, now: s.now)
    let draft = PlanEngine.draftWeek(goal: s.goal, metrics: m, now: s.now, planStart: s.planStart)
    let e = s.persona.expectation
    let final = r.week
    let directionOK = switch e.volume {
    case .down: final.plannedKm < draft.plannedKm * 0.95
    case .notDown: final.plannedKm >= draft.plannedKm * 0.9
    case .notUp: final.plannedKm <= (s.previous?.plannedKm ?? .infinity)
    case .any: true
    }
    let hard = final.sessions.filter { $0.type == .tempo || $0.type == .intervals }.count
    let easyDraft = draft.sessions.first { $0.type == .easy }?.pace?.slow ?? 0
    let easyFinal = final.sessions.first { $0.type == .easy }?.pace?.slow ?? 0
    let paceOK = !e.slowerEasy || easyFinal > easyDraft
    let msg = r.week.coachSummary ?? ""
    return Trial(
        model: model, persona: s.persona.rawValue,
        valid: model == "rules" || r.error == nil, directionOK: directionOK, hardOK: hard <= e.maxHard, paceOK: paceOK,
        // Only runners with a flagged signal have a number worth citing.
        citesNumber: [.steady, .beginner].contains(s.persona) || msg.range(of: #"\d"#, options: .regularExpression) != nil,
        guardrailHits: r.guardrailHits, draftKm: draft.plannedKm, finalKm: final.plannedKm,
        latency: r.latency, message: msg, messageKept: r.week.coachSource == r.source, error: r.error
    )
}

public func printWeek(_ w: WeekPlan) {
    for s in w.sessions {
        let pace = s.pace.map { " @ " + Format.paceRange($0) } ?? ""
        let note = s.note.map { "  [\($0)]" } ?? ""
        print("    \(CoachAgent.dayNames[s.weekday - 1])  \(s.type.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(Format.km(s.distanceKm))\(pace)\(note)")
    }
    print("    total \(Format.km(w.plannedKm)), \(w.phase.rawValue) week \(w.weekNumber)/\(w.totalWeeks)")
}

/// Runs every persona through each coach and prints a scorecard.
public func runEval(coaches: [(String, LLMClient?)], personas: [Persona] = Persona.allCases, runs: Int = 3, show: Bool = false, outPath: String? = nil) async throws {
    var trials: [Trial] = []
    let models = coaches.map(\.0)
    for (model, llm) in coaches {
        let agent = CoachAgent(llm: llm)
        for p in personas {
            let s = Synthetic.scenario(p)
            for i in 0..<(model == "rules" ? 1 : runs) {
                let r = await agent.planWeek(goal: s.goal, data: s.data, previous: s.previous, planStart: s.planStart, now: s.now)
                let t = score(s, r, model: model)
                trials.append(t)
                let mark = t.pass ? (t.modelPass ? "PASS" : "PASS(floor)") : "FAIL"
                print("[\(model)] \(p.rawValue) #\(i + 1): \(mark)  km \(t.draftKm)->\(t.finalKm)  \(String(format: "%.1fs", t.latency))"
                    + (t.error.map { "  error: \($0.prefix(120))" } ?? "")
                    + (t.directionOK ? "" : "  [volume]") + (t.hardOK ? "" : "  [hard]") + (t.paceOK ? "" : "  [pace]"))
                if show, t.error != nil, let raw = r.rawOutput {
                print("    raw: \(raw.prefix(400).replacingOccurrences(of: "\n", with: " "))")
            }
            if show && i == 0 {
                    print("    coach: \(t.message)")
                    if !t.guardrailHits.isEmpty { print("    guardrails: \(t.guardrailHits.joined(separator: "; "))") }
                    printWeek(r.week)
                }
            }
        }
    }

    print("\nmodel                      valid  final  model  msg-kept  cites#  guardrail-hits/run  avg-latency")
    for model in models {
        let ts = trials.filter { $0.model == model }
        let n = Double(ts.count)
        func pct(_ f: (Trial) -> Bool) -> String { String(format: "%3.0f%%", Double(ts.filter(f).count) / n * 100) }
        let hits = Double(ts.map(\.guardrailHits.count).reduce(0, +)) / n
        let lat = ts.map(\.latency).reduce(0, +) / n
        print("\(model.padding(toLength: 26, withPad: " ", startingAt: 0)) \(pct(\.valid))   \(pct(\.pass))   \(pct(\.modelPass))    \(pct(\.messageKept))    \(pct(\.citesNumber))    \(String(format: "%.2f", hits))                \(String(format: "%.1fs", lat))")
    }

    if let outPath {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(trials).write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath)")
    }
}
