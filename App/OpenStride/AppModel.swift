import CoachKit
import CoachMLX
import Foundation
import Observation

enum DataSource: Codable, Hashable {
    case health
    case sample(Persona)

    var label: String {
        switch self {
        case .health: "Apple Health"
        case let .sample(p): "Sample: \(p.rawValue)"
        }
    }
}

enum Backend: Codable, Hashable {
    case onDevice(OnDeviceModel)
    case ollama(url: String, model: String)
    case rules

    var label: String {
        switch self {
        case let .onDevice(m): "\(m.label) on this iPhone"
        case let .ollama(_, model): "\(model) via Ollama"
        case .rules: "Rules only (no model)"
        }
    }
}

/// Everything we keep between launches. One JSON file in Application Support.
struct Saved: Codable {
    var goal: Goal?
    var source: DataSource = .health
    var backend: Backend = .onDevice(.gemma4B)
    var planStart: Date?
    var weeks: [WeekPlan] = []
    var lastRun: CoachRunInfo?
}

/// What the coach did on its last run, shown under "How your coach decided".
struct CoachRunInfo: Codable, Hashable {
    var source: String
    var latency: TimeInterval
    var guardrailHits: [String]
    var signals: [CoachAgent.Signal]
    var prompt: String
    var rawOutput: String?
    var error: String?
    var date: Date
}

@MainActor
@Observable
final class AppModel {
    var saved = Saved()
    var data: AthleteData?
    var metrics: Metrics?
    var status: Status = .idle
    var error: String?
    /// One-time message, e.g. after switching models.
    var notice: String?

    enum Status: Equatable {
        case idle, loadingHealth, downloading(Double), thinking
    }

    private let health = HealthKitProvider()
    private var mlxClients: [OnDeviceModel: MLXClient] = [:]

    var goal: Goal? { saved.goal }

    /// "Now" for the coach. Sample histories end at the start of this week, so plan from there.
    var referenceDate: Date {
        if case .sample = saved.source { return Calendar.coach.startOfWeek(for: .now) }
        return .now
    }
    var currentWeek: WeekPlan? {
        let start = Calendar.coach.startOfWeek(for: planningDate)
        return saved.weeks.last { $0.weekStart == start }
    }

    /// On weekends the coach plans next week, so it never rewrites days that already happened.
    var planningDate: Date {
        let cal = Calendar.coach
        if case .health = saved.source, cal.coachWeekday(.now) >= 6 {
            return cal.date(byAdding: .day, value: 7, to: cal.startOfWeek(for: .now))!
        }
        return referenceDate
    }

    var isNextWeek: Bool { (currentWeek?.weekStart ?? .distantPast) > .now }

    init() {
        load()
        applyLaunchArguments()
        recoverFromModelCrash()
    }

