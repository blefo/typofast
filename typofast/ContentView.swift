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
    @Published var suggestionBase = ""
    @Published var suggestionOffset = 0
    @Published var metrics: CompletionMetrics?
    @Published var modelPath: String?

    private var inferenceTask: Task<Void, Never>?
    private var lastText = ""

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
        let previousText = lastText
        logEvent("textChange", [
            "prev": previousText,
            "new": newText,
            "suggestion": suggestion,
            "base": suggestionBase,
            "offset": "\(suggestionOffset)"
        ])
        if shouldKeepSuggestionOnTrailingWhitespace(previousText: previousText, newText: newText) {
            inferenceTask?.cancel()
            currentText = newText
            lastText = newText
            logEvent("keepSuggestion.trailingWhitespace", [
                "typed": String(newText.dropFirst(previousText.count))
            ])
            return
        }
        if shouldKeepSuggestionAlive(previousText: previousText, newText: newText) {
            inferenceTask?.cancel()
            lastText = newText
            logEvent("keepSuggestion.matching", [
                "typed": String(newText.dropFirst(previousText.count)),
                "remaining": String(suggestionBase.dropFirst(suggestionOffset))
            ])
            return
        }

        currentText = newText
        lastText = newText

        inferenceTask?.cancel()

        // Clear suggestion immediately if text is empty
        if newText.isEmpty {
            suggestion = ""
            suggestionBase = ""
            suggestionOffset = 0
            metrics = nil
            lastText = ""
            return
        }
        if !hasCompletedWord(newText) {
            suggestion = ""
            suggestionBase = ""
            suggestionOffset = 0
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

        let modelPrompt = trimTrailingSpaces(text)
        logEvent("requestCompletion", [
            "text": text,
            "modelPrompt": modelPrompt
        ])
        let (completion, completionMetrics) = await engine.getCompletion(
            prompt: modelPrompt,
            inputText: text,
            maxTokens: 6
        )

        // Only update if text hasn't changed
        if text == currentText {
            let sanitized = sanitizeSuggestion(completion, forPrompt: text)
            suggestionBase = sanitized
            suggestionOffset = 0
            suggestion = sanitized
            logEvent("completionReceived", [
                "raw": completion,
                "sanitized": sanitized
            ])
            metrics = completionMetrics
        }
    }

    func acceptSuggestion() -> String {
        guard !suggestion.isEmpty else { return "" }

        // Accept first word only, no artificial spaces
        let firstWord = firstWordWithLeadingWhitespace(from: suggestion)
        currentText += firstWord
        suggestion = ""
        suggestionBase = ""
        suggestionOffset = 0
        metrics = nil

        // Trigger new completion
        onTextChange(currentText)
        return firstWord
    }

    func acceptAllSuggestion() -> String {
        guard !suggestion.isEmpty else { return "" }

        let accepted = suggestion
        currentText += suggestion
        suggestion = ""
        suggestionBase = ""
        suggestionOffset = 0
        metrics = nil

        // Trigger new completion
        onTextChange(currentText)
        return accepted
    }

    func regenerateAfterDeletingAcceptedSuggestion(newText: String) {
        suggestion = ""
        suggestionBase = ""
        suggestionOffset = 0
        metrics = nil
        lastText = ""
        onTextChange(newText)
    }

    private func sanitizeSuggestion(_ suggestion: String, forPrompt prompt: String) -> String {
        guard !suggestion.isEmpty else { return "" }

        if promptEndsWithSpaceOrTab(prompt) {
            return trimLeadingWhitespace(suggestion)
        }

        return suggestion
    }

    private func trimTrailingSpaces(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let prev = text.index(before: end)
            let ch = text[prev]
            if ch == " " || ch == "\t" {
                end = prev
            } else {
                break
            }
        }
        return String(text[..<end])
    }

    private func promptEndsWithSpaceOrTab(_ text: String) -> Bool {
        guard let lastChar = text.last else { return false }
        return lastChar == " " || lastChar == "\t"
    }

    private func trimLeadingWhitespace(_ text: String) -> String {
        var start = text.startIndex
        while start < text.endIndex {
            let ch = text[start]
            if ch == " " || ch == "\t" {
                start = text.index(after: start)
            } else {
                break
            }
        }
        return String(text[start...])
    }

    private func firstWordWithLeadingWhitespace(from suggestion: String) -> String {
        var index = suggestion.startIndex

        while index < suggestion.endIndex, suggestion[index].isWhitespace {
            index = suggestion.index(after: index)
        }

        if index == suggestion.endIndex {
            return ""
        }

        var end = index
        while end < suggestion.endIndex, !suggestion[end].isWhitespace {
            end = suggestion.index(after: end)
        }

        return String(suggestion[..<end])
    }

    private func shouldKeepSuggestionAlive(previousText: String, newText: String) -> Bool {
        guard !suggestionBase.isEmpty else { return false }
        guard newText.count >= previousText.count else { return false }
        guard newText.hasPrefix(previousText) else { return false }

        let typedStart = newText.index(newText.startIndex, offsetBy: previousText.count)
        let typed = String(newText[typedStart...])
        if typed.isEmpty { return false }

        let remaining = String(suggestionBase.dropFirst(suggestionOffset))
        if remaining.hasPrefix(typed) {
            suggestionOffset += typed.count
            suggestion = String(suggestionBase.dropFirst(suggestionOffset))
            currentText = newText
            return true
        }

        return false
    }

    private func shouldKeepSuggestionOnTrailingWhitespace(previousText: String, newText: String) -> Bool {
        guard !suggestionBase.isEmpty else { return false }
        guard newText.count > previousText.count else { return false }
        guard newText.hasPrefix(previousText) else { return false }

        let typedStart = newText.index(newText.startIndex, offsetBy: previousText.count)
        let typed = newText[typedStart...]
        if typed.isEmpty { return false }
        guard typed.allSatisfy({ $0 == " " || $0 == "\t" }) else { return false }

        let remaining = String(suggestionBase.dropFirst(suggestionOffset))
        if remaining.hasPrefix(typed) {
            suggestionOffset += typed.count
            suggestion = String(suggestionBase.dropFirst(suggestionOffset))
        }
        return true
    }

    private func logEvent(_ name: String, _ data: [String: String]) {
        #if DEBUG
        let payload = data.map { "\($0.key)=\($0.value.debugDescription)" }.sorted().joined(separator: " ")
        print("[Typofast] \(name) \(payload)")
        #endif
    }

    private func hasCompletedWord(_ text: String) -> Bool {
        var inWord = false
        for ch in text {
            if ch.isWhitespace {
                if inWord { return true }
            } else {
                inWord = true
            }
        }
        return false
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
                    onAcceptSuggestion: { appState.acceptSuggestion() },
                    onAcceptAllSuggestion: { appState.acceptAllSuggestion() },
                    onDeleteAcceptedSuggestion: { appState.regenerateAfterDeletingAcceptedSuggestion(newText: $0) }
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
    let onAcceptSuggestion: () -> String
    let onAcceptAllSuggestion: () -> String
    let onDeleteAcceptedSuggestion: (String) -> Void

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
            onAcceptSuggestion: onAcceptSuggestion,
            onAcceptAllSuggestion: onAcceptAllSuggestion,
            onDeleteAcceptedSuggestion: onDeleteAcceptedSuggestion
        )
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onTextChange: (String) -> Void
        let onAcceptSuggestion: () -> String
        let onAcceptAllSuggestion: () -> String
        let onDeleteAcceptedSuggestion: (String) -> Void

        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        private var suggestionLayer: CATextLayer?
        private var lastAcceptedRange: NSRange?
        private var lastAcceptedText = ""

        init(
            text: Binding<String>,
            onTextChange: @escaping (String) -> Void,
            onAcceptSuggestion: @escaping () -> String,
            onAcceptAllSuggestion: @escaping () -> String,
            onDeleteAcceptedSuggestion: @escaping (String) -> Void
        ) {
            self._text = text
            self.onTextChange = onTextChange
            self.onAcceptSuggestion = onAcceptSuggestion
            self.onAcceptAllSuggestion = onAcceptAllSuggestion
            self.onDeleteAcceptedSuggestion = onDeleteAcceptedSuggestion
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            onTextChange(textView.string)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if replacementString == "@" {
                let accepted = acceptAllSuggestion(from: textView)
                return accepted.isEmpty
            }

            if let replacementString = replacementString, !replacementString.isEmpty {
                lastAcceptedRange = nil
                lastAcceptedText = ""
            }
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Handle Tab to accept suggestion
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                _ = acceptSuggestion(from: textView)
                return true
            }

            if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                if let range = lastAcceptedRange,
                   textView.selectedRange().location == range.location + range.length {
                    textView.textStorage?.deleteCharacters(in: range)
                    text = textView.string
                    onDeleteAcceptedSuggestion(textView.string)
                    lastAcceptedRange = nil
                    lastAcceptedText = ""
                    return true
                }
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

        private func acceptSuggestion(from textView: NSTextView) -> String {
            let before = textView.selectedRange().location
            let accepted = onAcceptSuggestion()
            if !accepted.isEmpty {
                lastAcceptedRange = NSRange(location: before, length: accepted.count)
                lastAcceptedText = accepted
            }
            return accepted
        }

        private func acceptAllSuggestion(from textView: NSTextView) -> String {
            let before = textView.selectedRange().location
            let accepted = onAcceptAllSuggestion()
            if !accepted.isEmpty {
                lastAcceptedRange = NSRange(location: before, length: accepted.count)
                lastAcceptedText = accepted
            }
            return accepted
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 800, height: 600)
}
