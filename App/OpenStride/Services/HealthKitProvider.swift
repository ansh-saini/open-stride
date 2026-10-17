import CoachKit
import Foundation
import HealthKit

/// Reads running history and physiology from Apple Health. Read-only.
actor HealthKitProvider {
    private let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let heartRate = HKQuantityType(.heartRate)
    private let restingHR = HKQuantityType(.restingHeartRate)
    private let vo2Max = HKQuantityType(.vo2Max)
    private let bodyMass = HKQuantityType(.bodyMass)
    private let distance = HKQuantityType(.distanceWalkingRunning)
    private let bpm = HKUnit.count().unitDivided(by: .minute())

    func requestAccess() async throws {
        let types: Set<HKObjectType> = [
            HKObjectType.workoutType(), heartRate, restingHR, vo2Max, bodyMass, distance,
            HKCharacteristicType(.dateOfBirth),
        ]
        try await store.requestAuthorization(toShare: [], read: types)
    }

    func load(days: Int = 180) async throws -> AthleteData {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
        let workouts = try await runningWorkouts(since: since)

        var runs: [Run] = []
        for (i, w) in workouts.enumerated() {
            let km = w.statistics(for: distance)?.sumQuantity()?.doubleValue(for: .meter())
                ?? w.totalDistance?.doubleValue(for: .meter()) ?? 0
            guard km > 500 else { continue }
            let hrStats = w.statistics(for: heartRate)
            var run = Run(
                id: w.uuid, start: w.startDate, duration: w.duration, distanceMeters: km,
                avgHR: hrStats?.averageQuantity()?.doubleValue(for: bpm),
                maxHR: hrStats?.maximumQuantity()?.doubleValue(for: bpm)
            )
            // HR drift only matters for recent runs; skip the per-sample query for old ones.
            if i < 15, run.avgHR != nil, w.duration >= 20 * 60 {
                let (a, b) = try await halves(start: w.startDate, end: w.endDate)
                run.firstHalfHR = a
                run.secondHalfHR = b
            }
            runs.append(run)
        }

        let physiology = Physiology(
            age: age(),
            restingHR: try await average(restingHR, unit: bpm, days: 14),
            vo2Max: try await latest(vo2Max, unit: HKUnit(from: "ml/kg*min")),
            bodyMassKg: try await latest(bodyMass, unit: .gramUnit(with: .kilo))
        )
        return AthleteData(runs: runs, physiology: physiology)
    }

    // MARK: Queries

    private func runningWorkouts(since: Date) async throws -> [HKWorkout] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForWorkouts(with: .running),
            HKQuery.predicateForSamples(withStart: since, end: .now),
        ])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        return try await descriptor.result(for: store)
    }

    private func halves(start: Date, end: Date) async throws -> (Double?, Double?) {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: heartRate, predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = try await descriptor.result(for: store)
        // Skip the first 10% (warm-up HR climb) so drift reflects the steady part.
        let total = end.timeIntervalSince(start)
        let warmup = start.addingTimeInterval(total * 0.1)
        let mid = start.addingTimeInterval(total * 0.55)
        let first = samples.filter { $0.startDate >= warmup && $0.startDate < mid }.map { $0.quantity.doubleValue(for: bpm) }
        let second = samples.filter { $0.startDate >= mid }.map { $0.quantity.doubleValue(for: bpm) }
        func mean(_ xs: [Double]) -> Double? { xs.count >= 5 ? xs.reduce(0, +) / Double(xs.count) : nil }
        return (mean(first), mean(second))
    }

    private func latest(_ type: HKQuantityType, unit: HKUnit) async throws -> Double? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        return try await descriptor.result(for: store).first?.quantity.doubleValue(for: unit)
    }

    private func average(_ type: HKQuantityType, unit: HKUnit, days: Int) async throws -> Double? {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: since, end: .now))],
            sortDescriptors: []
        )
        let values = try await descriptor.result(for: store).map { $0.quantity.doubleValue(for: unit) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func age() -> Int? {
        guard let dob = try? store.dateOfBirthComponents(), let date = Calendar.current.date(from: dob) else { return nil }
        return Calendar.current.dateComponents([.year], from: date, to: .now).year
    }
}
