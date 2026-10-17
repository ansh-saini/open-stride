import Foundation

/// One completed run, as read from HealthKit (or generated for tests).
public struct Run: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Date
    public var duration: TimeInterval
    public var distanceMeters: Double
    public var avgHR: Double?
    public var maxHR: Double?
    /// Average HR in the first and second half of the run. Used for drift.
    public var firstHalfHR: Double?
    public var secondHalfHR: Double?

    public init(
        id: UUID = UUID(), start: Date, duration: TimeInterval, distanceMeters: Double,
        avgHR: Double? = nil, maxHR: Double? = nil, firstHalfHR: Double? = nil, secondHalfHR: Double? = nil
    ) {
        self.id = id
        self.start = start
        self.duration = duration
        self.distanceMeters = distanceMeters
        self.avgHR = avgHR
        self.maxHR = maxHR
        self.firstHalfHR = firstHalfHR
        self.secondHalfHR = secondHalfHR
    }

    public var distanceKm: Double { distanceMeters / 1000 }
    /// Seconds per km.
    public var pace: Double { distanceMeters > 0 ? duration / distanceKm : 0 }
}

public struct Physiology: Codable, Hashable, Sendable {
    public var age: Int?
    public var restingHR: Double?
    public var vo2Max: Double?
    public var bodyMassKg: Double?

    public init(age: Int? = nil, restingHR: Double? = nil, vo2Max: Double? = nil, bodyMassKg: Double? = nil) {
        self.age = age
        self.restingHR = restingHR
        self.vo2Max = vo2Max
        self.bodyMassKg = bodyMassKg
    }
}

public struct AthleteData: Codable, Hashable, Sendable {
    public var runs: [Run]
    public var physiology: Physiology

    public init(runs: [Run], physiology: Physiology) {
        self.runs = runs.sorted { $0.start < $1.start }
        self.physiology = physiology
    }
}

public enum RaceDistance: String, Codable, CaseIterable, Sendable {
    case fiveK = "5K", tenK = "10K", half = "Half marathon", marathon = "Marathon"

    public var meters: Double {
        switch self {
        case .fiveK: 5000
        case .tenK: 10000
        case .half: 21097.5
        case .marathon: 42195
        }
    }

    /// Weekly km we aim to peak at, for a recreational runner.
    var peakWeeklyKm: Double {
        switch self {
        case .fiveK: 30
        case .tenK: 40
        case .half: 50
        case .marathon: 65
        }
    }

    /// Longest long run in the plan, km.
    var longRunCapKm: Double {
        switch self {
        case .fiveK: 12
        case .tenK: 16
        case .half: 21
        case .marathon: 32
        }
    }
}

public struct Goal: Codable, Hashable, Sendable {
    public var race: RaceDistance
    public var raceDate: Date
    public var daysPerWeek: Int
    /// 1 = Monday ... 7 = Sunday.
    public var longRunWeekday: Int

    public init(race: RaceDistance, raceDate: Date, daysPerWeek: Int, longRunWeekday: Int = 7) {
        self.race = race
        self.raceDate = raceDate
        self.daysPerWeek = min(max(daysPerWeek, 3), 6)
        self.longRunWeekday = min(max(longRunWeekday, 1), 7)
    }
}

public enum SessionType: String, Codable, CaseIterable, Sendable {
    case easy, long, tempo, intervals, recovery, rest, race

    public var isHard: Bool { self == .tempo || self == .intervals || self == .race }
}

public struct PaceRange: Codable, Hashable, Sendable {
    /// Seconds per km. `fast` < `slow`.
    public var fast: Double
    public var slow: Double

    public init(fast: Double, slow: Double) {
        self.fast = fast
        self.slow = slow
    }
}

public struct Session: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// 1 = Monday ... 7 = Sunday.
    public var weekday: Int
    public var type: SessionType
    public var distanceKm: Double
    public var pace: PaceRange?
    public var hrZone: Int?
    public var detail: String
    public var note: String?

    public init(
        id: UUID = UUID(), weekday: Int, type: SessionType, distanceKm: Double,
        pace: PaceRange? = nil, hrZone: Int? = nil, detail: String, note: String? = nil
    ) {
        self.id = id
        self.weekday = weekday
        self.type = type
        self.distanceKm = distanceKm
        self.pace = pace
        self.hrZone = hrZone
        self.detail = detail
        self.note = note
    }
}

public enum Phase: String, Codable, Sendable {
    case base = "Base", build = "Build", peak = "Peak", taper = "Taper", race = "Race week"
}

public struct WeekPlan: Codable, Hashable, Sendable {
    public var weekStart: Date
    public var weekNumber: Int
    public var totalWeeks: Int
    public var phase: Phase
    public var isCutback: Bool
    public var sessions: [Session]
    public var coachSummary: String?
    /// Where the summary came from: the model name, or "rules" for the fallback coach.
    public var coachSource: String?

    public var plannedKm: Double { sessions.reduce(0) { $0 + $1.distanceKm } }
}