    /// `-demo <persona>` starts fresh with a sample runner. `-backend rules|1b|4b` picks the coach. For screenshots and tests.
    /// A file, not UserDefaults: it must be on disk before iOS can kill the app mid-generation.
    private var inFlightURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("model-in-flight") }

    /// If the app died while an on-device model was running (iOS kills apps that run out of memory),
    /// step down to the smaller model instead of crashing again.
    private func recoverFromModelCrash() {
        guard let data = try? Data(contentsOf: inFlightURL) else { return }
        let id = String(decoding: data, as: UTF8.self)
        try? FileManager.default.removeItem(at: inFlightURL)
        if id == OnDeviceModel.gemma4B.rawValue, saved.backend == .onDevice(.gemma4B) {
            saved.backend = .onDevice(.gemma1B)
            persist()
            notice = "Gemma 4B ran out of memory on this iPhone, so your coach now uses Gemma 3 1B. You can switch back in Settings."
        }
    }

    private func applyLaunchArguments() {
        let args = UserDefaults.standard
        if let b = args.string(forKey: "backend") {
            saved.backend = switch b {
            case "rules": .rules
            case "1b": .onDevice(.gemma1B)
            default: .onDevice(.gemma4B)
            }
        }
        if let d = args.string(forKey: "demo"), let p = Persona(rawValue: d) {
            // Demo runs in memory only, so it never replaces the real plan on disk.
            isDemo = true
            let cal = Calendar.coach
            let week = cal.startOfWeek(for: .now)
            saved.source = .sample(p)
            saved.goal = Goal(race: p == .beginner ? .fiveK : .tenK, raceDate: cal.date(byAdding: .day, value: 7 * 9 + 6, to: week)!,
                              daysPerWeek: p == .beginner ? 3 : 4)
            saved.planStart = cal.date(byAdding: .day, value: -7, to: week)
            // Last week's plan, so the coach has something to review.
            let s = Synthetic.scenario(p, now: week)
            saved.weeks = s.previous.map { [$0] } ?? []
            saved.lastRun = nil
        }
    }

    // MARK: Flow

    func start(goal: Goal) async {
        saved.goal = goal
        saved.planStart = .now
        saved.weeks = []
        persist()
        await refresh(replan: true)
    }

    /// Reload data, recompute metrics, and plan the week if there is no plan yet (or `replan`).
    func refresh(replan: Bool = false) async {
        error = nil
        do {
            status = .loadingHealth
            let d = try await loadData()
            data = d
            metrics = MetricsCalculator.compute(d, now: referenceDate)
            // `-dumpData YES`: write what we parsed from Health to the app container, for debugging on a Mac.
            if UserDefaults.standard.bool(forKey: "dumpData") {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                enc.dateEncodingStrategy = .iso8601
                try? enc.encode(d).write(to: fileURL.deletingLastPathComponent().appendingPathComponent("athlete-dump.json"))
            }
            status = .idle
            if replan || currentWeek == nil { await planWeek() }
        } catch {
            self.error = error.localizedDescription
            status = .idle
        }
    }

    func planWeek() async {
        guard let goal = saved.goal, let data else { return }
        status = .thinking
        let llm = client()
        if let mlx = llm as? MLXClient { try? Data(mlx.model.rawValue.utf8).write(to: inFlightURL, options: .atomic) }
        defer { try? FileManager.default.removeItem(at: inFlightURL) }
        let agent = CoachAgent(llm: llm)
        let now = planningDate
        let start = Calendar.coach.startOfWeek(for: now)
        let previous = saved.weeks.last { $0.weekStart < start }
        let result = await agent.planWeek(goal: goal, data: data, previous: previous, planStart: saved.planStart, now: now)

        saved.weeks.removeAll { $0.weekStart == result.week.weekStart }
        saved.weeks.append(result.week)
        let m = MetricsCalculator.compute(data, now: now)
        let draft = PlanEngine.draftWeek(goal: goal, metrics: m, now: now, planStart: saved.planStart)
        let review = WeekReview.make(previous: previous, runs: data.runs)
        saved.lastRun = CoachRunInfo(
            source: result.source, latency: result.latency, guardrailHits: result.guardrailHits,
            signals: CoachAgent.signals(m, review: review),
            prompt: CoachAgent.userPrompt(goal: goal, metrics: m, draft: draft, review: review),
            rawOutput: result.rawOutput, error: result.error, date: .now
        )
        persist()
        status = .idle
    }

    func setSource(_ s: DataSource) async {
        saved.source = s
        persist()
        await refresh(replan: true)
    }

    func setBackend(_ b: Backend) {
        saved.backend = b
        persist()
    }

    func reset() {
        saved = Saved(source: saved.source, backend: saved.backend)
        data = nil
        metrics = nil
        persist()
    }

    /// DEBUG: `-seedHealth <persona>` writes a sample runner into Health, then plans from the real Health path.
    func seedIfRequested() async {
        #if DEBUG
        guard let name = UserDefaults.standard.string(forKey: "seedHealth"), let p = Persona(rawValue: name),
              !UserDefaults.standard.bool(forKey: "seeded-\(name)") else { return }
        do {
            status = .loadingHealth
            let n = try await HealthSeeder.seed(p)
            UserDefaults.standard.set(true, forKey: "seeded-\(name)")
            print("seeded \(n) runs for \(name)")
            let week = Calendar.coach.startOfWeek(for: .now)
            saved.source = .health
            saved.goal = Goal(race: .tenK, raceDate: Calendar.coach.date(byAdding: .day, value: 7 * 9 + 6, to: week)!, daysPerWeek: 4)
            saved.planStart = Calendar.coach.date(byAdding: .day, value: -7, to: week)
            saved.weeks = []
            persist()
        } catch {
            self.error = "Seeding failed: \(error.localizedDescription)"
        }
        status = .idle
        #endif
    }

    // MARK: Private

    private func loadData() async throws -> AthleteData {
        switch saved.source {
        case .health:
            guard HealthKitProvider.isAvailable else { throw AppError.noHealth }
            try await health.requestAccess()
            return try await health.load()
        case let .sample(p):
            // Shift the sample history so it ends today.
            let s = Synthetic.scenario(p, now: Calendar.coach.startOfWeek(for: .now))
            return s.data
        }
    }

    private func client() -> LLMClient? {
        switch saved.backend {
        case .rules:
            return nil
        case let .ollama(url, model):
            guard let u = URL(string: url) else { return nil }
            return OllamaClient(baseURL: u, model: model)
        case let .onDevice(m):
            #if targetEnvironment(simulator)
            // MLX needs a real GPU. The simulator talks to Ollama on the Mac instead.
            return OllamaClient(model: m == .gemma4B ? "gemma3:4b" : "gemma3:1b")
            #else
            if let c = mlxClients[m] { return c }
            let c = MLXClient(model: m) { [weak self] p in
                Task { @MainActor in self?.status = p < 1 ? .downloading(p) : .thinking }
            }
            mlxClients[m] = c
            return c
            #endif
        }
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("openstride.json")
    }

    private func load() {
        guard let d = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        saved = s
    }

    private var isDemo = false

    private func persist() {
        guard !isDemo else { return }
        if let d = try? JSONEncoder().encode(saved) { try? d.write(to: fileURL, options: .atomic) }
    }
}

enum AppError: LocalizedError {
    case noHealth
    var errorDescription: String? { "Apple Health is not available on this device." }
}
