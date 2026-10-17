import Foundation

/// Builds a deterministic week of training from metrics and the goal.
/// The coach agent adjusts this draft; it never writes a week from scratch.
public enum PlanEngine {
    public struct Context: Sendable {
        public var weekStart: Date
        public var weekNumber: Int
        public var totalWeeks: Int
        public var weeksToRace: Int
        public var phase: Phase
        public var isCutback: Bool
        public var targetKm: Double
    }

    public static func context(goal: Goal, metrics: Metrics, now: Date, planStart: Date? = nil, calendar: Calendar = .coach) -> Context {
        let weekStart = calendar.startOfWeek(for: now)
        let raceWeek = calendar.startOfWeek(for: goal.raceDate)
        let start = calendar.startOfWeek(for: planStart ?? now)
        let weeksToRace = max(weeksBetween(weekStart, raceWeek, calendar) + 1, 1)
        let totalWeeks = max(weeksBetween(start, raceWeek, calendar) + 1, 1)
        let weekNumber = min(max(weeksBetween(start, weekStart, calendar) + 1, 1), totalWeeks)

        let taperWeeks = goal.race == .fiveK || goal.race == .tenK ? 1 : 2
        let phase: Phase
        if weeksToRace == 1 {
            phase = .race
        } else if weeksToRace <= taperWeeks + 1 {
            phase = .taper
        } else {
            let progress = Double(weekNumber) / Double(max(totalWeeks - taperWeeks - 1, 1))
            phase = progress <= 0.4 ? .base : progress <= 0.8 ? .build : .peak
        }
        let isCutback = phase != .taper && phase != .race && weekNumber % 4 == 0

        // Start from the 4-week average, not last week, so a one-week spike does not set the bar.
        let floorKm = Double(goal.daysPerWeek) * 3
        var current = max(metrics.baselineWeeklyKm, floorKm)
        if let gap = metrics.daysSinceLastRun, gap >= 14 {
            current = max(metrics.baselineWeeklyKm * 0.5, floorKm)
        }
        let peak = goal.race.peakWeeklyKm * [3: 0.7, 4: 0.85][goal.daysPerWeek, default: 1.0]
        var target = min(current * 1.08, max(peak, current))
        switch phase {
        case .taper: target = current * (weeksToRace == 2 ? 0.7 : 0.8)
        case .race: target = current * 0.5
        default: if isCutback { target *= 0.8 }
        }

        return Context(
            weekStart: weekStart, weekNumber: weekNumber, totalWeeks: totalWeeks, weeksToRace: weeksToRace,
            phase: phase, isCutback: isCutback, targetKm: roundHalf(target)
        )
    }

    public static func draftWeek(goal: Goal, metrics: Metrics, now: Date = .now, planStart: Date? = nil, calendar: Calendar = .coach) -> WeekPlan {
        let ctx = context(goal: goal, metrics: metrics, now: now, planStart: planStart, calendar: calendar)
        let raceWeekday = calendar.coachWeekday(goal.raceDate)
        let long = goal.longRunWeekday

        // Day slots relative to the long run day: (offset, role).
        let layout: [(Int, Role)] = switch goal.daysPerWeek {
        case 3: [(-5, .hard1), (-3, .easy)]
        case 4: [(-6, .easy), (-4, .hard1), (-2, .easy)]
        case 5: [(-5, .hard1), (-4, .easy), (-3, .hard2), (-1, .recovery)]
        default: [(-6, .easy), (-5, .hard1), (-4, .easy), (-3, .hard2), (-1, .recovery)]
        }

        let p = metrics.paces
        let easyPace = p.easy
        let longPace = PaceRange(fast: p.easy.fast + 10, slow: p.easy.slow)
        let target = ctx.targetKm
        let minRun = target < 15 ? 2.0 : 3.0

        // Long run: about 30% of the week (more on low volume), no more than ~15% longer than anything recent.
        let recentLong = max(metrics.longestRecentRunKm, 3)
        var longKm = roundHalf(min(max(target * 0.3, target / Double(goal.daysPerWeek) * 1.25), goal.race.longRunCapKm, recentLong * 1.15 + 1))
        longKm = max(longKm, minRun + 1)

        var sessions: [Session] = []
        let hardTypes = hardSessions(phase: ctx.phase, baselineKm: metrics.baselineWeeklyKm)

        for (offset, role) in layout {
            let weekday = wrap(long + offset)
            switch role {
            case .hard1, .hard2:
                let type = role == .hard1 ? hardTypes.0 : hardTypes.1
                let km = roundHalf(max(target * (type == .intervals ? 0.17 : 0.18), minRun + 1))
                sessions.append(makeSession(type: type, weekday: weekday, km: km, metrics: metrics))
            case .recovery:
                sessions.append(Session(weekday: weekday, type: .recovery, distanceKm: roundHalf(max(target * 0.1, minRun)),
                                        pace: p.recovery, hrZone: 1, detail: "Very easy. Conversation pace. Walk breaks are fine."))
            case .easy:
                sessions.append(Session(weekday: weekday, type: .easy, distanceKm: 0, pace: easyPace, hrZone: 2,
                                        detail: "Easy aerobic run. Keep HR in zone 2."))
            }
        }

        if ctx.phase == .race {
            sessions.removeAll { $0.weekday >= raceWeekday || $0.type == .recovery }
            sessions.append(Session(weekday: raceWeekday, type: .race, distanceKm: goal.race.meters / 1000,
                                    pace: nil, hrZone: nil, detail: "Race day: \(goal.race.rawValue). Start controlled, finish strong."))
        } else {
            sessions.append(Session(weekday: long, type: .long, distanceKm: longKm, pace: longPace, hrZone: 2,
                                    detail: "Long run at easy effort. Relaxed and steady."))
        }

        // Easy runs fill whatever volume is left.
        let fixed = sessions.filter { $0.type != .easy }.map(\.distanceKm).reduce(0, +)
        let raceKm = ctx.phase == .race ? goal.race.meters / 1000 : 0
        let easyCount = sessions.filter { $0.type == .easy }.count
        if easyCount > 0 {
            let each = roundHalf(max((target + raceKm - fixed) / Double(easyCount), minRun))
            for i in sessions.indices where sessions[i].type == .easy { sessions[i].distanceKm = each }
        }

        sessions.sort { $0.weekday < $1.weekday }
        return WeekPlan(
            weekStart: ctx.weekStart, weekNumber: ctx.weekNumber, totalWeeks: ctx.totalWeeks,
            phase: ctx.phase, isCutback: ctx.isCutback, sessions: sessions
        )
    }

