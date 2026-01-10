import AppKit
import InputMethodKit

final class TypofastInputController: IMKInputController {
    private var currentText = ""
    private var lastText = ""
    private var suggestion = ""
    private var suggestionBase = ""
    private var suggestionOffset = 0
    private var lastAcceptedText = ""
    private var pendingTask: Task<Void, Never>?
    private var isAccepting = false
    private var syncTask: Task<Void, Never>?

    private let grayColor = NSColor.secondaryLabelColor

    override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int) -> Bool {
        guard let string else { return false }

        if string.isEmpty {
            return false
        }

        if isAccepting {
            return false
        }

        scheduleSync()
        return false
    }

    override func handleEvent(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }

        if event.type == .keyDown {
            switch event.keyCode {
            case 48: // tab
                if acceptSuggestion(firstWordOnly: true) { return true }
            case 53: // escape
                clearSuggestion()
                return true
            case 51: // delete
                if handleDelete() { return true }
            default:
                break
            }

            if (event.characters == "@" || event.characters == "`"), !suggestion.isEmpty {
                if acceptSuggestion(firstWordOnly: false) { return true }
            }
        }

        return false
    }

    override func commitComposition(_ sender: Any!) {
        clearSuggestion()
        super.commitComposition(sender)
    }

    // MARK: - Suggestion lifecycle

    private func updateSuggestion(_ suggestion: String) {
        guard let client = client() else { return }
        guard !suggestion.isEmpty else {
            client.unmarkText()
            return
        }

        let attr = NSAttributedString(string: suggestion, attributes: [.foregroundColor: grayColor])
        let selection = NSRange(location: 0, length: 0)
        client.setMarkedText(attr, selectionRange: selection, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func clearSuggestion() {
        suggestion = ""
        suggestionBase = ""
        suggestionOffset = 0
        if let client = client() {
            client.unmarkText()
        }
    }

    // MARK: - Acceptance

    private func acceptSuggestion(firstWordOnly: Bool) -> Bool {
        guard !suggestion.isEmpty else { return false }
        let accepted = firstWordOnly ? firstWordWithLeadingWhitespace(from: suggestion) : suggestion
        guard !accepted.isEmpty else { return false }

        clearSuggestion()
        isAccepting = true
        if let client = client() {
            client.insertText(accepted, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }
        lastAcceptedText = accepted
        scheduleSync()
        return true
    }

    private func handleDelete() -> Bool {
        if !lastAcceptedText.isEmpty {
            // Allow backspace to undo last accepted suggestion by clearing internal state.
            lastAcceptedText = ""
            clearSuggestion()
            scheduleSync()
            return false
        }

        scheduleSync()
        return false
    }

    // MARK: - Helpers

    private func shouldTriggerCompletion(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if text.last?.isWhitespace == true { return true }

        var length = 0
        for ch in text.reversed() {
            if ch.isWhitespace { break }
            length += 1
        }
        return length >= 2
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

    private func sanitizeSuggestion(_ suggestion: String, forPrompt prompt: String) -> String {
        guard !suggestion.isEmpty else { return "" }
        if prompt.last == " " || prompt.last == "\t" {
            return trimLeadingWhitespace(suggestion)
        }
        return suggestion
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
        if index == suggestion.endIndex { return "" }
        var end = index
        while end < suggestion.endIndex, !suggestion[end].isWhitespace {
            end = suggestion.index(after: end)
        }
        return String(suggestion[..<end])
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000)
            if let text = syncCurrentTextFromClient() {
                handleTextChange(newText: text)
            }
            isAccepting = false
        }
    }

    private func syncCurrentTextFromClient() -> String? {
        guard let client = client() else { return nil }
        let selection = client.selectedRange()
        guard selection.location != NSNotFound else { return nil }

        let marked = client.markedRange()
        var prefixLength = selection.location
        if marked.location != NSNotFound, marked.location < prefixLength {
            prefixLength = marked.location
        }

        if prefixLength < 0 {
            prefixLength = 0
        }

        var actual = NSRange(location: 0, length: 0)
        let proposed = NSRange(location: 0, length: prefixLength)
        if let attr = client.attributedSubstring(forProposedRange: proposed, actualRange: &actual) {
            return attr.string
        }

        return nil
    }

    // MARK: - Text change handling

    private func handleTextChange(newText: String) {
        if newText == lastText { return }

        let previousText = lastText
        if shouldKeepSuggestionOnTrailingWhitespace(previousText: previousText, newText: newText) {
            pendingTask?.cancel()
            currentText = newText
            lastText = newText
            updateSuggestion(suggestion)
            return
        }

        if shouldKeepSuggestionAlive(previousText: previousText, newText: newText) {
            pendingTask?.cancel()
            lastText = newText
            updateSuggestion(suggestion)
            return
        }

        currentText = newText
        lastText = newText
        pendingTask?.cancel()

        if newText.isEmpty {
            clearSuggestion()
            return
        }

        if !shouldTriggerCompletion(text: newText) {
            clearSuggestion()
            return
        }

        let modelPrompt = trimTrailingSpaces(newText)
        pendingTask = Task { @MainActor in
            let (completion, _) = await InputMethodEngine.shared.getSuggestion(prompt: modelPrompt, inputText: newText)
            guard newText == currentText else { return }
            let sanitized = sanitizeSuggestion(completion, forPrompt: newText)
            suggestionBase = sanitized
            suggestionOffset = 0
            suggestion = sanitized
            updateSuggestion(sanitized)
        }
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
}
