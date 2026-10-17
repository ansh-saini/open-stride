#if DEBUG
import CoachKit
import Foundation
import HealthKit

/// Simulator testing only: writes a synthetic runner into Apple Health so the real HealthKit read path can be exercised.
/// Launch with `-seedHealth <persona>`.
enum HealthSeeder {
    static func seed(_ persona: Persona, store: HKHealthStore = HKHealthStore()) async throws -> Int {
        let hr = HKQuantityType(.heartRate)
        let distance = HKQuantityType(.distanceWalkingRunning)
        let resting = HKQuantityType(.restingHeartRate)
        let vo2 = HKQuantityType(.vo2Max)
        try await store.requestAuthorization(toShare: [HKObjectType.workoutType(), hr, distance, resting, vo2], read: [])

        // Idempotent: remove anything this app wrote before. Simulator Health data survives reinstalls.
        let mine = HKQuery.predicateForObjects(from: HKSource.default())
        for type in [HKObjectType.workoutType(), hr, distance, resting, vo2] as [HKObjectType] {
            _ = try? await store.deleteObjects(of: type, predicate: mine)
        }

        // History ending yesterday, so this week shows real completed runs too.
        let now = Calendar.coach.startOfDay(for: .now)
        let scenario = Synthetic.scenario(persona, now: now)
        let bpm = HKUnit.count().unitDivided(by: .minute())

        for run in scenario.data.runs {
            let end = run.start.addingTimeInterval(run.duration)
            let config = HKWorkoutConfiguration()
            config.activityType = .running
            config.locationType = .outdoor
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
            try await builder.beginCollection(at: run.start)

            var samples: [HKSample] = [
                HKQuantitySample(type: distance, quantity: HKQuantity(unit: .meter(), doubleValue: run.distanceMeters), start: run.start, end: end),
            ]
            // One HR sample every 30 s, ramping from first-half to second-half average.
            let a = run.firstHalfHR ?? run.avgHR ?? 140, b = run.secondHalfHR ?? run.avgHR ?? 140
            var t = run.start
            while t < end {
                let f = t.timeIntervalSince(run.start) / run.duration
                let value = f < 0.1 ? a - 15 * (1 - f / 0.1) : (f < 0.55 ? a : b)
                samples.append(HKQuantitySample(type: hr, quantity: HKQuantity(unit: bpm, doubleValue: value), start: t, end: t.addingTimeInterval(1)))
                t = t.addingTimeInterval(30)
            }
            try await builder.addSamples(samples)
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        }

        let p = scenario.data.physiology
        if let r = p.restingHR {
            try await store.save(HKQuantitySample(type: resting, quantity: HKQuantity(unit: bpm, doubleValue: r), start: now.addingTimeInterval(-86400), end: now.addingTimeInterval(-86400)))
        }
        if let v = p.vo2Max {
            try await store.save(HKQuantitySample(type: vo2, quantity: HKQuantity(unit: HKUnit(from: "ml/kg*min"), doubleValue: v), start: now.addingTimeInterval(-86400), end: now.addingTimeInterval(-86400)))
        }
        return scenario.data.runs.count
    }
}
#endif
