import Charts
import CoachKit
import SwiftUI

struct InsightsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                if let m = model.metrics {
                    Section("Weekly distance") {
                        Chart(m.weekly, id: \.weekStart) { w in
                            BarMark(x: .value("Week", w.weekStart, unit: .weekOfYear), y: .value("km", w.km))
                                .foregroundStyle(.orange.gradient)
                                .cornerRadius(4)
                        }
                        .frame(height: 160)
                        LabeledContent("4-week average", value: Format.km(m.baselineWeeklyKm))
                        LabeledContent("Runs in last 28 days", value: "\(m.runsLast28Days)")
                    }

                    if let info = model.saved.lastRun {
                        Section {
                            ForEach(info.signals, id: \.name) { s in
                                HStack(alignment: .top) {
                                    Image(systemName: s.flagged ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(s.flagged ? .orange : .green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(s.title).font(.subheadline.weight(.semibold))
                                            Spacer()
                                            Text(s.value).font(.subheadline.monospacedDigit())
                                        }
                                        Text(s.guidance).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("Signals")
                        } footer: {
                            Text("Thresholds are fixed in code. The model decides what to do about them.")
                        }
                    }

                    Section {
                        ForEach(m.hrZones, id: \.zone) { z in
                            LabeledContent("Zone \(z.zone) · \(zoneName(z.zone))", value: "\(z.low)-\(z.high) bpm")
                        }
                    } header: {
                        Text("Heart rate zones")
                    } footer: {
                        Text("Max HR \(m.maxHR) from \(m.maxHRSource)" + (m.restingHR.map { ", resting HR \($0). Karvonen method." } ?? "."))
                    }

                    Section {
                        LabeledContent("Easy", value: Format.paceRange(m.paces.easy))
                        LabeledContent("Marathon", value: Format.paceRange(m.paces.marathon))
                        LabeledContent("Threshold", value: Format.paceRange(m.paces.threshold))
                        LabeledContent("Interval", value: Format.paceRange(m.paces.interval))
                        LabeledContent("Recovery", value: Format.paceRange(m.paces.recovery))
                    } header: {
                        Text("Pace zones")
                    } footer: {
                        Text("VDOT \(String(format: "%.1f", m.vdot)) from \(m.vdotSource).")
                    }

                    Section("Race predictions") {
                        ForEach(RaceDistance.allCases, id: \.self) { r in
                            LabeledContent(r.rawValue, value: m.predictions[r.rawValue].map(Format.duration) ?? "-")
                        }
                    }
                }

                if let info = model.saved.lastRun {
                    Section {
                        LabeledContent("Coach", value: info.source == "rules" ? "Rule-based" : info.source)
                        LabeledContent("Took", value: String(format: "%.1f s", info.latency))
                        if !info.guardrailHits.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Guardrails stepped in").font(.subheadline.weight(.semibold))
                                ForEach(info.guardrailHits, id: \.self) { Text("• " + $0).font(.caption) }
                            }
                        }
                        if let e = info.error { Text("Model error, used rules: \(e)").font(.caption).foregroundStyle(.red) }
                        DisclosureGroup("What the coach saw") {
                            Text(info.prompt).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if let raw = info.rawOutput {
                            DisclosureGroup("What the coach answered") {
                                Text(raw).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    } header: {
                        Text("How your coach decided")
                    }
                }
            }
            .navigationTitle("Insights")
        }
    }

    private func zoneName(_ z: Int) -> String {
        ["Recovery", "Aerobic", "Tempo", "Threshold", "VO2 max"][z - 1]
    }
}
