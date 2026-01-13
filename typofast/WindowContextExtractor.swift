import AppKit
import Foundation
import Vision
import ScreenCaptureKit

final class WindowContextExtractor {
    private let maxTokens = 200
    private let textProcessor = OCRTextProcessor()

    func extract(frontmostApp: NSRunningApplication?,
                 allowOCR: Bool,
                 caretRegion: CGRect? = nil,
                 elementFrame: CGRect? = nil,
                 excludeTextLine: String? = nil) async -> WindowTextContext? {
        guard let app = frontmostApp else { return nil }
        let bundleId = app.bundleIdentifier
        let appName = app.localizedName ?? bundleId ?? "Unknown"

        guard allowOCR else { return nil }
        guard let ocrCapture = await captureRegionImage(for: app, caretRegion: caretRegion, elementFrame: elementFrame) else { return nil }
        #if DEBUG
        if let exclusion = ocrCapture.exclusionRect {
            print("[Typofast] ocr capture size=\(ocrCapture.image.width)x\(ocrCapture.image.height) exclusion=\(exclusion)")
        } else {
            print("[Typofast] ocr capture size=\(ocrCapture.image.width)x\(ocrCapture.image.height) exclusion=nil")
        }
        #endif
        let ocrText = recognizeText(
            in: ocrCapture.image,
            excluding: ocrCapture.exclusionRect,
            excludeTextLine: excludeTextLine,
            caretLineYInCrop: ocrCapture.caretLineYInCrop,
            caretBandHeight: ocrCapture.caretBandHeight
        )
        guard !ocrText.isEmpty else { return nil }

        let resolvedTitle = ocrCapture.title
        return WindowTextContext(
            appName: appName,
            bundleId: bundleId,
            windowTitle: resolvedTitle,
            source: .ocr,
            text: trimFromEnd(ocrText),
            capturedAt: Date()
        )
    }

