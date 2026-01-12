import SwiftUI
import AppKit
import Combine

enum TextChangeSource {
    case key
    case ax
    case `internal`
}

/// Thread-safe atomic counter for tracking key presses across threads
final class AtomicKeyPressCounter: @unchecked Sendable {
    private var _value: Int64 = 0
    private let lock = NSLock()

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
        #if DEBUG
        print("[Typofast] keyPressCounter incremented to \(_value)")
        #endif
    }
}

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
    @Published var averageCachedTokensReused: Double = 0
    @Published var metricsSamples: Int = 0
    @Published var modelPath: String?
    @Published var disabledApps: [DisabledAppEntry] = []
    @Published var isGenerating = false
    @Published var windowContext: WindowTextContext?
    @Published var suggestedWordsCount: Int = 0
    @Published var acceptedWordsCount: Int = 0
    @Published var ocrContextEnabled: Bool = true

    private var inferenceTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var lastText = ""
    private var lastRequestedInput = ""
    private var lastAppliedSuggestion = ""
    private var lastEmptyCompletionInput: String?
    private var inFlightRequestId: UUID?
    private var suggestionAnchor = ""
    private var suppressNextInference = false
    /// Atomic counter that can be safely incremented from any thread (event tap callback)
    /// and read from MainActor without race conditions
    let keyPressCounter = AtomicKeyPressCounter()
    private var metricsObserver: NSObjectProtocol?
    private var disabledAppsById: [String: String] = [:]
    private let disabledAppsKey = "typofast.disabledApps"
    private let suggestedWordsKey = "typofast.suggestedWordsCount"
    private let acceptedWordsKey = "typofast.acceptedWordsCount"
    private let ocrContextEnabledKey = "typofast.ocrContextEnabled"
    private let defaultModelPath = "/Users/baptistelefort/Downloads/Qwen3-1.7B-Base.i1-Q4_K_M.gguf"
    private let debounceDelayNs: UInt64 = 0_000_000

    init() {
        loadAcceptanceStats()
        loadDisabledApps()
        loadOcrContextEnabled()
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
        suggestionAnchor = ""
        isGenerating = false
        lastRequestedInput = ""
        lastAppliedSuggestion = ""
        lastEmptyCompletionInput = nil
        inFlightRequestId = nil
        metrics = nil
    }

    func updateWindowContext(_ context: WindowTextContext?) {
        windowContext = context
    }

    /// Called immediately when a key is pressed, before onTextChange.
    /// This allows us to detect if keys were pressed while a completion was in flight.
    /// Note: This can be called from any thread (event tap callback) - the counter is atomic.
    nonisolated func notifyKeyPressed() {
        keyPressCounter.increment()
    }

    private func applyMetrics(_ updated: CompletionMetrics) {
        metrics = updated
        guard updated.ttft > 0 || updated.tokensPerSecond > 0 || updated.cachedTokensReused > 0 else { return }
        metricsSamples += 1
        let count = Double(metricsSamples)
        averageTtft = ((averageTtft * (count - 1)) + updated.ttft) / count
        averageTokensPerSecond = ((averageTokensPerSecond * (count - 1)) + updated.tokensPerSecond) / count
        averageCachedTokensReused = ((averageCachedTokensReused * (count - 1)) + Double(updated.cachedTokensReused)) / count
    }

    private func loadAcceptanceStats() {
        suggestedWordsCount = UserDefaults.standard.integer(forKey: suggestedWordsKey)
        acceptedWordsCount = UserDefaults.standard.integer(forKey: acceptedWordsKey)
    }

    private func persistAcceptanceStats() {
        UserDefaults.standard.set(suggestedWordsCount, forKey: suggestedWordsKey)
        UserDefaults.standard.set(acceptedWordsCount, forKey: acceptedWordsKey)
    }

    private func wordCount(in text: String) -> Int {
        let parts = text.split { $0.isWhitespace || $0.isNewline }
        return parts.count
    }

    private func addSuggestedWords(from suggestion: String) {
        let count = wordCount(in: suggestion)
        guard count > 0 else { return }
        suggestedWordsCount += count
        persistAcceptanceStats()
    }

    private func addAcceptedWords(from accepted: String) {
        let count = wordCount(in: accepted)
        guard count > 0 else { return }
        acceptedWordsCount += count
        persistAcceptanceStats()
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

    func onTextChange(_ newText: String, source: TextChangeSource = .ax) {
        if newText == lastText {
            return
        }
        let previousText = lastText
        logEvent("textChange", [
            "prev": previousText,
            "new": newText,
            "suggestion": suggestion,
            "base": suggestionBase,
            "offset": "\(suggestionOffset)"
        ])
        if lastEmptyCompletionInput != nil, lastEmptyCompletionInput != newText {
            lastEmptyCompletionInput = nil
        }
        let changeStart = CFAbsoluteTimeGetCurrent()
        if !suggestionBase.isEmpty,
           !suggestionAnchor.isEmpty,
           !newText.hasPrefix(suggestionAnchor),
           !suggestionAnchor.hasPrefix(newText) {
            inferenceTask?.cancel()
            suggestion = ""
            suggestionBase = ""
            suggestionOffset = 0
            suggestionAnchor = ""
            isGenerating = false
            lastRequestedInput = ""
            lastAppliedSuggestion = ""
            lastEmptyCompletionInput = nil
            inFlightRequestId = nil
            currentText = newText
            lastText = newText
            return
        }
        if suppressNextInference {
            suppressNextInference = false
            isGenerating = false
            lastRequestedInput = ""
            lastAppliedSuggestion = ""
            lastEmptyCompletionInput = nil
            inFlightRequestId = nil
            currentText = newText
            lastText = newText
            return
        }
        if updateSuggestionForTextChange(newText: newText) {
            inferenceTask?.cancel()
            isGenerating = false
            lastText = newText
            return
        }

        currentText = newText
        lastText = newText
        inferenceTask?.cancel()
        debounceTask?.cancel()
        inFlightRequestId = nil
        if newText == lastRequestedInput {
            return
        }
        isGenerating = false

        // Clear suggestion immediately if text is empty
        if newText.isEmpty {
            suggestion = ""
            suggestionBase = ""
            suggestionOffset = 0
            suggestionAnchor = ""
            metrics = nil
            isGenerating = false
            lastRequestedInput = ""
            lastAppliedSuggestion = ""
            lastEmptyCompletionInput = nil
            inFlightRequestId = nil
            lastText = ""
            return
        }
        if hasValidSuggestion(for: newText) {
            isGenerating = false
            return
        }
        if lastEmptyCompletionInput == newText {
            isGenerating = false
            return
        }
        if !shouldTriggerCompletion(newText) {
            suggestion = ""
            suggestionBase = ""
            suggestionOffset = 0
            suggestionAnchor = ""
            metrics = nil
            isGenerating = false
            lastRequestedInput = ""
            lastAppliedSuggestion = ""
            lastEmptyCompletionInput = nil
            inFlightRequestId = nil
            return
        }

        debounceTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: debounceDelayNs)
            guard !Task.isCancelled else { return }
            guard currentText == newText else { return }
            if newText == lastRequestedInput { return }
            if hasValidSuggestion(for: newText) { return }
            if lastEmptyCompletionInput == newText { return }
            isGenerating = true
            lastRequestedInput = newText
            let requestStart = CFAbsoluteTimeGetCurrent()
            inferenceTask?.cancel()
            inferenceTask = Task { @MainActor in
                let requestId = UUID()
                inFlightRequestId = requestId
                await requestCompletion(newText, requestId: requestId)
            }
            await inferenceTask?.value
            let requestEnd = CFAbsoluteTimeGetCurrent()
            isGenerating = false
            logEvent("timing.requestCompletion", [
                "durationMs": String(format: "%.2f", (requestEnd - requestStart) * 1000.0),
                "textLength": "\(newText.count)"
            ])
        }

        let changeEnd = CFAbsoluteTimeGetCurrent()
        logEvent("timing.onTextChange", [
            "durationMs": String(format: "%.2f", (changeEnd - changeStart) * 1000.0),
            "textLength": "\(newText.count)"
        ])
    }

    private func requestCompletion(_ text: String, requestId: UUID) async {
        guard let engine = engine else { return }

        // Capture the key press counter at request start
        // If any key is pressed during the request, this counter will change
        // This is atomic and can be updated from the event tap thread synchronously
        let startKeyCount = keyPressCounter.value

        let systemPrompt = """
        User context: My name is Baptiste Lefort. I usually write in English and French.
        Write causally with low ponctuation (I espcially rarely use commas). Keep your sentences short, concise and readable.
        """
        let trimmedText = trimTrailingSpaces(text)
        var promptParts: [String] = [systemPrompt]
        if let context = windowContext, !context.text.isEmpty {
            promptParts.append(context.promptBlock(maxTextLength: 1200))
            logEvent("contextUsed", [
                "source": context.source.rawValue,
                "len": "\(context.text.count)",
                "title": context.windowTitle ?? ""
            ])
        }
        promptParts.append(trimmedText)
        let modelPrompt = promptParts.joined(separator: "\n\n")
        logEvent("requestCompletion", [
            "text": text,
            "modelPrompt": modelPrompt
        ])
        let generationStart = CFAbsoluteTimeGetCurrent()
        let (completion, completionMetrics) = await engine.getCompletion(
            prompt: modelPrompt,
            inputText: text,
            maxTokens: 6
        )

        // Check if this request was cancelled while waiting
        guard !Task.isCancelled else { return }
        guard inFlightRequestId == requestId else { return }

        // Check if any key was pressed during the request
        // The atomic counter is updated synchronously from the event tap callback thread,
        // so this check is reliable without any timing delays
        let currentKeyCount = keyPressCounter.value
        guard currentKeyCount == startKeyCount else {
            #if DEBUG
            print("[Typofast] discarding completion: keyCount changed from \(startKeyCount) to \(currentKeyCount)")
            #endif
            return
        }

        let generationEnd = CFAbsoluteTimeGetCurrent()
        logEvent("timing.engineCompletion", [
            "durationMs": String(format: "%.2f", (generationEnd - generationStart) * 1000.0),
            "tokens": "\(completionMetrics.tokensGenerated)",
            "tps": String(format: "%.2f", completionMetrics.tokensPerSecond),
            "ttft": String(format: "%.2f", completionMetrics.ttft * 1000.0)
        ])

        lastAppliedSuggestion = completion
        if completion.isEmpty {
            lastEmptyCompletionInput = text
        } else {
            lastEmptyCompletionInput = nil
        }
        suggestionBase = completion
        suggestionOffset = 0
        suggestion = completion
        suggestionAnchor = text
        if !completion.isEmpty {
            addSuggestedWords(from: completion)
        }
        logEvent("completionReceived", [
            "raw": completion,
            "sanitized": completion
        ])
        logEvent("timing.suggestionApplied", [
            "suggestionLength": "\(completion.count)"
        ])
        applyMetrics(completionMetrics)
    }

    func acceptSuggestion() -> String {
        let accepted = acceptedSuggestionText(firstWordOnly: true)
        guard !accepted.isEmpty else { return "" }

        let newText = currentText + accepted
        applyAcceptedSuggestion(accepted: accepted, newText: newText, keepRemaining: true)
        return accepted
    }

    func acceptAllSuggestion() -> String {
        let accepted = acceptedSuggestionText(firstWordOnly: false)
        guard !accepted.isEmpty else { return "" }

        let newText = currentText + accepted
        applyAcceptedSuggestion(accepted: accepted, newText: newText, keepRemaining: false)
        return accepted
    }

    func acceptedSuggestionText(firstWordOnly: Bool) -> String {
        guard !suggestion.isEmpty else { return "" }
        if firstWordOnly {
            return firstWordWithLeadingWhitespace(from: suggestion)
        }
        return suggestion
    }

    func applyAcceptedSuggestion(accepted: String, newText: String, keepRemaining: Bool) {
        guard !accepted.isEmpty else { return }

        addAcceptedWords(from: accepted)

        if keepRemaining, !suggestionBase.isEmpty {
            suggestionOffset += accepted.count
            if suggestionOffset < suggestionBase.count {
                suggestion = String(suggestionBase.dropFirst(suggestionOffset))
                suggestionAnchor = newText
            } else {
                suggestion = ""
                suggestionBase = ""
                suggestionOffset = 0
                suggestionAnchor = ""
                metrics = nil
            }
        } else {
            suggestion = ""
            suggestionBase = ""
            suggestionOffset = 0
            suggestionAnchor = ""
            metrics = nil
        }

        suppressNextInference = true
        currentText = newText
        lastText = newText
    }

    func regenerateAfterDeletingAcceptedSuggestion(newText: String) {
        suggestion = ""
        suggestionBase = ""
        suggestionOffset = 0
        suggestionAnchor = ""
        metrics = nil
        lastText = ""
        onTextChange(newText, source: .internal)
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

    private func updateSuggestionForTextChange(newText: String) -> Bool {
        guard !suggestionBase.isEmpty else { return false }
        guard !suggestionAnchor.isEmpty else { return false }
        guard newText.hasPrefix(suggestionAnchor) else {
            suggestion = ""
            suggestionBase = ""
            suggestionOffset = 0
            suggestionAnchor = ""
            metrics = nil
            return false
        }

        let consumed = String(newText.dropFirst(suggestionAnchor.count))
        guard suggestionBase.hasPrefix(consumed) else {
            suggestion = ""
            suggestionBase = ""
            suggestionOffset = 0
            suggestionAnchor = ""
            metrics = nil
            return false
        }

        suggestionOffset = consumed.count
        suggestion = String(suggestionBase.dropFirst(suggestionOffset))
        currentText = newText
        logEvent("keepSuggestion.matching", [
            "typed": consumed,
            "remaining": suggestion
        ])
        return true
    }

    private func hasValidSuggestion(for newText: String) -> Bool {
        guard !suggestionBase.isEmpty else { return false }
        guard !suggestionAnchor.isEmpty else { return false }
        guard newText.hasPrefix(suggestionAnchor) else { return false }
        let consumed = String(newText.dropFirst(suggestionAnchor.count))
        return suggestionBase.hasPrefix(consumed)
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

    private func loadOcrContextEnabled() {
        if UserDefaults.standard.object(forKey: ocrContextEnabledKey) == nil {
            ocrContextEnabled = true
        } else {
            ocrContextEnabled = UserDefaults.standard.bool(forKey: ocrContextEnabledKey)
        }
    }

    func setOcrContextEnabled(_ enabled: Bool) {
        ocrContextEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: ocrContextEnabledKey)
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

            sectionView(title: "OCR Context", systemImage: "eye") {
                Toggle("Enable OCR context", isOn: Binding(
                    get: { appState.ocrContextEnabled },
                    set: { appState.setOcrContextEnabled($0) }
                ))
                .font(.system(.body, design: .rounded))
            }
        }
        .padding(14)
        .frame(width: 360, height: 280)
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

    private func statsContent() -> some View {
        let acceptancePercent = appState.suggestedWordsCount > 0
            ? (Double(appState.acceptedWordsCount) / Double(appState.suggestedWordsCount)) * 100.0
            : 0.0
        return VStack(alignment: .leading, spacing: 4) {
            if appState.metricsSamples > 0 {
                Text("Avg TTFT \(String(format: "%.0f", appState.averageTtft * 1000)) ms  •  Avg \(String(format: "%.1f", appState.averageTokensPerSecond)) tok/s  •  Avg Cache \(String(format: "%.1f", appState.averageCachedTokensReused))")
                    .font(.system(.body, design: .rounded))
            } else {
                Text(appState.isLoading ? "Loading…" : "No stats yet")
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(.secondary)
            }
            Text("Acceptance \(String(format: "%.0f", acceptancePercent))%  •  Suggested \(appState.suggestedWordsCount) words  •  Accepted \(appState.acceptedWordsCount) words")
                .font(.system(.body, design: .rounded))
                .foregroundColor(.secondary)
        }
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
