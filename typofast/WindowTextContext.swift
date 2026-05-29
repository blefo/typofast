import Foundation

enum WindowContextSource: String {
    case accessibility
    case ocr
}

struct WindowTextContext {
    let appName: String
    let bundleId: String?
    let windowTitle: String?
    let source: WindowContextSource
    let text: String
    let capturedAt: Date

    func isFresh(maxAge: TimeInterval) -> Bool {
        Date().timeIntervalSince(capturedAt) <= maxAge
    }

    func clippedText(maxLength: Int) -> String {
        WindowTextContext.trim(text, maxLength: maxLength)
    }

    private static func trim(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let end = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<end])
    }
}
