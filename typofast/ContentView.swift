import SwiftUI
import AppKit
import Combine

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
    @Published var averageTtft: Double = 0
    @Published var averageTokensPerSecond: Double = 0
    @Published var metricsSamples: Int = 0
    @Published var modelPath: String?
    @Published var disabledApps: [DisabledAppEntry] = []

    private var inferenceTask: Task<Void, Never>?
    private var lastText = ""
    private var metricsObserver: NSObjectProtocol?
    private var disabledAppsById: [String: String] = [:]
    private let disabledAppsKey = "typofast.disabledApps"
    private let defaultModelPath = "/Users/baptistelefort/Downloads/Qwen3-1.7B-Base.i1-Q4_K_M.gguf"

    init() {
        loadDisabledApps()
        loadDefaultModelIfNeeded()
        metricsObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("TypofastMetricsUpdate"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let userInfo = notification.userInfo else { return }
            var updated = CompletionMetrics()
            if let ttft = userInfo["ttft"] as? Double {
                updated.ttft = ttft
            }
            if let tps = userInfo["tokensPerSecond"] as? Double {
                updated.tokensPerSecond = tps
            }
            if let tokens = userInfo["tokensGenerated"] as? Int {
                updated.tokensGenerated = tokens
            }
            if let reused = userInfo["cachedTokensReused"] as? Int {
                updated.cachedTokensReused = reused
            }
            self.applyMetrics(updated)
        }
    }

    deinit {
        if let observer = metricsObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    func isAppDisabled(bundleId: String) -> Bool {
        return disabledAppsById[bundleId] != nil
    }

    func setAppDisabled(bundleId: String, name: String?, disabled: Bool) {
        if disabled {
            disabledAppsById[bundleId] = name ?? bundleId
        } else {
            disabledAppsById.removeValue(forKey: bundleId)
        }
        persistDisabledApps()
        publishDisabledApps()
    }

    func clearSuggestion() {
        suggestion = ""
        suggestionBase = ""
        suggestionOffset = 0
        metrics = nil
    }

    private func applyMetrics(_ updated: CompletionMetrics) {
        metrics = updated
        guard updated.ttft > 0 || updated.tokensPerSecond > 0 else { return }
        metricsSamples += 1
        let count = Double(metricsSamples)
        averageTtft = ((averageTtft * (count - 1)) + updated.ttft) / count
        averageTokensPerSecond = ((averageTokensPerSecond * (count - 1)) + updated.tokensPerSecond) / count
    }

    func loadModel(path: String) async {
        isLoading = true
        loadingStatus = "Loading model..."

        do {
            let engine = AutocompleteEngine()
            try await engine.loadModel(path: path)
            self.engine = engine
            self.modelPath = path
            UserDefaults.standard.set(path, forKey: "typofast.modelPath")
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
        if !shouldTriggerCompletion(newText) {
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
            applyMetrics(completionMetrics)
        }
    }

    func acceptSuggestion() -> String {
        let accepted = acceptedSuggestionText(firstWordOnly: true)
        guard !accepted.isEmpty else { return "" }

        let newText = currentText + accepted
        applyAcceptedSuggestion(accepted: accepted, newText: newText)
        return accepted
    }

    func acceptAllSuggestion() -> String {
        let accepted = acceptedSuggestionText(firstWordOnly: false)
        guard !accepted.isEmpty else { return "" }

        let newText = currentText + accepted
        applyAcceptedSuggestion(accepted: accepted, newText: newText)
        return accepted
    }

    func acceptedSuggestionText(firstWordOnly: Bool) -> String {
        guard !suggestion.isEmpty else { return "" }
        if firstWordOnly {
            return firstWordWithLeadingWhitespace(from: suggestion)
        }
        return suggestion
    }

    func applyAcceptedSuggestion(accepted: String, newText: String) {
        guard !accepted.isEmpty else { return }

        suggestion = ""
        suggestionBase = ""
        suggestionOffset = 0
        metrics = nil

        currentText = newText
        onTextChange(newText)
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

    private func shouldTriggerCompletion(_ text: String) -> Bool {
        // V0 logic: only trigger after at least one completed word (word + whitespace)
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
        clearSuggestion()
        if let engine = engine {
            await engine.resetCache()
        }
    }

    private func loadDisabledApps() {
        if let data = UserDefaults.standard.data(forKey: disabledAppsKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            disabledAppsById = decoded
        } else {
            disabledAppsById = Self.defaultDisabledApps
        }
        publishDisabledApps()
    }

    private func loadDefaultModelIfNeeded() {
        guard FileManager.default.fileExists(atPath: defaultModelPath) else {
            loadingStatus = "Default model not found at \(defaultModelPath)"
            return
        }
        Task {
            await loadModel(path: defaultModelPath)
        }
    }

    private func persistDisabledApps() {
        if let data = try? JSONEncoder().encode(disabledAppsById) {
            UserDefaults.standard.set(data, forKey: disabledAppsKey)
        }
    }

    private func publishDisabledApps() {
        disabledApps = disabledAppsById.map { DisabledAppEntry(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var modelDisplayName: String {
        URL(fileURLWithPath: modelPath ?? defaultModelPath).lastPathComponent
    }

    private static let defaultDisabledApps: [String: String] = [
        "com.apple.Terminal": "Terminal",
        "com.apple.dt.Xcode": "Xcode",
        "com.googlecode.iterm2": "iTerm2",
        "dev.warp.Warp-Stable": "Warp",
        "com.microsoft.VSCode": "Visual Studio Code"
    ]
}

struct DisabledAppEntry: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var globalController: GlobalSuggestionController

    var body: some View {
        VStack(spacing: 10) {
            sectionView(title: "Model", systemImage: "brain") {
                Text(appState.modelDisplayName)
                    .font(.system(.body, design: .rounded))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            sectionView(title: "Statistics", systemImage: "speedometer") {
                statsContent()
            }

            sectionView(title: "Permissions", systemImage: "checkmark.seal") {
                Text(permissionsStatusText())
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(permissionsOk() ? .secondary : .primary)
            }
        }
        .padding(14)
        .frame(width: 360, height: 220)
        .onAppear {
            globalController.start()
        }
    }

    private func permissionsOk() -> Bool {
        globalController.accessibilityEnabled
            && globalController.inputMonitoringEnabled
            && globalController.screenRecordingEnabled
    }

    private func permissionsStatusText() -> String {
        if permissionsOk() {
            return "OK"
        }
        var missing: [String] = []
        if !globalController.accessibilityEnabled {
            missing.append("Accessibility")
        }
        if !globalController.inputMonitoringEnabled {
            missing.append("Input Monitoring")
        }
        if !globalController.screenRecordingEnabled {
            missing.append("Screen Recording")
        }
        return "Missing: " + missing.joined(separator: ", ")
    }

    private func statsContent() -> Text {
        if let metrics = appState.metrics {
            return Text("TTFT \(String(format: "%.0f", metrics.ttft * 1000)) ms  •  \(String(format: "%.1f", metrics.tokensPerSecond)) tok/s  •  Cache \(metrics.cachedTokensReused)")
                .font(.system(.body, design: .rounded))
        }
        return Text(appState.isLoading ? "Loading…" : "No stats yet")
            .font(.system(.body, design: .rounded))
            .foregroundColor(.secondary)
    }

    private func sectionView<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

#Preview {
    let state = AppState()
    ContentView(appState: state, globalController: GlobalSuggestionController(appState: state))
        .frame(width: 800, height: 600)
}
