import CoachKit
import SwiftUI

struct WeekView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                if let note = model.notice {
                    Section { Label(note, systemImage: "memorychip").font(.callout) }
                }
                if let err = model.error {
                    Section { Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                if let week = model.currentWeek, let goal = model.goal {
                    Section { WeekHeader(week: week, goal: goal) }
                    if let summary = week.coachSummary {
                        Section { CoachCard(message: summary, source: week.coachSource ?? "") }
                    }
                    Section("Sessions") {
                        ForEach(week.sessions) { s in
                            NavigationLink { SessionDetailView(session: s) } label: {
                                SessionRow(session: s, status: status(of: s, in: week))
                            }
                        }
                    }
                } else if model.status == .idle {
                    ContentUnavailableView("No plan yet", systemImage: "figure.run", description: Text("Pull to refresh or tap Re-plan."))
                }
            }
            .navigationTitle(model.isNextWeek ? "Next week" : "This week")
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Re-plan") { Task { await model.refresh(replan: true) } }
                        .disabled(model.status != .idle)
                }
            }
            .overlay { StatusOverlay(status: model.status) }
        }
    }
}

extension WeekView {
    /// Past days show what actually happened. A run counts toward a session on the same day, or one day either side,
    /// because real weeks shift (Tuesday's run instead of Monday's is still the run).
    func status(of s: Session, in week: WeekPlan) -> SessionRow.Status {
        // Sample histories end before this week, so every day is still ahead.
        if case .sample = model.saved.source { return .upcoming }
        let cal = Calendar.coach
        let end = cal.date(byAdding: .day, value: 7, to: week.weekStart)!
        let runs = (model.data?.runs ?? []).filter { $0.start >= week.weekStart && $0.start < end }

        var matched: [UUID: Double] = [:]
        var used = Set<UUID>()
        for offset in [0, 1, -1] {
            for session in week.sessions where matched[session.id] == nil {
                if let run = runs.first(where: { !used.contains($0.id) && cal.coachWeekday($0.start) == session.weekday + offset }) {
                    matched[session.id] = run.distanceKm
                    used.insert(run.id)
                }
            }
        }
        if let km = matched[s.id] { return .done(km) }
        let day = cal.date(byAdding: .day, value: s.weekday - 1, to: week.weekStart)!
        return day < cal.startOfDay(for: .now) ? .missed : .upcoming
    }
}

struct WeekHeader: View {
    let week: WeekPlan
    let goal: Goal

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(week.phase.rawValue.uppercased())
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
                if week.isCutback {
                    Text("CUTBACK").font(.caption.bold()).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Week \(week.weekNumber) of \(week.totalWeeks)").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(Format.km(week.plannedKm)).font(.system(size: 40, weight: .bold, design: .rounded))
                Text("planned").foregroundStyle(.secondary)
            }
            let days = Calendar.current.dateComponents([.day], from: .now, to: goal.raceDate).day ?? 0
            Text("\(goal.race.rawValue) in \(days) days").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct CoachCard: View {
    let message: String
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your coach", systemImage: "sparkles").font(.headline)
            Text(message).font(.callout)
            Text(source == "rules" ? "Rule-based coach" : source)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct SessionRow: View {
    enum Status { case upcoming, done(Double), missed }
    let session: Session
    var status: Status = .upcoming

    var body: some View {
        HStack(spacing: 12) {
            Text(session.weekday.weekdayName)
                .font(.subheadline.bold()).frame(width: 36, alignment: .leading)
            Image(systemName: session.type.symbol)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(session.type.color, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.type.label).font(.body.weight(.semibold))
                    if session.note != nil {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.orange)
                    }
                }
                if let p = session.pace {
                    Text(Format.paceRange(p) + (session.hrZone.map { " · Z\($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch status {
            case .upcoming:
                Text(Format.km(session.distanceKm)).font(.body.monospacedDigit().weight(.medium))
            case let .done(km):
                VStack(alignment: .trailing, spacing: 2) {
                    Label(Format.km(km), systemImage: "checkmark.circle.fill")
                        .font(.body.monospacedDigit().weight(.medium)).foregroundStyle(.green)
                    Text("of \(Format.km(session.distanceKm))").font(.caption2).foregroundStyle(.secondary)
                }
            case .missed:
                Text(Format.km(session.distanceKm)).font(.body.monospacedDigit()).strikethrough().foregroundStyle(.secondary)
            }
        }
        .opacity(isMissed ? 0.5 : 1)
    }

    private var isMissed: Bool { if case .missed = status { true } else { false } }
}

struct StatusOverlay: View {
    let status: AppModel.Status

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .loadingHealth:
            card { ProgressView("Reading Apple Health") }
        case let .downloading(p):
            card {
                VStack(spacing: 8) {
                    ProgressView(value: p)
                    Text("Downloading Gemma (\(Int(p * 100))%). One time only.").font(.caption)
                }
            }
        case .thinking:
            card { ProgressView("Coach is reviewing your week") }
        }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(20)
            .frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: session.type.symbol)
                        .font(.title2).foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(session.type.color, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading) {
                        Text(session.type.label).font(.title2.bold())
                        Text("\(session.weekday.weekdayName) · \(Format.km(session.distanceKm))").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Workout") { Text(session.detail) }
            Section("Targets") {
                if let p = session.pace { LabeledContent("Pace", value: Format.paceRange(p)) }
                if let z = session.hrZone, let zone = model.metrics?.hrZones.first(where: { $0.zone == z }) {
                    LabeledContent("Heart rate", value: "Zone \(z): \(zone.low)-\(zone.high) bpm")
                }
            }
            if let note = session.note {
                Section("Why your coach changed this") {
                    Label(note, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