    enum Role { case easy, hard1, hard2, recovery }

    static func hardSessions(phase: Phase, baselineKm: Double) -> (SessionType, SessionType) {
        switch phase {
        case .base: (baselineKm >= 15 ? .tempo : .easy, .easy)
        case .build: (.tempo, .intervals)
        case .peak: (.intervals, .tempo)
        case .taper: (.intervals, .easy)
        case .race: (.tempo, .easy)
        }
    }

    public static func makeSession(type: SessionType, weekday: Int, km: Double, metrics: Metrics) -> Session {
        let p = metrics.paces
        switch type {
        case .tempo:
            let workKm = max(km - 3, 1)
            let minutes = Int((workKm * p.threshold.slow / 60).rounded())
            let main = minutes >= 16
                ? "\(minutes / 8) x 8 min at threshold with 2 min jog between"
                : "\(max(minutes, 6)) min steady at threshold"
            return Session(weekday: weekday, type: .tempo, distanceKm: km, pace: p.threshold, hrZone: 4,
                           detail: "1.5 km warm-up, \(main), 1.5 km cool-down.")
        case .intervals:
            let reps = max(Int(((km - 3) / 1.2).rounded(.down)), 3)
            return Session(weekday: weekday, type: .intervals, distanceKm: km, pace: p.interval, hrZone: 5,
                           detail: "1.5 km warm-up, \(reps) x 800 m at interval pace with 400 m jog, 1.5 km cool-down.")
        case .easy:
            return Session(weekday: weekday, type: .easy, distanceKm: km, pace: p.easy, hrZone: 2,
                           detail: "Easy aerobic run. Add 4 x 20 s relaxed strides at the end.")
        case .recovery:
            return Session(weekday: weekday, type: .recovery, distanceKm: km, pace: p.recovery, hrZone: 1,
                           detail: "Very easy. Conversation pace. Walk breaks are fine.")
        case .long:
            return Session(weekday: weekday, type: .long, distanceKm: km, pace: PaceRange(fast: p.easy.fast + 10, slow: p.easy.slow), hrZone: 2,
                           detail: "Long run at easy effort. Relaxed and steady.")
        case .rest, .race:
            return Session(weekday: weekday, type: type, distanceKm: 0, detail: "Rest day. Sleep, stretch, walk.")
        }
    }

    static func wrap(_ day: Int) -> Int { ((day - 1) % 7 + 7) % 7 + 1 }

    static func roundHalf(_ x: Double) -> Double { (x * 2).rounded() / 2 }

    static func weeksBetween(_ a: Date, _ b: Date, _ calendar: Calendar) -> Int {
        Int((calendar.dateComponents([.day], from: a, to: b).day ?? 0) / 7)
    }
}
