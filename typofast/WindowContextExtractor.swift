import AppKit
import Foundation
import Vision
import ScreenCaptureKit

final class WindowContextExtractor {
    private let maxTokens = 200
    private let textProcessor = OCRTextProcessor()

    func extract(frontmostApp: NSRunningApplication?,
                 allowOCR: Bool,
                 caretRegion: CGRect? = nil) async -> WindowTextContext? {
        guard let app = frontmostApp else { return nil }
        let bundleId = app.bundleIdentifier
        let appName = app.localizedName ?? bundleId ?? "Unknown"

        guard allowOCR else { return nil }
        guard let ocrCapture = await captureRegionImage(for: app, region: caretRegion) else { return nil }
        let ocrText = recognizeText(in: ocrCapture.image)
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

    private func recognizeText(in image: CGImage) -> String {
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
            return OCRLine(text: candidate.string, confidence: candidate.confidence, bbox: observation.boundingBox)
        }
        let processed = textProcessor.process(lines)
        return processed.joined(separator: "\n")
    }

    func frontmostWindowIdentity(for app: NSRunningApplication) async -> WindowIdentity? {
        guard #available(macOS 14.0, *) else { return nil }
        guard let window = await frontmostWindow(for: app) else { return nil }
        return WindowIdentity(windowId: window.windowID, title: window.title)
    }

    private func captureRegionImage(for app: NSRunningApplication, region: CGRect?) async -> WindowCaptureResult? {
        guard #available(macOS 14.0, *) else { return nil }
        do {
            guard let window = await frontmostWindow(for: app) else { return nil }

            guard let region = region else {
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
            
            let caretYInScreen = region.origin.y
            let caretXInScreen = region.origin.x
            
            let caretYInWindow = caretYInScreen - windowFrame.origin.y
            let caretXInWindow = caretXInScreen - windowFrame.origin.x
            
            let caretYInWindowFromTop = windowFrame.height - caretYInWindow
            let caretYInImage = caretYInWindowFromTop * scaleY
            let caretXInImage = caretXInWindow * scaleX
            
            let captureHeightAbove: CGFloat = 400 * scaleY
            let captureHeightBelow: CGFloat = 200 * scaleY
            let horizontalPadding: CGFloat = 400 * scaleX
            
            let regionTop = max(0, caretYInImage - captureHeightAbove)
            let regionBottom = min(imageHeight, caretYInImage + captureHeightBelow)
            let regionLeft = max(0, caretXInImage - horizontalPadding)
            let regionRight = min(imageWidth, caretXInImage + horizontalPadding)
            
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
            
            return WindowCaptureResult(image: croppedImage, title: window.title)
        } catch {
            return nil
        }
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
}
