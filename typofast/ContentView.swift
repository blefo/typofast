import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
class AppState: ObservableObject {
    @Published var engine: AutocompleteEngine?
    @Published var isLoading = false
    @Published var loadingStatus = ""
    @Published var currentText = ""
    @Published var suggestion = ""
    @Published var metrics: CompletionMetrics?
    @Published var modelPath: String?

    private var inferenceTask: Task<Void, Never>?

    func loadModel(path: String) async {
        isLoading = true
        loadingStatus = "Loading model..."

        do {
            let engine = AutocompleteEngine()
            try await engine.loadModel(path: path)
            self.engine = engine
            self.modelPath = path
            loadingStatus = "Model loaded successfully!"

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            isLoading = false
        } catch {
            loadingStatus = "Error loading model: \(error.localizedDescription)"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            isLoading = false
        }
    }

    func onTextChange(_ newText: String) {
        currentText = newText

        inferenceTask?.cancel()

        // Clear suggestion immediately if text is empty
        if newText.isEmpty {
            suggestion = ""
            metrics = nil
            return
        }

        inferenceTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await requestCompletion(newText)
        }
    }

    private func requestCompletion(_ text: String) async {
        guard let engine = engine else { return }

        let (completion, completionMetrics) = await engine.getCompletion(
            prompt: text,
            inputText: text,
            maxTokens: 6
        )

        // Only update if text hasn't changed
        if text == currentText {
            suggestion = completion
            metrics = completionMetrics
        }
    }

    func acceptSuggestion() {
        guard !suggestion.isEmpty else { return }

        // Accept first word
        let firstWord = suggestion.split(separator: " ").first.map(String.init) ?? suggestion
        currentText += firstWord + " "
        suggestion = ""
        metrics = nil

        // Trigger new completion
        onTextChange(currentText)
    }

    func clearAll() async {
        currentText = ""
        suggestion = ""
        metrics = nil
        if let engine = engine {
            await engine.resetCache()
        }
    }
}

struct ContentView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                Button(action: selectModel) {
                    Label(
                        appState.modelPath == nil ? "Select Model" : "Change Model",
                        systemImage: "folder"
                    )
                }

                if let modelPath = appState.modelPath {
                    Text(URL(fileURLWithPath: modelPath).lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: {
                    Task {
                        await appState.clearAll()
                    }
                }) {
                    Label("Clear Cache", systemImage: "trash")
                }
                .disabled(appState.engine == nil)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Main editor area
            if appState.isLoading {
                VStack {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text(appState.loadingStatus)
                        .font(.headline)
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.engine == nil {
                VStack {
                    Image(systemName: "doc.text")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("Select a GGUF model to start")
                        .font(.headline)
                        .padding()
                    Button("Select Model") {
                        selectModel()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditorWithSuggestions(
                    text: $appState.currentText,
                    suggestion: appState.suggestion,
                    onTextChange: { appState.onTextChange($0) },
                    onAcceptSuggestion: { appState.acceptSuggestion() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Metrics footer
            if let metrics = appState.metrics {
                Divider()
                HStack {
                    Text("TTFT: \(String(format: "%.0f", metrics.ttft * 1000))ms")
                    Text("•")
                    Text("\(String(format: "%.1f", metrics.tokensPerSecond)) tok/s")
                    Text("•")
                    Text("Cache: \(metrics.cachedTokensReused)")
                    Spacer()
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private func selectModel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.item]
        panel.allowsOtherFileTypes = true
        panel.message = "Select a GGUF model file"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await appState.loadModel(path: url.path)
            }
        }
    }
}

struct TextEditorWithSuggestions: NSViewRepresentable {
    @Binding var text: String
    let suggestion: String
    let onTextChange: (String) -> Void
    let onAcceptSuggestion: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = context.coordinator

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Update text if different
        if textView.string != text {
            textView.string = text
        }

        // Update suggestion display
        context.coordinator.updateSuggestion(suggestion)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onTextChange: onTextChange,
            onAcceptSuggestion: onAcceptSuggestion
        )
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onTextChange: (String) -> Void
        let onAcceptSuggestion: () -> Void

        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        private var suggestionLayer: CATextLayer?

        init(text: Binding<String>, onTextChange: @escaping (String) -> Void, onAcceptSuggestion: @escaping () -> Void) {
            self._text = text
            self.onTextChange = onTextChange
            self.onAcceptSuggestion = onAcceptSuggestion
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            onTextChange(textView.string)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Handle Tab to accept suggestion
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                onAcceptSuggestion()
                return true
            }

            return false
        }

        func updateSuggestion(_ suggestion: String) {
            guard let textView = textView else { return }

            // Remove old suggestion layer
            suggestionLayer?.removeFromSuperlayer()
            suggestionLayer = nil

            guard !suggestion.isEmpty else { return }

            // Calculate position after cursor
            let cursorRect = textView.layoutManager?.boundingRect(
                forGlyphRange: NSRange(location: textView.selectedRange().location, length: 0),
                in: textView.textContainer!
            ) ?? .zero

            // Create suggestion layer
            let layer = CATextLayer()
            layer.string = suggestion
            layer.font = textView.font
            layer.fontSize = textView.font?.pointSize ?? 14
            layer.foregroundColor = NSColor.systemGray.cgColor
            layer.contentsScale = textView.window?.backingScaleFactor ?? 2.0

            let size = (suggestion as NSString).size(withAttributes: [
                .font: textView.font ?? NSFont.systemFont(ofSize: 14)
            ])

            layer.frame = CGRect(
                x: cursorRect.maxX + textView.textContainerInset.width,
                y: cursorRect.minY + textView.textContainerInset.height,
                width: size.width,
                height: size.height
            )

            textView.layer?.addSublayer(layer)
            suggestionLayer = layer
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 800, height: 600)
}
