import SwiftUI

struct PerformanceView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    private let tokenLimits = [128, 500, 1_000]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tokenLimits, id: \.self) { tokenLimit in
                        Button {
                            Task {
                                await store.runPerformanceTest(maxOutputTokens: tokenLimit)
                            }
                        } label: {
                            HStack {
                                Label("Run \(tokenLimit.formatted())-token test", systemImage: "play.fill")
                                Spacer()
                                if store.runningPerformanceTestTokenLimit == tokenLimit {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(!store.canSend)
                    }
                } footer: {
                    Text(
                        "Runs a fixed prompt in a temporary conversation using the loaded model. " +
                        "Longer tests take more time and energy. The response is discarded; only the on-device LiteRT-LM measurements are kept."
                    )
                }

                if let metrics = store.lastMetrics {
                    Section(metrics.displayLabel) {
                        metricRows(metrics)
                    }
                } else {
                    Section("No measurements yet") {
                        Text("Run the test above or send a chat message. Every completed response records its real decode-token count and speed.")
                            .foregroundStyle(.secondary)
                    }
                }

                if !store.metricHistory.isEmpty {
                    Section("Recent measurements") {
                        ForEach(Array(store.metricHistory.prefix(10).enumerated()), id: \.offset) { _, metrics in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(metrics.displayLabel)
                                    Spacer()
                                    Text("\(metrics.outputTokenCount) tokens")
                                        .monospacedDigit()
                                }
                                HStack {
                                    Text(metrics.measuredAt.formatted(date: .omitted, time: .standard))
                                    Spacer()
                                    Text("\(metrics.outputTokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s")
                                        .monospacedDigit()
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Text(
                        "Generated tokens are LiteRT-LM decode tokens and can include hidden reasoning tokens when thinking is enabled. " +
                        "The dedicated test disables thinking for a cleaner decode-speed measurement."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Model performance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(store.isRunningPerformanceTest)
    }

    @ViewBuilder
    private func metricRows(_ metrics: GenerationMetrics) -> some View {
        if let outputTokenLimit = metrics.outputTokenLimit {
            LabeledContent("Requested limit", value: outputTokenLimit.formatted())
        }
        LabeledContent("Generated tokens", value: metrics.outputTokenCount.formatted())
        LabeledContent("Prompt tokens", value: metrics.prefillTokenCount.formatted())
        LabeledContent("Context after run", value: metrics.contextTokenCount.formatted())
        LabeledContent(
            "Generation speed",
            value: "\(metrics.outputTokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s"
        )
        LabeledContent(
            "Prompt processing",
            value: "\(metrics.prefillTokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s"
        )
        LabeledContent(
            "Time to first token",
            value: "\(metrics.timeToFirstToken.formatted(.number.precision(.fractionLength(2)))) s"
        )
        LabeledContent(
            "Engine initialization",
            value: "\(metrics.initializationTime.formatted(.number.precision(.fractionLength(2)))) s"
        )
    }
}
