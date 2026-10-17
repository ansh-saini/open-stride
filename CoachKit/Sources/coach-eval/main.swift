import CoachKit
import Foundation

// Usage: swift run coach-eval [--models rules,gemma3:1b,gemma3:4b] [--runs 3] [--persona steady] [--show] [--out results.json]

var models = ["rules", "gemma3:1b", "gemma3:4b"]
var runs = 3
var personas = Persona.allCases
var show = false
var outPath: String?
var athletePath: String?

var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--models": models = args.next()!.split(separator: ",").map(String.init)
    case "--runs": runs = Int(args.next()!)!
    case "--persona": personas = args.next()!.split(separator: ",").map { Persona(rawValue: String($0))! }
    case "--show": show = true
    case "--out": outPath = args.next()
    case "--athlete": athletePath = args.next()
    default: fatalError("unknown arg \(a)")
    }
}

// `--athlete dump.json`: run a real Health export (from the app's -dumpData flag) through the pipeline.
if let athletePath {
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    let data = try dec.decode(AthleteData.self, from: Data(contentsOf: URL(fileURLWithPath: athletePath)))
    let m = MetricsCalculator.compute(data)
    print("VDOT \(m.vdot) (\(m.vdotSource)), max HR \(m.maxHR), easy \(Format.paceRange(m.paces.easy)), threshold \(Format.paceRange(m.paces.threshold))")
    print("baseline \(m.baselineWeeklyKm) km/wk, acwr \(m.acwr.map { String($0) } ?? "-"), drift \(m.hrDriftPct.map { String($0) } ?? "-")")
    let goal = Goal(race: .tenK, raceDate: Date().addingTimeInterval(69 * 86400), daysPerWeek: 4)
    for model in models {
        let r = await CoachAgent(llm: model == "rules" ? nil : OllamaClient(model: model)).planWeek(goal: goal, data: data)
        print("\n[\(model)] \(r.week.coachSummary ?? "")")
        printWeek(r.week)
    }
    exit(0)
}

let coaches: [(String, LLMClient?)] = models.map { ($0, $0 == "rules" ? nil : OllamaClient(model: $0)) }
try await runEval(coaches: coaches, personas: personas, runs: runs, show: show, outPath: outPath)
