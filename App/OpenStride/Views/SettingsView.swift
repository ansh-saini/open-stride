import CoachKit
import CoachMLX
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var ollamaURL = "http://192.168.1.10:11434"
    @State private var ollamaModel = "gemma3:4b"
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                if let g = model.goal {
                    Section("Goal") {
                        LabeledContent("Race", value: g.race.rawValue)
                        LabeledContent("Date", value: g.raceDate.formatted(date: .abbreviated, time: .omitted))
                        LabeledContent("Runs per week", value: "\(g.daysPerWeek)")
                    }
                }

                Section {
                    ForEach(OnDeviceModel.allCases) { m in
                        backendRow(.onDevice(m), title: "\(m.label) on this iPhone", subtitle: m.sizeLabel)
                    }
                    backendRow(.rules, title: "Rules only", subtitle: "No model. Same guardrails, fixed wording.")
                    VStack(alignment: .leading) {
                        backendRow(.ollama(url: ollamaURL, model: ollamaModel), title: "Ollama server", subtitle: "Run Gemma on your own computer.")
                        TextField("URL", text: $ollamaURL).textInputAutocapitalization(.never).font(.caption.monospaced())
                        TextField("Model", text: $ollamaModel).textInputAutocapitalization(.never).font(.caption.monospaced())
                    }
                } header: {
                    Text("Coach model")
                } footer: {
                    Text("All options use open-weight Gemma models. On-device keeps every number on your phone.")
                }

                Section("Data") {
                    Picker("Source", selection: Binding(get: { model.saved.source }, set: { s in Task { await model.setSource(s) } })) {
                        Text("Apple Health").tag(DataSource.health)
                        ForEach(Persona.allCases, id: \.self) { p in
                            Text("Sample: \(p.summary)").tag(DataSource.sample(p))
                        }
                    }
                }

                Section {
                    Button("Start over", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete your plan and goal?", isPresented: $confirmReset) {
                Button("Start over", role: .destructive) { model.reset() }
            }
        }
    }

    private func backendRow(_ b: Backend, title: String, subtitle: String) -> some View {
        Button {
            model.setBackend(b)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected(b) { Image(systemName: "checkmark").foregroundStyle(.orange) }
            }
        }
    }

    private func isSelected(_ b: Backend) -> Bool {
        switch (b, model.saved.backend) {
        case (.ollama, .ollama): true
        default: b == model.saved.backend
        }
    }
}
