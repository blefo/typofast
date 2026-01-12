import CoreGraphics
import Foundation

struct OCRLine {
    let text: String
    let confidence: Float
    let bbox: CGRect
}

final class OCRTextProcessor {
    private let minConfidence: Float = 0.45
    private let rowTolerance: CGFloat = 0.02
    private let edgeSingleWordBand: CGFloat = 0.08
    
    private let chromeWords: Set<String> = [
        "file", "edit", "view", "window", "help", "search", "preferences", "settings",
        "tab", "reload", "back", "forward"
    ]
    
    func process(_ rawLines: [OCRLine]) -> [String] {
        var filtered: [OCRLine] = []
        filtered.reserveCapacity(rawLines.count)
        
        for line in rawLines {
            let cleaned = preprocessLine(line.text)
            guard !cleaned.isEmpty else { continue }
            guard line.confidence >= minConfidence else { continue }
            guard !isMostlyGarbage(cleaned) else { continue }
            guard !looksLikeChrome(cleaned) else { continue }
            guard !isEdgeSingleWord(cleaned, bbox: line.bbox) else { continue }
            filtered.append(OCRLine(text: cleaned, confidence: line.confidence, bbox: line.bbox))
        }
        
        let ordered = sortReadingOrder(filtered)
        let merged = mergeLines(ordered.map { $0.text })
        return dedupe(merged)
    }
    
    private func preprocessLine(_ line: String) -> String {
        return line.replacingOccurrences(of: "•", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func isMostlyGarbage(_ line: String) -> Bool {
        if line.count <= 2 { return true }
        if matchesLogPrefix(line) { return true }
        if isLowLetterRatio(line) { return true }
        if matchesSymbolOnly(line) { return true }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return letters < max(2, trimmed.count / 6)
    }
    
    private func matchesLogPrefix(_ line: String) -> Bool {
        let prefixes = [
            "[Typofast]",
            "requestCompletion",
            "modelPrompt=",
            "User context:",
            "Window context",
            "App:",
            "Window:",
            "Visible text:"
        ]
        return prefixes.contains { line.hasPrefix($0) }
    }
    
    private func isLowLetterRatio(_ line: String) -> Bool {
        var letters = 0
        var alnum = 0
        for scalar in line.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letters += 1
            }
            if CharacterSet.alphanumerics.contains(scalar) {
                alnum += 1
            }
        }
        let denom = max(1, alnum)
        return Double(letters) / Double(denom) < 0.25
    }
    
    private func matchesSymbolOnly(_ line: String) -> Bool {
        let symbols = CharacterSet(charactersIn: "•-+=()[]{}©®™|\\\\/*_.,:;\"'~…")
        var symbolCount = 0
        for scalar in line.unicodeScalars {
            if symbols.contains(scalar) {
                symbolCount += 1
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            } else {
                return false
            }
        }
        return symbolCount >= 3
    }

    private func looksLikeChrome(_ line: String) -> Bool {
        let words = line.lowercased().split(whereSeparator: { !$0.isLetter })
        guard !words.isEmpty else { return true }
        let hits = words.filter { chromeWords.contains(String($0)) }.count
        return hits >= max(1, words.count * 2 / 3)
    }
    
    private func isEdgeSingleWord(_ line: String, bbox: CGRect) -> Bool {
        let words = line.split(whereSeparator: { $0.isWhitespace })
        guard words.count == 1 else { return false }
        let y = bbox.midY
        return y < edgeSingleWordBand || y > (1.0 - edgeSingleWordBand)
    }
    
    private func sortReadingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        let sorted = lines.sorted { $0.bbox.midY > $1.bbox.midY }
        var rows: [[OCRLine]] = []
        for line in sorted {
            if let index = rows.firstIndex(where: { abs($0.first!.bbox.midY - line.bbox.midY) < rowTolerance }) {
                rows[index].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows
            .map { $0.sorted { $0.bbox.minX < $1.bbox.minX } }
            .flatMap { $0 }
    }
    
    private func mergeLines(_ lines: [String]) -> [String] {
        var output: [String] = []
        var i = 0
        
        while i < lines.count {
            var current = lines[i].trimmingCharacters(in: .whitespaces)
            if current.isEmpty {
                i += 1
                continue
            }
            
            while i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if next.isEmpty {
                    i += 1
                    continue
                }
                
                if isBullet(current) || isBullet(next) || isCodey(current) || isCodey(next) {
                    break
                }
                
                if current.hasSuffix("-"), next.first?.isLetter == true {
                    current.removeLast()
                    current += next
                    i += 1
                    continue
                }
                
                let endsWithPunct = current.range(of: #"[\.!\?:;…]$"#, options: .regularExpression) != nil
                let nextStartsLower = next.first?.isLowercase == true
                
                if !endsWithPunct && nextStartsLower {
                    current += " " + next
                    i += 1
                    continue
                }
                
                if current.hasSuffix(",") {
                    current += " " + next
                    i += 1
                    continue
                }
                
                break
            }
            
            output.append(normalizeWhitespace(current))
            i += 1
        }
        
        return output
    }
    
    private func isBullet(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("•") || trimmed.hasPrefix("* ") { return true }
        return trimmed.range(of: #"^\d+[\).\]]\s"#, options: .regularExpression) != nil
    }
    
    private func isCodey(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return true }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("}") { return true }
        if trimmed.hasPrefix("func ") || trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") { return true }
        if trimmed.hasPrefix("if ") || trimmed.hasPrefix("for ") || trimmed.hasPrefix("while ") { return true }
        if trimmed.hasPrefix("class ") || trimmed.hasPrefix("struct ") || trimmed.hasPrefix("enum ") { return true }
        if trimmed.hasPrefix("import ") { return true }
        let symbols = trimmed.filter { "{}[]();<>_=|".contains($0) }.count
        return symbols >= max(3, trimmed.count / 8)
    }
    
    private func normalizeWhitespace(_ line: String) -> String {
        var value = line.replacingOccurrences(of: "’", with: "'")
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #" \\,"#, with: ",", options: .regularExpression)
        value = value.replacingOccurrences(of: #" \."#, with: ".", options: .regularExpression)
        value = value.replacingOccurrences(of: #" \:"#, with: ":", options: .regularExpression)
        value = value.replacingOccurrences(of: #" \;"#, with: ";", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func dedupe(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var seenList: [String] = []
        var output: [String] = []
        output.reserveCapacity(lines.count)
        
        for line in lines {
            let key = normalizedKey(line)
            if key.count < 3 { continue }
            if seen.contains(key) { continue }
            if isNearDuplicate(key, seenList: seenList) { continue }
            seen.insert(key)
            seenList.append(key)
            output.append(line)
        }
        
        return output
    }
    
    private func normalizedKey(_ line: String) -> String {
        let lower = line.lowercased()
        let stripped = lower.replacingOccurrences(of: #"[^a-z0-9\s]"#, with: "", options: .regularExpression)
        let collapsed = stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespaces)
    }
    
    private func isNearDuplicate(_ key: String, seenList: [String]) -> Bool {
        for seen in seenList {
            if seen.contains(key) || key.contains(seen) {
                let maxLen = max(seen.count, key.count)
                let minLen = min(seen.count, key.count)
                if maxLen > 0 && Double(minLen) / Double(maxLen) >= 0.85 {
                    return true
                }
            }
        }
        return false
    }
}
