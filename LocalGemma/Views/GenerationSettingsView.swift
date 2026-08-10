import SwiftUI

struct GenerationSettingsView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings: GenerationSettings

    init(settings: GenerationSettings) {
        _settings = State(initialValue: settings)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Creativity") {
                    valueSlider("Temperature", value: $settings.temperature, range: 0...1.5, step: 0.1)
                    valueSlider("Top P", value: $settings.topP, range: 0.1...1, step: 0.05)
                    Picker("Top K", selection: $settings.topK) {
                        ForEach([10, 20, 40, 60, 80, 100], id: \.self) { Text("\($0)").tag($0) }
                    }
                }

                Section("Response") {
                    Picker("Maximum tokens", selection: $settings.maxOutputTokens) {
                        ForEach([128, 256, 500, 1_000, 1_024, 1_500, 2_048], id: \.self) {
                            Text($0.formatted()).tag($0)
                        }
                    }
                    Toggle("Thinking", isOn: $settings.thinkingEnabled)
                    if settings.thinkingEnabled {
                        Picker("Thinking budget", selection: $settings.thinkingBudget) {
                            ForEach([64, 128, 256, 512, 1_024], id: \.self) { Text("\($0)").tag($0) }
                        }
                    }
                }

                Section {
                    Text("Lower temperature is more deterministic. Larger token and thinking budgets use more memory, energy, and time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Generation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        Task {
                            await store.applyGenerationSettings(settings)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
