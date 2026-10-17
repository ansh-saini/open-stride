import Foundation

public struct HRZone: Codable, Hashable, Sendable {
    public var zone: Int
    public var low: Int
    public var high: Int
}

public struct PaceZones: Codable, Hashable, Sendable {
    public var easy: PaceRange
    public var marathon: PaceRange
    public var threshold: PaceRange
    public var interval: PaceRange
    public var recovery: PaceRange
}

public struct WeekVolume: Codable, Hashable, Sendable {
    public var weekStart: Date
    public var km: Double
    public var runs: Int
}

public struct Metrics: Codable, Hashable, Sendable {
    public var maxHR: Int
    public var maxHRSource: String
    public var restingHR: Int?
    public var hrZones: [HRZone]
    public var vdot: Double
    public var vdotSource: String
    public var paces: PaceZones
    public var predictions: [String: TimeInterval]
    public var acuteLoad: Double
    public var chronicLoad: Double
    /// Acute:chronic workload ratio. nil without enough history.
    public var acwr: Double?
    public var weekly: [WeekVolume]
    /// Mean weekly km over the last 4 full weeks.
    public var baselineWeeklyKm: Double
    public var longestRecentRunKm: Double
    /// Average HR rise from first to second half on recent runs, percent.
    public var hrDriftPct: Double?
    public var daysSinceLastRun: Int?
    public var runsLast28Days: Int
}

public enum MetricsCalculator {
    public static func compute(_ data: AthleteData, now: Date = .now, calendar: Calendar = .coach) -> Metrics {
        let runs = data.runs.filter { $0.start <= now }
        let rest = data.physiology.restingHR

        let (maxHR, maxSource) = estimateMaxHR(runs: runs, age: data.physiology.age, now: now)
        let zones = hrZones(maxHR: maxHR, restingHR: rest)

        let (vdot, vdotSource) = estimateVDOT(runs: runs, appleVO2: data.physiology.vo2Max, now: now,
                                              maxHR: Double(maxHR), restingHR: rest)
        let paces = paceZones(vdot: vdot)
        var predictions: [String: TimeInterval] = [:]
        for race in RaceDistance.allCases {
            predictions[race.rawValue] = predictTime(vdot: vdot, meters: race.meters)
        }

        let load: (Run) -> Double = { trimp($0, maxHR: Double(maxHR), restingHR: rest) }
        let acute = runs.filter { now.timeIntervalSince($0.start) < 7 * 86400 }.map(load).reduce(0, +)
        let chronicTotal = runs.filter { now.timeIntervalSince($0.start) < 28 * 86400 }.map(load).reduce(0, +)
        let chronic = chronicTotal / 4
        let acwr: Double? = chronic > 20 ? acute / chronic : nil

        let weekly = weeklyVolumes(runs: runs, now: now, weeks: 8, calendar: calendar)
        let fullWeeks = weekly.dropLast().suffix(4)
        let baseline = fullWeeks.isEmpty ? 0 : fullWeeks.map(\.km).reduce(0, +) / Double(fullWeeks.count)

        let recent = runs.filter { now.timeIntervalSince($0.start) < 28 * 86400 }
        let longest = recent.map(\.distanceKm).max() ?? 0

        let drifts = runs.filter { now.timeIntervalSince($0.start) < 21 * 86400 }
            .compactMap { r -> Double? in
                guard let a = r.firstHalfHR, let b = r.secondHalfHR, a > 0, r.duration >= 20 * 60 else { return nil }
                return (b - a) / a * 100
            }
        let drift = drifts.isEmpty ? nil : drifts.reduce(0, +) / Double(drifts.count)

        let daysSince = runs.last.map { Int(now.timeIntervalSince($0.start) / 86400) }

        return Metrics(
            maxHR: maxHR, maxHRSource: maxSource, restingHR: rest.map { Int($0.rounded()) },
            hrZones: zones, vdot: vdot, vdotSource: vdotSource, paces: paces, predictions: predictions,
            acuteLoad: acute.rounded(), chronicLoad: chronic.rounded(), acwr: acwr.map { ($0 * 100).rounded() / 100 },
            weekly: weekly, baselineWeeklyKm: (baseline * 10).rounded() / 10,
            longestRecentRunKm: (longest * 10).rounded() / 10, hrDriftPct: drift.map { ($0 * 10).rounded() / 10 },
            daysSinceLastRun: daysSince, runsLast28Days: recent.count
        )
    }

