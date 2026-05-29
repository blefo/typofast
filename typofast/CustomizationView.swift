import SwiftUI

struct CustomizationView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            modelSection
            personalizationSection
            lengthSection
            minWordsSection
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model")
                .font(.system(.callout, design: .rounded).weight(.semibold))
            Picker("", selection: Binding(
                get: { appState.selectedModel },
                set: { appState.switchModel($0) }
            )) {
                ForEach(ModelConfig.all) { config in
                    Text(config.displayName).tag(config)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(appState.isLoading)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Customization")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var personalizationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Personalization")
                .font(.system(.callout, design: .rounded).weight(.semibold))
            Text("Describe yourself, your role and how you write. Added as context to every suggestion so short sentences complete better.")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: Binding(
                get: { appState.customInstructions },
                set: { appState.setCustomInstructions($0) }
            ))
            .font(.system(size: 12, design: .rounded))
            .scrollContentBackground(.hidden)
            .frame(height: 64)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.55))
            )
        }
    }

    private var lengthSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Suggestion length")
                .font(.system(.callout, design: .rounded).weight(.semibold))
            Picker("", selection: Binding(
                get: { appState.completionLength },
                set: { appState.setCompletionLength($0) }
            )) {
                ForEach(CompletionLength.allCases, id: \.self) { length in
                    Text(length.shortLabel).tag(length)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var minWordsSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start after")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                Text("words typed")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Stepper(value: Binding(
                get: { appState.minWordsToSuggest },
                set: { appState.setMinWordsToSuggest($0) }
            ), in: 1...8) {
                Text("\(appState.minWordsToSuggest)")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
        }
    }
}