    private func recognizeText(in image: CGImage,
                               excluding exclusionRect: CGRect?,
                               excludeTextLine: String?,
                               caretLineYInCrop: CGFloat?,
                               caretBandHeight: CGFloat?) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "fr-FR"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        guard let observations = request.results as? [VNRecognizedTextObservation] else { return "" }
        let lines = observations.compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            if let exclusionRect, observationOverlapsExclusion(observation.boundingBox, image: image, exclusionRect: exclusionRect) {
                #if DEBUG
                print("[Typofast] ocr drop bbox overlap text=\"\(candidate.string)\"")
                #endif
                return nil
            }
            if let caretLineYInCrop, let caretBandHeight,
               observationInCaretBand(observation.boundingBox, image: image, caretLineYInCrop: caretLineYInCrop, caretBandHeight: caretBandHeight) {
                #if DEBUG
                print("[Typofast] ocr drop caret band text=\"\(candidate.string)\"")
                #endif
                return nil
            }
            if shouldExcludeText(candidate.string, excludeTextLine: excludeTextLine) {
                #if DEBUG
                print("[Typofast] ocr drop line match text=\"\(candidate.string)\"")
                #endif
                return nil
            }
            return OCRLine(text: candidate.string, confidence: candidate.confidence, bbox: observation.boundingBox)
        }
        let processed = textProcessor.process(lines)
        return processed.joined(separator: "\n")
    }

    private func observationOverlapsExclusion(_ bbox: CGRect, image: CGImage, exclusionRect: CGRect) -> Bool {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let rect = CGRect(
            x: bbox.minX * imageWidth,
            y: (1.0 - bbox.maxY) * imageHeight,
            width: bbox.width * imageWidth,
            height: bbox.height * imageHeight
        )
        return rect.intersects(exclusionRect)
    }

    private func observationInCaretBand(_ bbox: CGRect, image: CGImage, caretLineYInCrop: CGFloat, caretBandHeight: CGFloat) -> Bool {
        let imageHeight = CGFloat(image.height)
        let rectY = (1.0 - bbox.maxY) * imageHeight
        let rectHeight = bbox.height * imageHeight
        let centerY = rectY + (rectHeight / 2)
        let halfBand = caretBandHeight / 2
        return centerY >= (caretLineYInCrop - halfBand) && centerY <= (caretLineYInCrop + halfBand)
    }

    private func shouldExcludeText(_ text: String, excludeTextLine: String?) -> Bool {
        guard let excludeTextLine else { return false }
        let normalizedLine = normalizeForExclusion(excludeTextLine)
        let normalizedText = normalizeForExclusion(text)
        guard normalizedLine.count >= 6, normalizedText.count >= 4 else { return false }
        if normalizedLine.contains(normalizedText) || normalizedText.contains(normalizedLine) {
            return true
        }
        let prefixLength = min(24, normalizedLine.count)
        if prefixLength >= 8 {
            let prefix = String(normalizedLine.prefix(prefixLength))
            if normalizedText.contains(prefix) {
                return true
            }
        }
        return false
    }

    private func normalizeForExclusion(_ text: String) -> String {
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

    func frontmostWindowIdentity(for app: NSRunningApplication) async -> WindowIdentity? {
        guard #available(macOS 14.0, *) else { return nil }
        guard let window = await frontmostWindow(for: app) else { return nil }
        return WindowIdentity(windowId: window.windowID, title: window.title)
    }

    private func captureRegionImage(for app: NSRunningApplication, caretRegion: CGRect?, elementFrame: CGRect?) async -> WindowCaptureResult? {
        guard #available(macOS 14.0, *) else { return nil }
        do {
            guard let window = await frontmostWindow(for: app) else { return nil }

            guard let caretRegion = caretRegion else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.queueDepth = 1

            let fullImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            
            let windowFrame = window.frame
            let imageHeight = CGFloat(fullImage.height)
            let imageWidth = CGFloat(fullImage.width)
            
            let scaleX = imageWidth / windowFrame.width
            let scaleY = imageHeight / windowFrame.height
            
            var elementFrameInWindow: CGRect?
            if let elementFrame = elementFrame {
                let candidate = CGRect(
                    x: elementFrame.origin.x - windowFrame.origin.x,
                    y: elementFrame.origin.y - windowFrame.origin.y,
                    width: elementFrame.width,
                    height: elementFrame.height
                )
                if candidate.width > 1, candidate.height > 1 {
                    elementFrameInWindow = candidate
                }
            }

            let caretXInWindow = caretRegion.midX - windowFrame.origin.x
            let caretYInWindow = caretRegion.midY - windowFrame.origin.y
            let caretYInWindowFromTop = windowFrame.height - caretYInWindow
            let caretCenterXInImage = caretXInWindow * scaleX
            let caretCenterYInImage = caretYInWindowFromTop * scaleY

            let gap: CGFloat = 24 * scaleY
            let minHeight: CGFloat = 120 * scaleY
            let maxHeightAbove: CGFloat = 420 * scaleY
            let maxHeightBelow: CGFloat = 320 * scaleY

            let regionTop: CGFloat
            let regionBottom: CGFloat
            let availableAbove = max(0, caretCenterYInImage - gap)
            let availableBelow = max(0, imageHeight - (caretCenterYInImage + gap))
            let captureAboveHeight = min(maxHeightAbove, availableAbove)
            let captureBelowHeight = min(maxHeightBelow, availableBelow)
            let useAbove = captureAboveHeight >= minHeight || captureBelowHeight < minHeight
            if useAbove, captureAboveHeight >= minHeight {
                regionTop = max(0, caretCenterYInImage - gap - captureAboveHeight)
                regionBottom = max(regionTop, caretCenterYInImage - gap)
            } else if captureBelowHeight >= minHeight {
                regionTop = min(imageHeight, caretCenterYInImage + gap)
                regionBottom = min(imageHeight, regionTop + captureBelowHeight)
            } else {
                return nil
            }

            let centerXInImage = caretCenterXInImage

            let referenceWidth = elementFrameInWindow?.width ?? (windowFrame.width * 0.45)
            let elementWidthInImage = referenceWidth * scaleX
            let horizontalPadding: CGFloat = max(160 * scaleX, elementWidthInImage * 0.2)
            let maxCaptureWidth: CGFloat = min(imageWidth, 980 * scaleX)
            let targetWidth = min(maxCaptureWidth, elementWidthInImage + (horizontalPadding * 2))
            let regionLeft = max(0, min(imageWidth - targetWidth, centerXInImage - targetWidth / 2))
            let regionRight = min(imageWidth, regionLeft + targetWidth)
            
            let captureRegion = CGRect(
                x: regionLeft,
                y: regionTop,
                width: regionRight - regionLeft,
                height: regionBottom - regionTop
            )
            
            guard captureRegion.width > 50 && captureRegion.height > 50,
                  captureRegion.maxX <= imageWidth,
                  captureRegion.maxY <= imageHeight,
                  captureRegion.origin.x >= 0,
                  captureRegion.origin.y >= 0,
                  let croppedImage = fullImage.cropping(to: captureRegion) else {
                return nil
            }

            let caretBandHeight = max(120 * scaleY, (caretRegion.height * scaleY) * 8)
            let caretLineYInCrop = caretCenterYInImage - captureRegion.minY

            let exclusionRect = computeExclusionRect(
                windowFrame: windowFrame,
                elementFrameInWindow: elementFrameInWindow,
                caretRegion: caretRegion,
                captureRegion: captureRegion,
                scaleX: scaleX,
                scaleY: scaleY,
                imageHeight: imageHeight
            )
            #if DEBUG
            if let elementFrameInWindow {
                print("[Typofast] ocr elementFrameInWindow=\(elementFrameInWindow)")
            } else {
                print("[Typofast] ocr elementFrameInWindow=nil")
            }
            print("[Typofast] ocr caretRegion=\(caretRegion)")
            print("[Typofast] ocr captureRegion=\(captureRegion)")
            #endif

            return WindowCaptureResult(
                image: croppedImage,
                title: window.title,
                exclusionRect: exclusionRect,
                caretLineYInCrop: caretLineYInCrop,
                caretBandHeight: caretBandHeight
            )
        } catch {
            return nil
        }
    }

    private func computeExclusionRect(windowFrame: CGRect,
                                      elementFrameInWindow: CGRect?,
                                      caretRegion: CGRect?,
                                      captureRegion: CGRect,
                                      scaleX: CGFloat,
                                      scaleY: CGFloat,
                                      imageHeight: CGFloat) -> CGRect? {
        var exclusionRects: [CGRect] = []
        let paddingX: CGFloat = 8 * scaleX
        let paddingY: CGFloat = 8 * scaleY

        if let elementFrameInWindow = elementFrameInWindow {
            let elementTopFromTop = windowFrame.height - (elementFrameInWindow.origin.y + elementFrameInWindow.height)
            let elementRectImage = CGRect(
                x: elementFrameInWindow.origin.x * scaleX - paddingX,
                y: elementTopFromTop * scaleY - paddingY,
                width: elementFrameInWindow.width * scaleX + (paddingX * 2),
                height: elementFrameInWindow.height * scaleY + (paddingY * 2)
            )
            exclusionRects.append(elementRectImage)
        }

        if let caretRegion = caretRegion {
            let caretYInWindowFromTop = windowFrame.height - (caretRegion.origin.y - windowFrame.origin.y)
            let caretYInImage = caretYInWindowFromTop * scaleY
            let caretBandHeight = max(36 * scaleY, (caretRegion.height * scaleY) * 4)
            let bandTop = max(0, caretYInImage - (caretBandHeight / 2))
            let caretBandRect = CGRect(
                x: captureRegion.minX,
                y: bandTop,
                width: captureRegion.width,
                height: min(caretBandHeight, imageHeight - bandTop)
            )
            exclusionRects.append(caretBandRect)
        }

        guard !exclusionRects.isEmpty else { return nil }

        let combined = exclusionRects.reduce(exclusionRects[0]) { $0.union($1) }
        let inCrop = combined.offsetBy(dx: -captureRegion.minX, dy: -captureRegion.minY)
        let cropBounds = CGRect(origin: .zero, size: CGSize(width: captureRegion.width, height: captureRegion.height))
        return inCrop.intersection(cropBounds)
    }

    @available(macOS 14.0, *)
    private func frontmostWindow(for app: NSRunningApplication) async -> SCWindow? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows.filter { window in
                guard let owner = window.owningApplication else { return false }
                return owner.processID == app.processIdentifier
            }
            guard !windows.isEmpty else { return nil }
            let sorted = windows.sorted { lhs, rhs in
                let lhsArea = lhs.frame.width * lhs.frame.height
                let rhsArea = rhs.frame.width * rhs.frame.height
                return lhsArea > rhsArea
            }
            return sorted.first
        } catch {
            return nil
        }
    }

    private func trimFromEnd(_ text: String) -> String {
        let tokens = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard tokens.count > maxTokens else { return text }
        return tokens.suffix(maxTokens).joined(separator: " ")
    }
}

struct WindowIdentity {
    let windowId: CGWindowID
    let title: String?
}

private struct WindowCaptureResult {
    let image: CGImage
    let title: String?
    let exclusionRect: CGRect?
    let caretLineYInCrop: CGFloat?
    let caretBandHeight: CGFloat?
}
