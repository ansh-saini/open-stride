@testable import CoachKit
import XCTest

final class MetricsTests: XCTestCase {
    func testVDOTMatchesDanielsTable() {
        // Daniels: 5K in 20:00 is VDOT ~49.8, 10K in 50:00 is ~39.9.
        XCTAssertEqual(MetricsCalculator.vdot(meters: 5000, seconds: 20 * 60), 49.8, accuracy: 0.5)
        XCTAssertEqual(MetricsCalculator.vdot(meters: 10000, seconds: 50 * 60), 39.9, accuracy: 0.5)
    }

    func testPredictionInvertsVDOT() {
        let t = MetricsCalculator.predictTime(vdot: 49.8, meters: 5000)
        XCTAssertEqual(t, 20 * 60, accuracy: 10)
    }

    func testPaceZonesNearDaniels() {
        // VDOT 50: threshold ~4:15/km, easy ~5:00-5:35/km.
        let p = MetricsCalculator.paceZones(vdot: 50)
        XCTAssertEqual(p.threshold.fast, 255, accuracy: 10)
        XCTAssertEqual(p.easy.fast, 300, accuracy: 15)
        XCTAssertLessThan(p.interval.fast, p.threshold.fast)
        XCTAssertLessThan(p.easy.fast, p.easy.slow)
    }

    func testKarvonenZones() {
        let z = MetricsCalculator.hrZones(maxHR: 190, restingHR: 50)
        XCTAssertEqual(z[1].low, 134) // 50 + 0.6 * 140
        XCTAssertEqual(z[4].high, 190)
    }

    func testMaxHRPrefersObservedWhenPlausible() {
        let now = Date()
        let runs = [Run(start: now.addingTimeInterval(-86400), duration: 1800, distanceMeters: 5000, avgHR: 160, maxHR: 196)]
        XCTAssertEqual(MetricsCalculator.estimateMaxHR(runs: runs, age: 30, now: now).0, 196)
        let soft = [Run(start: now.addingTimeInterval(-86400), duration: 1800, distanceMeters: 5000, avgHR: 130, maxHR: 150)]
        XCTAssertEqual(MetricsCalculator.estimateMaxHR(runs: soft, age: 30, now: now).0, 187)
    }

    func testOverreachingHasHighACWR() {
        let s = Synthetic.scenario(.overreaching)
        let m = MetricsCalculator.compute(s.data, now: s.now)
        XCTAssertGreaterThan(m.acwr ?? 0, 1.5)
    }

    func testDetrainedGap() {
        let s = Synthetic.scenario(.detrained)
        let m = MetricsCalculator.compute(s.data, now: s.now)
        XCTAssertGreaterThanOrEqual(m.daysSinceLastRun ?? 0, 14)
    }

    func testHRVDOTRaisesSubmaximalEstimate() {
        // A runner who never races: 4 km at 8:06/km at 85% HRR. Race formula says ~21; HR says ~23.
        let now = Date()
        let runs = (1...3).map { i in
            Run(start: now.addingTimeInterval(Double(-i) * 86400), duration: 4.0 * 486, distanceMeters: 4000, avgHR: 164, maxHR: 181)
        }
        let (v, source) = MetricsCalculator.estimateVDOT(runs: runs, appleVO2: nil, now: now, maxHR: 181, restingHR: 63.5)
        XCTAssertEqual(v, 22.7, accuracy: 0.5)
        XCTAssertEqual(source, "heart rate on your recent runs")
    }

    func testNoRunsStillWorks() {
        let m = MetricsCalculator.compute(AthleteData(runs: [], physiology: Physiology()))
        XCTAssertEqual(m.vdot, 30)
        XCTAssertNil(m.acwr)
    }
}

