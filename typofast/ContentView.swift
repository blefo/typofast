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
    @Published var completionLength: CompletionLength = .medium
    @Published var customInstructions: String = ""
    @Published var minWordsToSuggest: Int = 3

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
    private let completionLengthKey = "typofast.completionLength"
    private let customInstructionsKey = "typofast.customInstructions"
    private let minWordsToSuggestKey = "typofast.minWordsToSuggest"
    private let managedModelRepository = "mradermacher/gemma-4-E2B-i1-GGUF"
    private let managedModelFilename = "gemma-4-E2B.i1-Q4_K_M.gguf"
    private let managedModelRemoteURL = URL(string: "https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF/resolve/main/gemma-4-E2B.i1-Q4_K_M.gguf?download=true")!
    private let managedModelAddBos = true
    private let debounceDelayNs: UInt64 = 25_000_000

    init() {
        loadAcceptanceStats()
        loadPerformanceStats()
        loadDisabledApps()
        loadOcrContextEnabled()
        loadCompletionSettings()
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

    func loadModel(path: String, addBos: Bool = true) async {
        isLoading = true
        loadingStatus = "Loading model..."

        do {
            let engine = AutocompleteEngine()
            try await engine.loadModel(path: path, addBos: addBos)
            self.engine = engine
            self.modelPath = path
            UserDefaults.standard.set(path, forKey: "typofast.modelPath")
            UserDefaults.standard.set(addBos, forKey: "typofast.modelAddBos")
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

        enqueueCompletion(for: newText)

        let changeEnd = CFAbsoluteTimeGetCurrent()
        logEvent("timing.onTextChange", [
            "durationMs": String(format: "%.2f", (changeEnd - changeStart) * 1000.0),
            "textLength": "\(newText.count)"
        ])
    }

    private func enqueueCompletion(for text: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: debounceDelayNs)
            guard !Task.isCancelled else { return }
            guard currentText == text else { return }
            if text == lastRequestedInput { return }
            if hasValidSuggestion(for: text) { return }
            if lastEmptyCompletionInput == text { return }
            isGenerating = true
            lastRequestedInput = text
            let requestStart = CFAbsoluteTimeGetCurrent()
            inferenceTask?.cancel()
            inferenceTask = Task { @MainActor in
                let requestId = UUID()
                inFlightRequestId = requestId
                await requestCompletion(text, requestId: requestId)
            }
            await inferenceTask?.value
            let requestEnd = CFAbsoluteTimeGetCurrent()
            isGenerating = false
            logEvent("timing.requestCompletion", [
                "durationMs": String(format: "%.2f", (requestEnd - requestStart) * 1000.0),
                "textLength": "\(text.count)"
            ])
        }
    }

    private func enqueueCompletionAfterAccept(for text: String) {
        guard engine != nil else { return }
        let currentLine = currentInlineInput(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentLine.isEmpty else { return }

        lastRequestedInput = ""
        lastEmptyCompletionInput = nil
        logEvent("completionAfterAccept", ["textLength": "\(text.count)"])
        enqueueCompletion(for: text)
    }

    private func requestCompletion(_ text: String, requestId: UUID) async {
        guard let engine = engine else { return }

        // Feed the raw text up to the caret (including the partial word being typed) so the
        // base model continues exactly from the cursor. This is what makes in-word completion
        // work: typing "thi" yields a continuation like "nk it's", not a misaligned next word.
        var contextPrefix = ""
        if ocrContextEnabled,
           let context = windowContext,
           let filteredContext = filteredWindowContext(context, inputText: trimTrailingSpaces(text)),
           !filteredContext.text.isEmpty {
            contextPrefix = filteredContext.clippedText(maxLength: 600)
            logEvent("contextUsed", [
                "source": filteredContext.source.rawValue,
                "len": "\(filteredContext.text.count)",
                "title": filteredContext.windowTitle ?? ""
            ])
        }
        let modelPrompt = buildCompletionPrompt(text: text, contextPrefix: contextPrefix)
        logEvent("requestCompletion", [
            "text": text,
            "modelPrompt": modelPrompt
        ])
        let generationStart = CFAbsoluteTimeGetCurrent()
        let (completion, completionMetrics) = await engine.getCompletion(
            prompt: modelPrompt,
            maxWords: completionLength.wordCount
        )

        guard !Task.isCancelled else { return }
        guard inFlightRequestId == requestId else { return }

        guard currentText.hasPrefix(text) else {
            #if DEBUG
            print("[Typofast] discarding completion: text diverged from request prefix")
            #endif
            return
        }

        let typedSinceRequest = String(currentText.dropFirst(text.count))
        if !typedSinceRequest.isEmpty {
            let sanitizedPreview = sanitizeCompletion(completion, inputText: text)
            if sanitizedPreview.isEmpty || !sanitizedPreview.hasPrefix(typedSinceRequest) {
                #if DEBUG
                print("[Typofast] discarding completion: typed chars do not align with suggestion")
                #endif
                return
            }
        }

        let generationEnd = CFAbsoluteTimeGetCurrent()
        logEvent("timing.engineCompletion", [
            "durationMs": String(format: "%.2f", (generationEnd - generationStart) * 1000.0),
            "tokens": "\(completionMetrics.tokensGenerated)",
            "tps": String(format: "%.2f", completionMetrics.tokensPerSecond),
            "ttft": String(format: "%.2f", completionMetrics.ttft * 1000.0)
        ])

        let sanitizedCompletion = sanitizeCompletion(completion, inputText: text)

        // When the new continuation is empty, keep the suggestion that is already on screen instead
        // of clearing it. This gives the Cotypist-style feel where the user always has something to
        // accept; the stale suggestion is replaced as soon as a fresh, non-empty one arrives and is
        // realigned/cleared by the keep-suggestion logic in onTextChange as they keep typing.
        if sanitizedCompletion.isEmpty {
            lastEmptyCompletionInput = text
            logEvent("completionReceived", [
                "raw": completion,
                "sanitized": "",
                "kept": suggestion
            ])
            applyMetrics(completionMetrics)
            return
        }

        lastAppliedSuggestion = sanitizedCompletion
        lastEmptyCompletionInput = nil
        suggestionBase = sanitizedCompletion
        suggestionOffset = min(typedSinceRequest.count, sanitizedCompletion.count)
        suggestion = String(sanitizedCompletion.dropFirst(suggestionOffset))
        suggestionAnchor = currentText
        addSuggestedWords(from: sanitizedCompletion)
        logEvent("completionReceived", [
            "raw": completion,
            "sanitized": sanitizedCompletion
        ])
        logEvent("timing.suggestionApplied", [
            "suggestionLength": "\(sanitizedCompletion.count)"
        ])
        applyMetrics(completionMetrics)
    }

    private func stripHTMLTags(_ input: String) -> String {
        // Fast inline stripper – removes <tag> and </tag> patterns, decodes common entities
        var result = input
        while let range = result.range(of: "<[^>]+>", options: .regularExpression) {
            result.replaceSubrange(range, with: " ")
        }
        result = result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
        // Collapse whitespace runs created by tag removal
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildCompletionPrompt(text: String, contextPrefix: String) -> String {
        var prefix = ""
        let instructions = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            prefix += instructions + "\n\n"
        }
        if !contextPrefix.isEmpty {
            let cleanedContext = stripHTMLTags(contextPrefix)
            if !cleanedContext.isEmpty {
                prefix += cleanedContext.hasSuffix("\n") ? cleanedContext : cleanedContext + "\n"
            }
        }
        guard !prefix.isEmpty else { return text }
        return prefix + text
    }

    /// Turns the raw model continuation into ghost text that aligns with the caret.
    ///
    /// Leading whitespace is preserved as the natural word separator EXCEPT when the input
    /// already ends with a space (then it is dropped so the ghost glues after the existing
    /// space). This means:
    /// - mid-word + letter continuation  → glued in-word completion ("thi" + "nk it's")
    /// - mid-word + space continuation    → next-word suggestion     ("What" + " is the best")
    /// - after a space                    → next word, space trimmed  ("What " + "is the best")
    private func sanitizeCompletion(_ raw: String, inputText: String) -> String {
        guard !raw.isEmpty else { return "" }
        if raw.contains("<") || raw.contains(">") || raw.contains("**") { return "" }

        var cleaned = raw
        if let newline = cleaned.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            cleaned = String(cleaned[..<newline])
        }
        cleaned = String(cleaned.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        guard !cleaned.isEmpty else { return "" }

        let endsWithWhitespace = inputText.last?.isWhitespace ?? false
        let leadingSpace = !endsWithWhitespace && (cleaned.first == " " || cleaned.first == "\t")
        let body = trimLeadingWhitespace(cleaned)
        guard !body.isEmpty else { return "" }

        let words = body.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !words.isEmpty else { return "" }

        var limited = String(body)

        // Drop content-free continuations made only of punctuation/symbols ("-", "•", "​").
        let hasAlphanumeric = limited.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        guard hasAlphanumeric else { return "" }

        // Reject continuations that just echo the personalization back (the base model regenerates
        // the primed persona from its start when it has nothing better to continue).
        if echoesPersonalization(limited) { return "" }

        let inputLine = trimTrailingSpaces(currentInlineInput(from: inputText))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !inputLine.isEmpty, limited == inputLine { return "" }

        if leadingSpace {
            limited = " " + limited
        }
        return limited
    }

    private func echoesPersonalization(_ completion: String) -> Bool {
        let persona = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard persona.count >= 4 else { return false }
        let normalizedPersona = normalizeLine(persona)
        let normalizedCompletion = normalizeLine(completion)
        guard normalizedCompletion.count >= 3, !normalizedPersona.isEmpty else { return false }
        return normalizedPersona.hasPrefix(normalizedCompletion)
            || normalizedCompletion.hasPrefix(normalizedPersona)
    }

    private func trimLeadingWhitespace(_ text: String) -> String {
        var start = text.startIndex
        while start < text.endIndex, text[start].isWhitespace {
            start = text.index(after: start)
        }
        return String(text[start...])
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
                guard isUsefulContextLine(String(line)) else { return false }
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

    /// Drops OCR garbage lines (single short tokens like "sday"/"rday", lone symbols) that carry no
    /// usable context and only mislead the base model when the typed text is short.
    private func isUsefulContextLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 3 else { return false }
        let words = trimmed.split { $0.isWhitespace }
        return words.count >= 2 || trimmed.count >= 6
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

        if suggestion.isEmpty, suggestionBase.isEmpty {
            enqueueCompletionAfterAccept(for: newText)
        }
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
        let trimmed = trimTrailingSpaces(text)
        if trimmed.isEmpty { return false }

        // Never fire on a blank current line. With nothing to continue on this line the base model
        // falls back to regenerating the primed prefix (the personalization / surrounding context),
        // which is what produced the "I am Baptiste" echoes seen on empty Obsidian lines.
        let currentLine = currentInlineInput(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        if currentLine.isEmpty { return false }

        let wordCount = currentLine.split { $0.isWhitespace }.count
        if wordCount < minWordsToSuggest { return false }

        if text.last?.isWhitespace == true { return true }

        var activeWordLength = 0
        for ch in trimmed.reversed() {
            if ch.isWhitespace { break }
            activeWordLength += 1
        }
        return activeWordLength > 0
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
            await loadModel(path: localURL.path, addBos: managedModelAddBos)
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

    private func loadCompletionSettings() {
        if let raw = UserDefaults.standard.string(forKey: completionLengthKey),
           let value = CompletionLength(rawValue: raw) {
            completionLength = value
        }
        customInstructions = UserDefaults.standard.string(forKey: customInstructionsKey) ?? ""
        if UserDefaults.standard.object(forKey: minWordsToSuggestKey) == nil {
            minWordsToSuggest = 3
        } else {
            minWordsToSuggest = max(1, min(8, UserDefaults.standard.integer(forKey: minWordsToSuggestKey)))
        }
    }

    func setCompletionLength(_ length: CompletionLength) {
        completionLength = length
        UserDefaults.standard.set(length.rawValue, forKey: completionLengthKey)
    }

    func setCustomInstructions(_ text: String) {
        customInstructions = text
        UserDefaults.standard.set(text, forKey: customInstructionsKey)
    }

    func setMinWordsToSuggest(_ count: Int) {
        let clamped = max(1, min(8, count))
        minWordsToSuggest = clamped
        UserDefaults.standard.set(clamped, forKey: minWordsToSuggestKey)
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
            PermissionsBanner()
                .frame(width: contentWidth)

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

            // Row 4: Customization
            tileView {
                CustomizationView(appState: appState)
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
