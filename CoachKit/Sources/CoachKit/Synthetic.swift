import Foundation

/// Seeded fake training histories. Used by tests, the eval harness, and the app's demo mode.
public enum Persona: String, CaseIterable, Codable, Sendable {
    case steady, overreaching, detrained, hrDrift = "hr_drift", missedSessions = "missed_sessions", beginner

    public var summary: String {
        switch self {
        case .steady: "Consistent 25 km/week, normal HR"
        case .overreaching: "Volume doubled in the last week"
        case .detrained: "Fit runner, 3 weeks off"
        case .hrDrift: "Easy runs with high HR drift"
        case .missedSessions: "Did 1 of 4 runs last week"
        case .beginner: "8 km/week, short runs"
        }
    }

    /// What a good coach should do. Checked by the eval harness.
    public var expectation: Expectation {
        switch self {
        case .steady: .init(volume: .notDown, maxHard: 2, slowerEasy: false)
        case .overreaching: .init(volume: .down, maxHard: 1, slowerEasy: false)
        case .detrained: .init(volume: .any, maxHard: 0, slowerEasy: false)
        case .hrDrift: .init(volume: .any, maxHard: 2, slowerEasy: true)
        case .missedSessions: .init(volume: .notUp, maxHard: 2, slowerEasy: false)
        case .beginner: .init(volume: .notDown, maxHard: 1, slowerEasy: false)
        }
    }

    public struct Expectation: Sendable {
        public enum Volume: Sendable { case down, notDown, notUp, any }
        public var volume: Volume
        public var maxHard: Int
        public var slowerEasy: Bool
    }
}

public enum Synthetic {
    public struct Scenario: Sendable {
        public var persona: Persona
        public var data: AthleteData
        public var goal: Goal
        public var previous: WeekPlan?
        public var planStart: Date
        public var now: Date
    }

    /// `now` is a Monday morning so "last week" is complete.
    public static func scenario(_ persona: Persona, now: Date = defaultNow) -> Scenario {
        var rng = SeededRNG(seed: stableSeed(persona.rawValue))
        let cal = Calendar.coach
        let physiology = Physiology(age: 29, restingHR: persona == .beginner ? 68 : 54, vo2Max: persona == .beginner ? 38 : 48, bodyMassKg: 70)

        var runs: [Run] = []
        func add(daysAgo: Double, km: Double, pace: Double, hr: Double, drift: Double = 2.5) {
            let start = now.addingTimeInterval(-daysAgo * 86400 + 7 * 3600)
            let p = pace * Double.random(in: 0.97...1.03, using: &rng)
            let h = hr + Double.random(in: -3...3, using: &rng)
            let first = h * (1 - drift / 200), second = h * (1 + drift / 200)
            runs.append(Run(start: start, duration: km * p, distanceMeters: km * 1000, avgHR: h, maxHR: h + 18, firstHalfHR: first, secondHalfHR: second))
        }

        // 8 weeks of a typical week: Tue easy, Thu tempo-ish, Sat easy, Sun long.
        func typicalWeeks(_ weeks: ClosedRange<Int>, scale: Double, easyPace: Double = 345, easyHR: Double = 142, drift: Double = 2.5) {
            for w in weeks {
                let base = Double((w - 1) * 7)
                add(daysAgo: base + 6, km: 5 * scale, pace: easyPace, hr: easyHR, drift: drift)
                add(daysAgo: base + 4, km: 6 * scale, pace: 290, hr: 165)
                add(daysAgo: base + 2, km: 5 * scale, pace: easyPace, hr: easyHR, drift: drift)
                add(daysAgo: base + 1, km: 9 * scale, pace: easyPace + 10, hr: easyHR + 4, drift: drift)
            }
        }

        var previous: WeekPlan?
        switch persona {
        case .steady:
            typicalWeeks(1...8, scale: 1)
        case .overreaching:
            typicalWeeks(2...8, scale: 0.8)
            typicalWeeks(1...1, scale: 1.9)
            add(daysAgo: 3, km: 8, pace: 300, hr: 160)
        case .detrained:
            typicalWeeks(4...8, scale: 1.1)
        case .hrDrift:
            typicalWeeks(1...8, scale: 1, easyPace: 320, easyHR: 155, drift: 9)
        case .missedSessions:
            typicalWeeks(2...8, scale: 1)
            add(daysAgo: 5, km: 5, pace: 345, hr: 142)
        case .beginner:
            for w in 1...6 {
                let base = Double((w - 1) * 7)
                add(daysAgo: base + 5, km: 2.5, pace: 420, hr: 158)
                add(daysAgo: base + 3, km: 2.5, pace: 420, hr: 158)
                add(daysAgo: base + 1, km: 3, pace: 425, hr: 160)
            }
        }

        let race: RaceDistance = persona == .beginner ? .fiveK : .tenK
        let goal = Goal(race: race, raceDate: cal.date(byAdding: .day, value: 7 * 9 + 6, to: now)!, daysPerWeek: persona == .beginner ? 3 : 4)
        let planStart = cal.date(byAdding: .day, value: -7, to: now)!

        // Every persona except steady/beginner had a plan last week that we can review against.
        let lastWeekStart = cal.startOfWeek(for: planStart)
        previous = WeekPlan(
            weekStart: lastWeekStart, weekNumber: 1, totalWeeks: 11, phase: .base, isCutback: false,
            sessions: [
                Session(weekday: 2, type: .easy, distanceKm: 5, detail: ""),
                Session(weekday: 4, type: .tempo, distanceKm: 6, detail: ""),
                Session(weekday: 6, type: .easy, distanceKm: 5, detail: ""),
                Session(weekday: 7, type: .long, distanceKm: 9, detail: ""),
            ]
        )
        if persona == .beginner {
            previous!.sessions = [
                Session(weekday: 2, type: .easy, distanceKm: 2.5, detail: ""),
                Session(weekday: 4, type: .easy, distanceKm: 2.5, detail: ""),
                Session(weekday: 7, type: .long, distanceKm: 3, detail: ""),
            ]
        }

        return Scenario(persona: persona, data: AthleteData(runs: runs, physiology: physiology), goal: goal,
                        previous: previous, planStart: planStart, now: now)
    }

    /// Monday 2026-10-19 07:00 UTC.
    public static let defaultNow: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 19; c.hour = 7
        return Calendar.coach.date(from: c)!
    }()

    static func stableSeed(_ s: String) -> UInt64 {
        s.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}

/// SplitMix64. Deterministic across runs, unlike the system RNG.
public struct SeededRNG: RandomNumberGenerator, Sendable {
    var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