final class PlanEngineTests: XCTestCase {
    func testInvariantsAcrossPersonasAndDays() {
        for persona in Persona.allCases {
            for days in 3...6 {
                let s = Synthetic.scenario(persona)
                let goal = Goal(race: s.goal.race, raceDate: s.goal.raceDate, daysPerWeek: days)
                let m = MetricsCalculator.compute(s.data, now: s.now)
                let w = PlanEngine.draftWeek(goal: goal, metrics: m, now: s.now, planStart: s.planStart)
                let label = "\(persona) \(days)d"

                XCTAssertEqual(w.sessions.count, days, label)
                XCTAssertEqual(Set(w.sessions.map(\.weekday)).count, days, "\(label): two runs on one day")
                let long = w.sessions.first { $0.type == .long }
                XCTAssertNotNil(long, label)
                XCTAssertEqual(long?.distanceKm, w.sessions.map(\.distanceKm).max(), "\(label): long run is not the longest")

                let hardDays = w.sessions.filter { $0.type.isHard }.map(\.weekday).sorted()
                for (a, b) in zip(hardDays, hardDays.dropFirst()) {
                    XCTAssertGreaterThan(b - a, 1, "\(label): hard days back to back")
                }
                XCTAssertTrue(w.sessions.allSatisfy { $0.distanceKm >= 2 }, label)
            }
        }
    }

    func testRaceWeekHasRace() {
        let s = Synthetic.scenario(.steady)
        let raceDate = Calendar.coach.date(byAdding: .day, value: 5, to: s.now)!
        let goal = Goal(race: .tenK, raceDate: raceDate, daysPerWeek: 4)
        let m = MetricsCalculator.compute(s.data, now: s.now)
        let w = PlanEngine.draftWeek(goal: goal, metrics: m, now: s.now)
        XCTAssertEqual(w.phase, .race)
        XCTAssertEqual(w.sessions.last?.type, .race)
        XCTAssertFalse(w.sessions.contains { $0.weekday > Calendar.coach.coachWeekday(raceDate) })
    }

    func testCutbackEveryFourthWeek() {
        let s = Synthetic.scenario(.steady)
        let start = Calendar.coach.date(byAdding: .day, value: -21, to: s.now)!
        let m = MetricsCalculator.compute(s.data, now: s.now)
        let ctx = PlanEngine.context(goal: s.goal, metrics: m, now: s.now, planStart: start)
        XCTAssertEqual(ctx.weekNumber, 4)
        XCTAssertTrue(ctx.isCutback)
    }
}

final class GuardrailTests: XCTestCase {
    func setup(_ p: Persona) -> (WeekPlan, Metrics, WeekReview?) {
        let s = Synthetic.scenario(p)
        let m = MetricsCalculator.compute(s.data, now: s.now)
        let d = PlanEngine.draftWeek(goal: s.goal, metrics: m, now: s.now, planStart: s.planStart)
        return (d, m, WeekReview.make(previous: s.previous, runs: s.data.runs))
    }

    func decision(volume: Int = 0, pace: Int = 0, changes: [CoachDecision.Change] = []) -> CoachDecision {
        CoachDecision(assessment: "", volumeChangePct: volume, easyPaceAdjustSec: pace, changes: changes, message: "")
    }

    func testNoFlagMeansDraftStands() {
        let (draft, m, r) = setup(.steady)
        let (w, hits) = CoachAgent.apply(decision(volume: -30, pace: 20, changes: [.init(day: "Sun", action: .drop, reason: "x")]), to: draft, metrics: m, review: r)
        XCTAssertEqual(w.plannedKm, draft.plannedKm)
        XCTAssertEqual(w.sessions.count, draft.sessions.count)
        XCTAssertFalse(hits.isEmpty)
    }

    func testOverreachingFloorCutsVolume() {
        let (draft, m, r) = setup(.overreaching)
        let (w, hits) = CoachAgent.apply(decision(), to: draft, metrics: m, review: r)
        XCTAssertLessThan(w.plannedKm, draft.plannedKm * 0.85)
        XCTAssertTrue(hits.contains { $0.hasPrefix("floor") })
        XCTAssertLessThanOrEqual(w.sessions.filter { $0.type == .tempo || $0.type == .intervals }.count, 1)
    }