    // MARK: Heart rate

    static func estimateMaxHR(runs: [Run], age: Int?, now: Date) -> (Int, String) {
        let formula = age.map { 208 - 0.7 * Double($0) }
        let observed = runs
            .filter { now.timeIntervalSince($0.start) < 180 * 86400 }
            .compactMap(\.maxHR)
            .filter { $0 < 225 }
            .max()
        switch (observed, formula) {
        case let (obs?, f?) where obs >= f * 0.95:
            return (Int(obs.rounded()), "highest HR seen in your runs")
        case let (_, f?):
            return (Int(f.rounded()), "age formula (208 - 0.7 x age)")
        case let (obs?, nil):
            return (Int(obs.rounded()), "highest HR seen in your runs")
        default:
            return (190, "default")
        }
    }

    /// Karvonen zones when resting HR is known, else percent of max.
    static func hrZones(maxHR: Int, restingHR: Double?) -> [HRZone] {
        let bounds: [(Double, Double)] = [(0.5, 0.6), (0.6, 0.7), (0.7, 0.8), (0.8, 0.9), (0.9, 1.0)]
        let mx = Double(maxHR)
        return bounds.enumerated().map { i, b in
            let bpm: (Double) -> Int = { f in
                if let r = restingHR { return Int((r + f * (mx - r)).rounded()) }
                return Int((f * mx).rounded())
            }
            return HRZone(zone: i + 1, low: bpm(b.0), high: bpm(b.1))
        }
    }

    /// Banister TRIMP. Falls back to an easy-run estimate without HR.
    static func trimp(_ run: Run, maxHR: Double, restingHR: Double?) -> Double {
        let minutes = run.duration / 60
        guard let avg = run.avgHR else { return minutes * 1.4 }
        let rest = restingHR ?? 60
        let hrr = min(max((avg - rest) / max(maxHR - rest, 1), 0), 1)
        return minutes * hrr * 0.64 * exp(1.92 * hrr)
    }

    // MARK: VDOT (Jack Daniels)

    static func vo2(velocity v: Double) -> Double { -4.60 + 0.182258 * v + 0.000104 * v * v }

    static func fractionOfMax(minutes t: Double) -> Double {
        0.8 + 0.1894393 * exp(-0.012778 * t) + 0.2989558 * exp(-0.1932605 * t)
    }

    static func vdot(meters: Double, seconds: Double) -> Double {
        let minutes = seconds / 60
        return vo2(velocity: meters / minutes) / fractionOfMax(minutes: minutes)
    }

    static func estimateVDOT(runs: [Run], appleVO2: Double?, now: Date, maxHR: Double? = nil, restingHR: Double? = nil) -> (Double, String) {
        let recent = runs.filter { now.timeIntervalSince($0.start) < 60 * 86400 && $0.distanceMeters >= 3000 && $0.duration >= 12 * 60 }
        let best = recent
            .map { vdot(meters: $0.distanceMeters, seconds: $0.duration) }
            .filter { $0 > 15 && $0 < 85 }
            .max()
        // Race-effort VDOT assumes the run was all-out. Heart rate reserve says how hard it really was
        // (%HRR tracks %VO2max), so submaximal runs still give a fitness estimate.
        let fromHR = hrVDOT(runs: recent, maxHR: maxHR, restingHR: restingHR)
        switch (best, fromHR) {
        case let (b?, h?) where h > b:
            return ((h * 10).rounded() / 10, "heart rate on your recent runs")
        case let (b?, _):
            return ((b * 10).rounded() / 10, "best effort in the last 60 days")
        case let (nil, h?):
            return ((h * 10).rounded() / 10, "heart rate on your recent runs")
        default:
            if let v = appleVO2 { return ((v * 0.9 * 10).rounded() / 10, "Apple Watch VO2 max estimate") }
            return (30, "default for a new runner")
        }
    }

