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
    @Published var systemPrompt: String = ""

    private var inferenceTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var lastText = ""
    private var lastRequestedInput = ""
    private var lastAppliedSuggestion = ""
    private var lastEmptyCompletionInput: String?
    private var inFlightRequestId: UUID?
    private var textChangeCounter: Int64 = 0
    private var suggestionAnchor = ""
    private var suppressNextInference = false
    private var hasLoggedMissingEngine = false
    /// Atomic counter that can be safely incremented from any thread (event tap callback)
    /// and read from MainActor without race conditions
    let keyPressCounter = AtomicKeyPressCounter()
    private var metricsObserver: NSObjectProtocol?
    private var disabledAppsById: [String: String] = [:]
    private let disabledAppsKey = "typofast.disabledApps"
    private let suggestedWordsKey = "typofast.suggestedWordsCount"
    private let acceptedWordsKey = "typofast.acceptedWordsCount"
    private let averageTtftKey = "typofast.averageTtft"
    private let averageTokensPerSecondKey = "typofast.averageTokensPerSecond"
    private let averageCachedTokensReusedKey = "typofast.averageCachedTokensReused"
    private let metricsSamplesKey = "typofast.metricsSamples"
    private let ocrContextEnabledKey = "typofast.ocrContextEnabled"
    private let systemPromptKey = "typofast.systemPrompt"
    private let managedModelRepository = "unsloth/gemma-4-E2B-it-GGUF"
    private let managedModelFilename = "gemma-4-E2B-it-Q4_K_M.gguf"
    private let managedModelRemoteURL = URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf?download=true")!
    private let defaultSystemPrompt = """
        User context: My name is Baptiste Lefort. I usually write in English and French.
        Write causally with low ponctuation (I espcially rarely use commas). Keep your sentences short, concise and readable.
        """
    private let debounceDelayNs: UInt64 = 120_000_000

    init() {
        loadAcceptanceStats()
        loadPerformanceStats()
        loadDisabledApps()
        loadOcrContextEnabled()
        loadSystemPrompt()
        loadInitialModelIfNeeded()
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
        persistPerformanceStats()
    }

    private func loadAcceptanceStats() {
        suggestedWordsCount = UserDefaults.standard.integer(forKey: suggestedWordsKey)
        acceptedWordsCount = UserDefaults.standard.integer(forKey: acceptedWordsKey)
    }

    private func persistAcceptanceStats() {
        UserDefaults.standard.set(suggestedWordsCount, forKey: suggestedWordsKey)
        UserDefaults.standard.set(acceptedWordsCount, forKey: acceptedWordsKey)
    }

    func resetAcceptanceStats() {
        suggestedWordsCount = 0
        acceptedWordsCount = 0
        UserDefaults.standard.removeObject(forKey: suggestedWordsKey)
        UserDefaults.standard.removeObject(forKey: acceptedWordsKey)
    }

    private func loadPerformanceStats() {
        metricsSamples = UserDefaults.standard.integer(forKey: metricsSamplesKey)
        averageTtft = UserDefaults.standard.double(forKey: averageTtftKey)
        averageTokensPerSecond = UserDefaults.standard.double(forKey: averageTokensPerSecondKey)
        averageCachedTokensReused = UserDefaults.standard.double(forKey: averageCachedTokensReusedKey)
        if metricsSamples == 0,
           averageTtft > 0 || averageTokensPerSecond > 0 || averageCachedTokensReused > 0 {
            metricsSamples = 1
        }
    }

    private func persistPerformanceStats() {
        UserDefaults.standard.set(metricsSamples, forKey: metricsSamplesKey)
        UserDefaults.standard.set(averageTtft, forKey: averageTtftKey)
        UserDefaults.standard.set(averageTokensPerSecond, forKey: averageTokensPerSecondKey)
        UserDefaults.standard.set(averageCachedTokensReused, forKey: averageCachedTokensReusedKey)
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
            loadingStatus = "Model loaded successfully!"
            hasLoggedMissingEngine = false
            #if DEBUG
            print("[Typofast] model loaded path=\"\(path)\"")
            #endif

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            isLoading = false
        } catch {
            self.engine = nil
            loadingStatus = "Error loading model: \(error.localizedDescription)"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            isLoading = false
        }
    }

    func onTextChange(_ newText: String, source: TextChangeSource = .ax) {
        if newText == lastText {
            return
        }
        textChangeCounter += 1
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
        guard engine != nil else {
            isGenerating = false
            #if DEBUG
            if !hasLoggedMissingEngine {
                hasLoggedMissingEngine = true
                print("[Typofast] completion skipped: no model loaded")
            }
            #endif
            return
        }
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
        let startChangeCounter = textChangeCounter

        let trimmedText = trimTrailingSpaces(text)
        var contextBlock = ""
        if let context = windowContext,
           let filteredContext = filteredWindowContext(context, inputText: trimmedText),
           !filteredContext.text.isEmpty {
            contextBlock = filteredContext.promptBlock(maxTextLength: 1200)
            logEvent("contextUsed", [
                "source": filteredContext.source.rawValue,
                "len": "\(filteredContext.text.count)",
                "title": filteredContext.windowTitle ?? ""
            ])
        }
        let modelPrompt = buildCompletionPrompt(text: text, contextBlock: contextBlock)
        logEvent("requestCompletion", [
            "text": text,
            "modelPrompt": modelPrompt
        ])
        let generationStart = CFAbsoluteTimeGetCurrent()
        let (completion, completionMetrics) = await engine.getCompletion(
            prompt: modelPrompt,
            inputText: text,
            maxTokens: 10
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
        guard textChangeCounter == startChangeCounter else {
            #if DEBUG
            print("[Typofast] discarding completion: text changed during request")
            #endif
            return
        }
        guard currentText == text else {
            #if DEBUG
            print("[Typofast] discarding completion: currentText drifted from request text")
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

        let sanitizedCompletion = sanitizeCompletion(completion, inputText: text)
        lastAppliedSuggestion = sanitizedCompletion
        if sanitizedCompletion.isEmpty {
            lastEmptyCompletionInput = text
        } else {
            lastEmptyCompletionInput = nil
        }
        suggestionBase = sanitizedCompletion
        suggestionOffset = 0
        suggestion = sanitizedCompletion
        suggestionAnchor = text
        if !sanitizedCompletion.isEmpty {
            addSuggestedWords(from: sanitizedCompletion)
        }
        logEvent("completionReceived", [
            "raw": completion,
            "sanitized": sanitizedCompletion
        ])
        logEvent("timing.suggestionApplied", [
            "suggestionLength": "\(sanitizedCompletion.count)"
        ])
        applyMetrics(completionMetrics)
    }

    private func buildCompletionPrompt(text: String, contextBlock: String) -> String {
        let stylePrompt = (systemPrompt.isEmpty ? defaultSystemPrompt : systemPrompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let inlineInput = currentInlineInput(from: text)
        var prompt = "\(stylePrompt)\n\n"
        if !contextBlock.isEmpty {
            prompt += "\(contextBlock)\n\n"
        }
        prompt += inlineInput
        return prompt
    }

    private func sanitizeCompletion(_ raw: String, inputText: String) -> String {
        guard !raw.isEmpty else { return "" }

        let hadLeadingWhitespace = raw.first?.isWhitespace == true
        var cleaned = raw
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        cleaned = String(cleaned.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        })

        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;:!?()[]{}<>/\\"))
        guard !cleaned.isEmpty else { return "" }

        let inputLine = trimTrailingSpaces(currentInlineInput(from: inputText))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !inputLine.isEmpty {
            if cleaned == inputLine {
                return ""
            }
            if cleaned.hasPrefix(inputLine + " ") {
                cleaned = String(cleaned.dropFirst(inputLine.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;:!?()[]{}<>/\\"))
                guard !cleaned.isEmpty else { return "" }
            }
        }

        let lowered = cleaned.lowercased()
        let blockedPrefixes = [
            "assistant:",
            "user:",
            "system:",
            "okay, so",
            "here is",
            "here's",
            "i can"
        ]
        if blockedPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            return ""
        }
        let blockedFragments = [
            "baptiste lefort",
            "insert here",
            "current text",
            "continuation:",
            "next words:",
            "<cursor",
            "<|im_",
            "the user",
            "as an ai",
            "role:",
            "**"
        ]
        if blockedFragments.contains(where: { lowered.contains($0) }) {
            return ""
        }
        if cleaned.range(of: #"[\[\]\{\}\*]"#, options: .regularExpression) != nil {
            return ""
        }

        let words = cleaned.split { $0.isWhitespace || $0.isNewline }
        if words.isEmpty {
            return ""
        }
        if words.count > 6 {
            cleaned = words.prefix(6).joined(separator: " ")
        }

        let endsWithWhitespace = inputText.last?.isWhitespace ?? false
        if !endsWithWhitespace, hadLeadingWhitespace, cleaned.first?.isLetter == true {
            return " " + cleaned
        }
        return cleaned
    }

    private func currentInlineInput(from text: String) -> String {
        let segments = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if let last = segments.last {
            return String(last)
        }
        return text
    }

    private func filteredWindowContext(_ context: WindowTextContext, inputText: String) -> WindowTextContext? {
        let maxAge: TimeInterval = context.source == .ocr ? 1.0 : 3.0
        guard context.isFresh(maxAge: maxAge) else { return nil }
        guard context.source == .ocr else { return context }

        let normalizedInputLines = normalizeLines(inputText)
        if normalizedInputLines.isEmpty {
            return context
        }

        let filteredLines = context.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let normalizedLine = normalizeLine(String(line))
                guard !normalizedLine.isEmpty else { return false }
                return !normalizedInputLines.contains { inputLine in
                    shouldExcludeLine(normalizedLine, inputLine: inputLine)
                }
            }

        let filteredText = filteredLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filteredText.isEmpty else { return nil }

        return WindowTextContext(
            appName: context.appName,
            bundleId: context.bundleId,
            windowTitle: context.windowTitle,
            source: context.source,
            text: filteredText,
            capturedAt: context.capturedAt
        )
    }

    private func normalizeLines(_ text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let normalized = lines.map(normalizeLine).filter { !$0.isEmpty }
        return Array(Set(normalized))
    }

    private func normalizeLine(_ text: String) -> String {
        let transformed = text.applyingTransform(.toLatin, reverse: false) ?? text
        let folded = transformed.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        let lowered = folded.lowercased()
        let filtered = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let collapsed = String(filtered).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldExcludeLine(_ normalizedLine: String, inputLine: String) -> Bool {
        guard normalizedLine.count >= 6, inputLine.count >= 6 else { return false }
        if inputLine.contains(normalizedLine) || normalizedLine.contains(inputLine) {
            return true
        }
        let prefixLength = min(24, inputLine.count)
        if prefixLength >= 8 {
            let prefix = String(inputLine.prefix(prefixLength))
            if normalizedLine.contains(prefix) {
                return true
            }
        }
        return false
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
        let remainingBase = String(suggestionBase.dropFirst(suggestionOffset))
        guard remainingBase.hasPrefix(consumed) else {
            #if DEBUG
            logEvent("keepSuggestion.mismatch", [
                "anchor": suggestionAnchor,
                "base": suggestionBase,
                "offset": "\(suggestionOffset)",
                "remainingBase": remainingBase,
                "typed": consumed
            ])
            #endif
            suggestion = ""
            suggestionBase = ""
            suggestionOffset = 0
            suggestionAnchor = ""
            metrics = nil
            return false
        }

        suggestionOffset += consumed.count
        suggestion = String(suggestionBase.dropFirst(suggestionOffset))
        currentText = newText
        suggestionAnchor = newText
        logEvent("keepSuggestion.matching", [
            "typed": consumed,
            "remaining": suggestion,
            "offset": "\(suggestionOffset)"
        ])
        return true
    }

    private func hasValidSuggestion(for newText: String) -> Bool {
        guard !suggestionBase.isEmpty else { return false }
        guard !suggestionAnchor.isEmpty else { return false }
        guard newText.hasPrefix(suggestionAnchor) else { return false }
        let consumed = String(newText.dropFirst(suggestionAnchor.count))
        let remainingBase = String(suggestionBase.dropFirst(suggestionOffset))
        return remainingBase.hasPrefix(consumed)
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

    private func loadInitialModelIfNeeded() {
        Task {
            await ensureManagedModelLoaded()
        }
    }

    private func ensureManagedModelLoaded() async {
        do {
            let localURL = try await ensureManagedModelOnDisk()
            await loadModel(path: localURL.path)
        } catch {
            loadingStatus = "Error preparing model: \(error.localizedDescription)"
            isLoading = false
            #if DEBUG
            print("[Typofast] failed to prepare managed model: \(error)")
            #endif
        }
    }

    private func ensureManagedModelOnDisk() async throws -> URL {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let modelDirectory = appSupport
            .appendingPathComponent("typofast", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let modelURL = modelDirectory.appendingPathComponent(managedModelFilename, isDirectory: false)
        #if DEBUG
        print("[Typofast] managed model path=\"\(modelURL.path)\"")
        #endif
        if fileManager.fileExists(atPath: modelURL.path) {
            #if DEBUG
            print("[Typofast] found local managed model")
            #endif
            return modelURL
        }

        loadingStatus = "Downloading \(managedModelRepository)..."
        isLoading = true
        #if DEBUG
        print("[Typofast] downloading model from \(managedModelRemoteURL.absoluteString)")
        #endif
        let (temporaryURL, response) = try await URLSession.shared.download(from: managedModelRemoteURL)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }

        if fileManager.fileExists(atPath: modelURL.path) {
            try fileManager.removeItem(at: modelURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: modelURL)
        return modelURL
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

    private func loadSystemPrompt() {
        if let saved = UserDefaults.standard.string(forKey: systemPromptKey), !saved.isEmpty {
            systemPrompt = saved
        } else {
            systemPrompt = defaultSystemPrompt
        }
    }

    func setSystemPrompt(_ prompt: String) {
        systemPrompt = prompt
        UserDefaults.standard.set(prompt, forKey: systemPromptKey)
    }

    var modelDisplayName: String {
        guard let modelPath else { return managedModelFilename }
        return URL(fileURLWithPath: modelPath).lastPathComponent
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
    @State private var isEditingPrompt = false
    @State private var isEditingRestrictions = false
    @State private var runningApps: [(bundleId: String, name: String)] = []

    var body: some View {
        let tileSpacing: CGFloat = 8
        let panelWidth: CGFloat = 320
        let horizontalPadding: CGFloat = 12
        let contentWidth = panelWidth - (horizontalPadding * 2)
        let columnWidth = (contentWidth - tileSpacing) / 2
        let smallTileHeight: CGFloat = 80

        return VStack(spacing: tileSpacing) {
            // Row 1: Header + TTFT
            HStack(spacing: tileSpacing) {
                tileView(backgroundColor: statusTileColor()) {
                    headerView()
                }
                .frame(width: columnWidth, height: smallTileHeight)

                statTile(
                    value: hasPerformanceStats ? String(format: "%.0f", appState.averageTtft * 1000) : "-",
                    unit: "ms",
                    label: "Avg TTFT"
                )
                .frame(width: columnWidth, height: smallTileHeight)
            }

            // Row 2: OCR + tok/s
            HStack(spacing: tileSpacing) {
                tileView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "eye")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("OCR")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        HStack {
                            Text("Context")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { appState.ocrContextEnabled },
                                set: { appState.setOcrContextEnabled($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.blue)
                        }
                    }
                }
                .frame(width: columnWidth, height: smallTileHeight)

                statTile(
                    value: hasPerformanceStats ? String(format: "%.1f", appState.averageTokensPerSecond) : "-",
                    unit: "tok/s",
                    label: "Avg Speed"
                )
                .frame(width: columnWidth, height: smallTileHeight)
            }

            // Row 3: Acceptance + Suggested
            HStack(spacing: tileSpacing) {
                statTile(
                    value: appState.suggestedWordsCount > 0
                        ? String(format: "%.0f", (Double(appState.acceptedWordsCount) / Double(appState.suggestedWordsCount)) * 100)
                        : "0",
                    unit: "%",
                    label: "Acceptance"
                )
                .frame(width: columnWidth, height: smallTileHeight)

                statTileWithReset(
                    value: formatNumber(appState.suggestedWordsCount),
                    label: "Suggested",
                    onReset: { appState.resetAcceptanceStats() }
                )
                .frame(width: columnWidth, height: smallTileHeight)
            }

            // Row 4: About you
            tileView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.bubble")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("About you")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Toggle(isOn: $isEditingPrompt) {
                            Label("Edit", systemImage: "pencil.line")
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }

                    if isEditingPrompt {
                        TextEditor(text: Binding(
                            get: { appState.systemPrompt },
                            set: { appState.setSystemPrompt($0) }
                        ))
                        .font(.system(.callout, design: .rounded))
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(NSColor.textBackgroundColor))
                        )
                    } else {
                        Text(promptPreview())
                            .font(.system(.callout, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .frame(width: contentWidth)

            // Row 5: Restrictions
            tileView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.raised")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Restrictions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Toggle(isOn: $isEditingRestrictions) {
                            Label("Edit", systemImage: "pencil.line")
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }

                    if isEditingRestrictions {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(appState.disabledApps) { app in
                                HStack {
                                    Text(app.name)
                                        .font(.system(.callout, design: .rounded))
                                    Spacer()
                                    Button(action: {
                                        appState.setAppDisabled(bundleId: app.id, name: nil, disabled: false)
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Menu {
                                ForEach(runningApps.filter { app in
                                    !appState.disabledApps.contains { $0.id == app.bundleId }
                                }, id: \.bundleId) { app in
                                    Button(app.name) {
                                        appState.setAppDisabled(bundleId: app.bundleId, name: app.name, disabled: true)
                                    }
                                }
                            } label: {
                                Label("Add app", systemImage: "plus.circle")
                                    .font(.system(.callout, design: .rounded))
                            }
                            .onAppear { refreshRunningApps() }
                        }
                        .frame(maxHeight: 100)
                    } else {
                        if appState.disabledApps.isEmpty {
                            Text("No restrictions")
                                .font(.system(.callout, design: .rounded))
                                .foregroundColor(.secondary)
                        } else {
                            Text(appState.disabledApps.map(\.name).joined(separator: ", "))
                                .font(.system(.callout, design: .rounded))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .frame(width: contentWidth)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, horizontalPadding)
        .frame(width: panelWidth)
    }

    private func refreshRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .compactMap { app in
                guard let bundleId = app.bundleIdentifier else { return nil }
                let name = app.localizedName ?? bundleId
                return (bundleId: bundleId, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func statTile(value: String, unit: String? = nil, label: String) -> some View {
        tileView {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    if let unit = unit {
                        Text(unit)
                            .font(.system(.caption, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func statTileWithReset(value: String, label: String, onReset: @escaping () -> Void) -> some View {
        tileView {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label)
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: onReset) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset statistics")
                }
                Spacer()
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
            }
        }
    }

    private func headerView() -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Typofast")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Text(headerStatusText)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.secondary)
                if appState.engine == nil, !appState.loadingStatus.isEmpty {
                    Text(appState.loadingStatus)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: "text.cursor")
                .font(.title2)
                .foregroundColor(.secondary)
        }
    }

    private var hasPerformanceStats: Bool {
        appState.metricsSamples > 0
            || appState.averageTtft > 0
            || appState.averageTokensPerSecond > 0
            || appState.averageCachedTokensReused > 0
    }

    private var headerStatusText: String {
        if appState.isLoading {
            return "Loading model..."
        }
        if appState.engine != nil {
            return "Ready"
        }
        return "No model loaded"
    }

    private func promptPreview() -> String {
        let trimmed = appState.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "No system prompt set"
        }
        return trimmed
    }

    private func formatNumber(_ num: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }

    private func tileView<Content: View>(
        backgroundColor: Color? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(backgroundColor ?? Color.clear)
        )
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 8)
    }

    private func statusTileColor() -> Color {
        appState.isLoading ? Color(NSColor.systemOrange).opacity(0.35) : Color(NSColor.systemGreen).opacity(0.30)
    }
}

#Preview {
    let state = AppState()
    ContentView(appState: state)
        .frame(width: 800, height: 600)
}