    func testLongRunCannotBeDropped() {
        let (draft, m, r) = setup(.overreaching)
        let longDay = CoachAgent.dayNames[draft.sessions.first { $0.type == .long }!.weekday - 1]
        let (w, _) = CoachAgent.apply(decision(volume: -20, changes: [.init(day: longDay, action: .drop, reason: "x")]), to: draft, metrics: m, review: r)
        XCTAssertTrue(w.sessions.contains { $0.type == .long })
    }

    func testAtMostOneDrop() {
        let (draft, m, r) = setup(.missedSessions)
        let days = draft.sessions.filter { $0.type != .long }.map { CoachAgent.dayNames[$0.weekday - 1] }
        let (w, _) = CoachAgent.apply(decision(volume: -10, changes: days.map { .init(day: $0, action: .drop, reason: "x") }), to: draft, metrics: m, review: r)
        XCTAssertEqual(w.sessions.count, draft.sessions.count - 1)
    }

    func testDetrainedHasNoHardSessions() {
        let s = Synthetic.scenario(.detrained)
        let m = MetricsCalculator.compute(s.data, now: s.now)
        let goal = Goal(race: .tenK, raceDate: s.goal.raceDate, daysPerWeek: 5)
        let draft = PlanEngine.draftWeek(goal: goal, metrics: m, now: s.now, planStart: Calendar.coach.date(byAdding: .day, value: -35, to: s.now))
        let (w, _) = CoachAgent.apply(decision(), to: draft, metrics: m, review: nil)
        XCTAssertFalse(w.sessions.contains { $0.type == .tempo || $0.type == .intervals })
    }

    func testNegativePaceMeansSlower() {
        let (draft, m, r) = setup(.hrDrift)
        let (w, _) = CoachAgent.apply(decision(pace: -15), to: draft, metrics: m, review: r)
        let before = draft.sessions.first { $0.type == .easy }!.pace!.slow
        let after = w.sessions.first { $0.type == .easy }!.pace!.slow
        XCTAssertEqual(after - before, 15)
    }

    func testParseToleratesFencesAndProse() throws {
        let text = """
        Here is my plan:
        ```json
        {"assessment":"ok","volume_change_pct":-10,"slow_easy_pace_by_sec":0,"changes":[{"day":"Wed","action":"make_easy","reason":"acwr 1.4"}],"message":"Easy week."}
        ```
        """
        let d = try CoachAgent.parse(text)
        XCTAssertEqual(d.volumeChangePct, -10)
        XCTAssertEqual(d.changes.first?.action, .make_easy)
    }

    func testParseLenientShapes() throws {
        let text = #"{"assessment":"x","volume_change_pct":"-20%","slow_easy_pace_by_sec":12.0,"changes":["Wed: make_easy because load ratio 1.98", {"day":"Friday","action":"Shorten"}, {"day":"Sun","action":"reduce"}],"message":"Easier week."}"#
        let d = try CoachAgent.parse(text)
        XCTAssertEqual(d.volumeChangePct, -20)
        XCTAssertEqual(d.easyPaceAdjustSec, 12)
        XCTAssertEqual(d.changes.map(\.day), ["Wed", "Fri"])
        XCTAssertEqual(d.changes.map(\.action), [.make_easy, .shorten])
    }

    func testFallbackWhenModelFails() async {
        struct Broken: LLMClient {
            var name = "broken"
            func complete(system: String, user: String, schema: [String: any Sendable]) async throws -> String { "not json" }
        }
        let s = Synthetic.scenario(.overreaching)
        let r = await CoachAgent(llm: Broken()).planWeek(goal: s.goal, data: s.data, previous: s.previous, planStart: s.planStart, now: s.now)
        XCTAssertEqual(r.source, "rules")
        XCTAssertNotNil(r.error)
        XCTAssertEqual(r.week.coachSource, "rules")
    }
}