    /// Median of VO2(pace) / %HRR over runs with heart rate. nil with fewer than 2 usable runs.
    static func hrVDOT(runs: [Run], maxHR: Double?, restingHR: Double?) -> Double? {
        guard let mx = maxHR, let rest = restingHR, mx > rest + 40 else { return nil }
        let estimates = runs.compactMap { r -> Double? in
            guard let hr = r.avgHR else { return nil }
            let hrr = (hr - rest) / (mx - rest)
            guard hrr >= 0.6, hrr <= 1 else { return nil } // too easy to say much
            return vo2(velocity: r.distanceMeters / (r.duration / 60)) / hrr
        }.filter { $0 > 15 && $0 < 85 }.sorted()
        guard estimates.count >= 2 else { return nil }
        return estimates[estimates.count / 2]
    }

    /// Velocity (m/min) at a given VO2.
    static func velocity(vo2 target: Double) -> Double {
        let a = 0.000104, b = 0.182258, c = -4.60 - target
        return (-b + sqrt(b * b - 4 * a * c)) / (2 * a)
    }

    /// Training paces as fractions of velocity at VO2 max (calibrated to Daniels' tables).
    static func paceZones(vdot: Double) -> PaceZones {
        let vMax = velocity(vo2: vdot)
        func p(_ f: Double) -> Double { (1000 / (vMax * f) * 60).rounded() }
        return PaceZones(
            easy: PaceRange(fast: p(0.76), slow: p(0.69)),
            marathon: PaceRange(fast: p(0.86), slow: p(0.84)),
            threshold: PaceRange(fast: p(0.91), slow: p(0.89)),
            interval: PaceRange(fast: p(0.99), slow: p(0.96)),
            recovery: PaceRange(fast: p(0.68), slow: p(0.63))
        )
    }

    static func predictTime(vdot target: Double, meters: Double) -> TimeInterval {
        var lo = 60.0, hi = 60.0 * 60 * 10
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if vdot(meters: meters, seconds: mid) > target { lo = mid } else { hi = mid }
        }
        return hi.rounded()
    }

    // MARK: Volume

    static func weeklyVolumes(runs: [Run], now: Date, weeks: Int, calendar: Calendar) -> [WeekVolume] {
        let thisWeek = calendar.startOfWeek(for: now)
        return (0..<weeks).reversed().map { back in
            let start = calendar.date(byAdding: .day, value: -7 * back, to: thisWeek)!
            let end = calendar.date(byAdding: .day, value: 7, to: start)!
            let inWeek = runs.filter { $0.start >= start && $0.start < end }
            return WeekVolume(weekStart: start, km: (inWeek.map(\.distanceKm).reduce(0, +) * 10).rounded() / 10, runs: inWeek.count)
        }
    }
}

public extension Calendar {
    /// Gregorian, weeks start Monday.
    static var coach: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    func startOfWeek(for date: Date) -> Date {
        dateInterval(of: .weekOfYear, for: date)!.start
    }

    /// 1 = Monday ... 7 = Sunday.
    func coachWeekday(_ date: Date) -> Int {
        (component(.weekday, from: date) + 5) % 7 + 1
    }
}

public enum Format {
    public static func pace(_ secondsPerKm: Double) -> String {
        let s = Int(secondsPerKm.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    public static func paceRange(_ r: PaceRange) -> String { "\(pace(r.fast))-\(pace(r.slow))/km" }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    public static func km(_ km: Double) -> String {
        km == km.rounded() ? String(format: "%.0f km", km) : String(format: "%.1f km", km)
    }
}
