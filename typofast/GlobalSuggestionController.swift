import AppKit
import ApplicationServices
import Combine
import CursorBounds
import Security

@MainActor
final class GlobalSuggestionController: ObservableObject {
    @Published private(set) var accessibilityEnabled = false
    @Published private(set) var inputMonitoringEnabled = false
    @Published private(set) var screenRecordingEnabled = true
    @Published private(set) var focusedAppName = ""
    @Published private(set) var focusedAppBundleId: String?
    @Published private(set) var overlayMode: OverlayMode = .hidden

    private let appState: AppState
    private let overlay = SuggestionOverlayWindow()
    private let cursorBounds = CursorBounds()
    private let ownBundleId = Bundle.main.bundleIdentifier
    private var pollTimer: Timer?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var axObserver: AXObserver?
    private var axObserverSource: CFRunLoopSource?
    private var observedAppPid: pid_t?
    private var observedElement: AXUIElement?

    private var focusedContext: FocusedTextContext?
    private var lastObservedText = ""
    private var lastObservedRange = CFRange(location: 0, length: 0)
    private var lastAcceptedRange: CFRange?
    private var lastAcceptedText = ""
    private var suppressNextTextChange: String?
    private var keyBuffer: String = ""
    private var lastCursorPoint: CGPoint?
    private var lastCursorUpdateTime: CFAbsoluteTime = 0
    private var lastAXRefreshTime: CFAbsoluteTime = 0
    private var lastKeyRefreshTime: CFAbsoluteTime = 0
    private var lastTimerRefreshTime: CFAbsoluteTime = 0
    private var lastKeyBufferUpdateTime: CFAbsoluteTime = 0
    private var axRefreshScheduled = false
    private var lastOverlayText: String = ""
    private var lastOverlayCaret: CGPoint?
    private var lastOverlayFontKey: String = ""
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppState) {
        self.appState = appState

        appState.$suggestion
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.appState.suggestion.isEmpty {
                    self.updateOverlay()
                } else {
                    self.updateOverlay()
                }
            }
            .store(in: &cancellables)
    }

    func start() {
        accessibilityEnabled = CursorBounds.isAccessibilityEnabled()
        screenRecordingEnabled = Self.hasScreenRecordingPermission()
        logSandboxStatus()
        #if DEBUG
        print("[Typofast] accessibilityEnabled=\(accessibilityEnabled) screenRecordingEnabled=\(screenRecordingEnabled)")
        #endif
        startEventTapIfNeeded()
        startPolling()
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            updateAXObserver(for: pid)
            registerElementNotificationsIfNeeded()
        }
    }

    func requestAccessibilityPermission() {
        CursorBounds.requestAccessibilityPermissions()
        accessibilityEnabled = CursorBounds.isAccessibilityEnabled()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFocusedText(trigger: .timer)
            }
        }
    }

    private func startEventTapIfNeeded() {
        if eventTap != nil { return }

        // Listen for keyDown to accept/dismiss suggestions.
        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<GlobalSuggestionController>.fromOpaque(userInfo).takeUnretainedValue()
            return controller.handleEvent(type: type, event: event)
        }

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        guard let tap = tap else {
            inputMonitoringEnabled = false
            return
        }

        eventTap = tap
        inputMonitoringEnabled = true
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = eventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    @MainActor
    private func refreshFocusedText(trigger: RefreshTrigger) {
        if trigger == .timer,
           appState.suggestion.isEmpty,
           !appState.isGenerating {
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        if trigger == .ax {
            if now - lastAXRefreshTime < 0.05, !appState.isGenerating {
                return
            }
            lastAXRefreshTime = now
        } else if trigger == .key {
            if now - lastKeyRefreshTime < 0.02, !appState.isGenerating {
                return
            }
            lastKeyRefreshTime = now
        } else if trigger == .timer {
            let interval: CFAbsoluteTime = (appState.isGenerating || !appState.suggestion.isEmpty) ? 0.2 : 0.6
            if now - lastTimerRefreshTime < interval {
                return
            }
            lastTimerRefreshTime = now
        }
        let refreshStart = CFAbsoluteTimeGetCurrent()
        accessibilityEnabled = CursorBounds.isAccessibilityEnabled()
        screenRecordingEnabled = Self.hasScreenRecordingPermission()

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let newAppName = frontmostApp?.localizedName ?? ""
        if newAppName != focusedAppName {
            keyBuffer = ""
        }
        focusedAppName = newAppName
        let previousBundleId = focusedAppBundleId
        focusedAppBundleId = frontmostApp?.bundleIdentifier
        if previousBundleId != focusedAppBundleId {
            lastCursorPoint = nil
        }

        if let ownBundleId,
           focusedAppBundleId == ownBundleId {
            overlay.hide()
            overlayMode = .hidden
            focusedContext = nil
            return
        }

        if let pid = frontmostApp?.processIdentifier {
            updateAXObserver(for: pid)
        }

        if let bundleId = focusedAppBundleId, appState.isAppDisabled(bundleId: bundleId) {
            overlay.hide()
            overlayMode = .hidden
            focusedContext = nil
            appState.clearSuggestion()
            return
        }

        if !inputMonitoringEnabled {
            startEventTapIfNeeded()
        }
        guard accessibilityEnabled else {
            overlay.hide()
            overlayMode = .hidden
            return
        }

        let context = fetchFocusedTextContextSync()
        applyFocusedContext(context, trigger: trigger)
        let refreshEnd = CFAbsoluteTimeGetCurrent()
        #if DEBUG
        print("[Typofast] timing.refreshFocusedText trigger=\(trigger) durationMs=\(String(format: "%.2f", (refreshEnd - refreshStart) * 1000.0))")
        #endif
    }

    private func updateAXObserver(for pid: pid_t) {
        if observedAppPid == pid, axObserver != nil { return }
        teardownAXObserver()

        var observer: AXObserver?
        let error = AXObserverCreate(pid, { observer, element, notification, refcon in
            guard let refcon else { return }
            let controller = Unmanaged<GlobalSuggestionController>.fromOpaque(refcon).takeUnretainedValue()
            controller.handleAXNotification(observer: observer, element: element, notification: notification as String)
        }, &observer)

        guard error == .success, let observer else { return }
        axObserver = observer
        observedAppPid = pid

        let source = AXObserverGetRunLoopSource(observer)
        axObserverSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let appElement = AXUIElementCreateApplication(pid)
        _ = AXObserverAddNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        _ = AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        _ = AXObserverAddNotification(observer, appElement, kAXValueChangedNotification as CFString, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        registerElementNotificationsIfNeeded()
    }

    private func teardownAXObserver() {
        if let observer = axObserver, let element = observedElement {
            AXObserverRemoveNotification(observer, element, kAXSelectedTextChangedNotification as CFString)
            AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
        }
        if let observer = axObserver, let pid = observedAppPid {
            let appElement = AXUIElementCreateApplication(pid)
            AXObserverRemoveNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString)
            AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
            AXObserverRemoveNotification(observer, appElement, kAXValueChangedNotification as CFString)
        }
        if let source = axObserverSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        axObserverSource = nil
        axObserver = nil
        observedAppPid = nil
        observedElement = nil
    }

    private func handleAXNotification(observer: AXObserver, element: AXUIElement, notification: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if notification == kAXFocusedUIElementChangedNotification as String
                || notification == kAXFocusedWindowChangedNotification as String {
                self.registerElementNotificationsIfNeeded()
            }
            if !self.axRefreshScheduled {
                self.axRefreshScheduled = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.axRefreshScheduled = false
                    self.refreshFocusedText(trigger: .ax)
                }
            }
        }
    }

    private func registerElementNotificationsIfNeeded() {
        guard let observer = axObserver else { return }
        if let element = observedElement {
            AXObserverRemoveNotification(observer, element, kAXSelectedTextChangedNotification as CFString)
            AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
        }
        if let focusedAny = AccessibilityHelpers.focusedElement(),
           let resolvedAny = AccessibilityHelpers.resolveEditableElement(from: focusedAny),
           let axElement = AccessibilityHelpers.axElementIfAvailable(resolvedAny) {
            observedElement = axElement
            AXObserverAddNotification(observer, axElement, kAXSelectedTextChangedNotification as CFString, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
            AXObserverAddNotification(observer, axElement, kAXValueChangedNotification as CFString, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        }
    }

    private func applyFocusedContext(_ context: FocusedTextContext?, trigger: RefreshTrigger) {
        guard let context else {
            focusedContext = nil
            if !appState.suggestion.isEmpty {
                updateOverlay()
            }
            return
        }

        focusedContext = context

        let normalizedValue = context.value.map { normalizeObservedValue($0) }
        if trigger == .ax,
           let value = normalizedValue {
            let now = CFAbsoluteTimeGetCurrent()
            let current = appState.currentText
            if now - lastKeyBufferUpdateTime < 0.4,
               !keyBuffer.isEmpty,
               !value.hasPrefix(keyBuffer),
               !keyBuffer.hasPrefix(value) {
                return
            }
            if now - lastKeyRefreshTime < 0.25,
               !current.isEmpty,
               !value.hasPrefix(current),
               !current.hasPrefix(value) {
                return
            }
            if !current.isEmpty,
               !value.hasPrefix(current),
               !current.hasPrefix(value),
               current.hasSuffix(value),
               current.count - value.count <= 3 {
                return
            }
        }
        if trigger == .ax,
           let value = normalizedValue {
            let current = appState.currentText
            if !current.isEmpty,
               !value.hasPrefix(current),
               !current.hasPrefix(value),
               current.hasSuffix(value),
               current.count - value.count <= 3 {
                return
            }
        }
        if let value = normalizedValue,
           let suppressed = suppressNextTextChange,
           normalizeObservedValue(suppressed) == value {
            suppressNextTextChange = nil
            lastObservedText = value
            if let range = context.selectedRange {
                lastObservedRange = range
            }
            updateOverlay()
            return
        }

        let textChanged: Bool
        if let value = normalizedValue {
            textChanged = value != lastObservedText
        } else {
            textChanged = false
        }
        let rangeChanged: Bool
        if let range = context.selectedRange {
            rangeChanged = range.location != lastObservedRange.location
                || range.length != lastObservedRange.length
        } else {
            rangeChanged = false
        }

        if rangeChanged && !textChanged {
            if let range = context.selectedRange {
                lastObservedRange = range
                if range.length > 0 {
                    appState.clearSuggestion()
                }
            }
            updateOverlay()
            return
        }

        if textChanged || rangeChanged {
            if let value = normalizedValue {
                lastObservedText = value
            }
            if let range = context.selectedRange {
                lastObservedRange = range
            }
            lastAcceptedRange = nil
            lastAcceptedText = ""
            if let value = normalizedValue {
                appState.onTextChange(value, source: .ax)
            }
            if appState.suggestion.isEmpty {
                updateOverlay()
            } else {
                updateOverlay()
            }
        }
    }

    private func normalizeObservedValue(_ value: String) -> String {
        if value.hasSuffix("\r\n") {
            let trimmed = value.dropLast(2)
            if !trimmed.contains("\n") && !trimmed.contains("\r") {
                return String(trimmed)
            }
        }
        if value.hasSuffix("\n") || value.hasSuffix("\r") {
            let trimmed = value.dropLast()
            if !trimmed.contains("\n") && !trimmed.contains("\r") {
                return String(trimmed)
            }
        }
        return value
    }

    private func updateOverlay() {
        if appState.suggestion.isEmpty && overlayMode == .hidden {
            return
        }
        let overlayStart = CFAbsoluteTimeGetCurrent()
        tryUpdateOverlay(reason: "updateOverlay")
        let overlayEnd = CFAbsoluteTimeGetCurrent()
        #if DEBUG
        print("[Typofast] timing.updateOverlay durationMs=\(String(format: "%.2f", (overlayEnd - overlayStart) * 1000.0))")
        #endif
    }

    private func cursorPointWithGrace() -> CGPoint? {
        if let point = readCaretPoint() {
            return point
        }
        let now = CFAbsoluteTimeGetCurrent()
        if let lastCursorPoint, now - lastCursorUpdateTime < 0.4 {
            return lastCursorPoint
        }
        return nil
    }

    private func readCaretPoint() -> CGPoint? {
        let caretStart = CFAbsoluteTimeGetCurrent()
        if let caretRect = focusedContext?.caretRect {
            #if DEBUG
            let caretEnd = CFAbsoluteTimeGetCurrent()
            print("[Typofast] timing.readCaretPoint source=focusedContext durationMs=\(String(format: "%.2f", (caretEnd - caretStart) * 1000.0))")
            #endif
            return CGPoint(x: caretRect.maxX, y: caretRect.minY)
        }
        do {
            let position = try cursorBounds.cursorPosition(
                correctionMode: .none,
                corner: .bottomRight
            )
            #if DEBUG
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            print("[Typofast] cursorPosition type=\(position.type) point=\(position.point) bounds=\(position.bounds) frontmost=\(frontmost)")
            #endif
            guard position.type == CursorType.textCaret else {
                return nil
            }
            #if DEBUG
            print("[Typofast] resolvedCaretPoint=\(position.point) type=\(position.type)")
            #endif
            lastCursorPoint = position.point
            lastCursorUpdateTime = CFAbsoluteTimeGetCurrent()
            #if DEBUG
            let caretEnd = CFAbsoluteTimeGetCurrent()
            print("[Typofast] timing.readCaretPoint source=cursorBounds durationMs=\(String(format: "%.2f", (caretEnd - caretStart) * 1000.0))")
            #endif
            return position.point
        } catch {
            #if DEBUG
            print("[Typofast] cursorPosition error: \(error)")
            #endif
            return nil
        }
    }

    private func logSandboxStatus() {
        guard let task = SecTaskCreateFromSelf(nil) else {
            #if DEBUG
            print("[Typofast] appSandbox entitlement=unavailable")
            #endif
            return
        }
        let key = "com.apple.security.app-sandbox" as CFString
        if let value = SecTaskCopyValueForEntitlement(task, key, nil) {
            #if DEBUG
            print("[Typofast] appSandbox entitlement=\(value)")
            #endif
        } else {
            #if DEBUG
            print("[Typofast] appSandbox entitlement=missing")
            #endif
        }
    }

    private func tryUpdateOverlay(reason: String) {
        let updateStart = CFAbsoluteTimeGetCurrent()
        let suggestion = appState.suggestion
        guard !suggestion.isEmpty else {
            overlay.hide()
            overlayMode = .hidden
            lastOverlayText = ""
            lastOverlayCaret = nil
            lastOverlayFontKey = ""
            return
        }
        let effectiveFont = focusedContext?.font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let fontKey = "\(effectiveFont.fontName)-\(effectiveFont.pointSize)"

        guard let caretPoint = cursorPointWithGrace() else {
            #if DEBUG
            print("[Typofast] updateOverlay: no caret cursor available (reason=\(reason))")
            #endif
            return
        }

        if suggestion == lastOverlayText,
           fontKey == lastOverlayFontKey,
           let lastCaret = lastOverlayCaret,
           abs(lastCaret.x - caretPoint.x) < 0.5,
           abs(lastCaret.y - caretPoint.y) < 0.5 {
            #if DEBUG
            let updateEnd = CFAbsoluteTimeGetCurrent()
            print("[Typofast] timing.tryUpdateOverlay reason=\(reason) durationMs=\(String(format: "%.2f", (updateEnd - updateStart) * 1000.0))")
            #endif
            return
        }

        overlayMode = .inline
        overlay.update(text: suggestion, font: effectiveFont, color: .systemGray, origin: caretPoint)
        lastOverlayText = suggestion
        lastOverlayCaret = caretPoint
        lastOverlayFontKey = fontKey
        #if DEBUG
        let updateEnd = CFAbsoluteTimeGetCurrent()
        print("[Typofast] timing.tryUpdateOverlay reason=\(reason) durationMs=\(String(format: "%.2f", (updateEnd - updateStart) * 1000.0))")
        #endif
        return
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        if !accessibilityEnabled || !inputMonitoringEnabled {
            return Unmanaged.passUnretained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let characters = event.unicodeString ?? ""

        if keycode == 48 { // tab
            if acceptSuggestion(acceptAll: false) {
                return nil
            }
        }

        if characters == "@" || characters == "`" {
            if acceptSuggestion(acceptAll: true) {
                return nil
            }
        }

        if keycode == 53 {
            if !appState.suggestion.isEmpty {
                appState.clearSuggestion()
                overlay.hide()
                overlayMode = .hidden
                return nil
            }
        }

        if keycode == 51 {
            if deleteAcceptedSuggestion() {
                return nil
            }
        }

        if !characters.isEmpty {
            lastAcceptedRange = nil
            lastAcceptedText = ""
            updateKeyBuffer(with: characters, keycode: keycode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.refreshFocusedText(trigger: .key)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func acceptSuggestion(acceptAll: Bool) -> Bool {
        let accepted = appState.acceptedSuggestionText(firstWordOnly: !acceptAll)
        guard !accepted.isEmpty else { return false }

        // Use appState.currentText as source of truth to avoid stale context issues
        let currentText = appState.currentText
        let newText = currentText + accepted

        if let context = focusedContext {
            // Set the entire text field value to ensure consistency
            guard AXUIElementSetAttributeValue(context.element, kAXValueAttribute as CFString, newText as CFString) == .success else {
                // Fallback to injection if we can't set the value
                injectText(accepted)
                lastAcceptedText = accepted
                lastAcceptedRange = nil
                appState.applyAcceptedSuggestion(accepted: accepted, newText: newText, keepRemaining: !acceptAll)
                updateOverlay()
                return true
            }

            // Set cursor to end of new text
            let newLocation = (newText as NSString).length
            var newRange = CFRange(location: newLocation, length: 0)
            if let axRange = AXValueCreate(.cfRange, &newRange) {
                AXUIElementSetAttributeValue(context.element, kAXSelectedTextRangeAttribute as CFString, axRange)
            }

            // Track the accepted range for potential delete-undo
            let acceptedLocation = (currentText as NSString).length
            lastAcceptedRange = CFRange(location: acceptedLocation, length: (accepted as NSString).length)
            lastAcceptedText = accepted
            suppressNextTextChange = newText

            appState.applyAcceptedSuggestion(accepted: accepted, newText: newText, keepRemaining: !acceptAll)

            focusedContext = FocusedTextContext(
                element: context.element,
                value: newText,
                selectedRange: CFRange(location: newLocation, length: 0),
                caretRect: context.caretRect,
                elementFrame: context.elementFrame,
                font: context.font
            )
            updateOverlay()
            return true
        }

        // Fallback: inject typed characters when we cannot access AX element.
        injectText(accepted)
        keyBuffer = newText
        lastAcceptedText = accepted
        lastAcceptedRange = nil
        appState.applyAcceptedSuggestion(accepted: accepted, newText: newText, keepRemaining: !acceptAll)
        updateOverlay()
        return true
    }

    private func deleteAcceptedSuggestion() -> Bool {
        guard !lastAcceptedText.isEmpty else { return false }

        if let range = lastAcceptedRange, let context = focusedContext, let selection = context.selectedRange {
            let caretLocation = selection.location
            // Only delete if cursor is right after the accepted text
            guard selection.length == 0,
                  caretLocation == range.location + range.length else {
                lastAcceptedRange = nil
                lastAcceptedText = ""
                return false
            }

            // Compute new text by removing the accepted portion
            let currentText = appState.currentText
            let nsCurrentText = currentText as NSString
            let safeLocation = max(0, min(range.location, nsCurrentText.length))
            let safeLength = max(0, min(range.length, nsCurrentText.length - safeLocation))
            let safeRange = NSRange(location: safeLocation, length: safeLength)
            let newText = nsCurrentText.replacingCharacters(in: safeRange, with: "")

            // Set the text field to the new value
            guard AXUIElementSetAttributeValue(context.element, kAXValueAttribute as CFString, newText as CFString) == .success else {
                // Fallback to sending backspaces
                sendBackspaces(count: lastAcceptedText.count)
                appState.regenerateAfterDeletingAcceptedSuggestion(newText: newText)
                lastAcceptedRange = nil
                lastAcceptedText = ""
                return true
            }

            // Set cursor to the position before the deleted text
            var newRange = CFRange(location: safeLocation, length: 0)
            if let axRange = AXValueCreate(.cfRange, &newRange) {
                AXUIElementSetAttributeValue(context.element, kAXSelectedTextRangeAttribute as CFString, axRange)
            }

            suppressNextTextChange = newText
            appState.regenerateAfterDeletingAcceptedSuggestion(newText: newText)
            lastAcceptedRange = nil
            lastAcceptedText = ""
            updateOverlay()
            return true
        }

        // Fallback: delete last accepted text using backspaces
        sendBackspaces(count: lastAcceptedText.count)
        let currentText = appState.currentText
        let newText: String
        if currentText.hasSuffix(lastAcceptedText) {
            newText = String(currentText.dropLast(lastAcceptedText.count))
        } else {
            newText = currentText
        }
        appState.regenerateAfterDeletingAcceptedSuggestion(newText: newText)
        lastAcceptedRange = nil
        lastAcceptedText = ""
        return true
    }

    private func updateKeyBuffer(with characters: String, keycode: Int64) {
        // Ignore control characters except backspace.
        if keycode == 51 {
            if !keyBuffer.isEmpty {
                keyBuffer.removeLast()
            }
        } else {
            keyBuffer.append(characters)
        }
        lastKeyBufferUpdateTime = CFAbsoluteTimeGetCurrent()
        if focusedContext == nil {
            appState.onTextChange(keyBuffer, source: .key)
        }
    }

    private func injectText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for scalar in text.unicodeScalars {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            keyDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(scalar.value)])
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(scalar.value)])
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    private func sendBackspaces(count: Int) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for _ in 0..<count {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)
            keyDown?.post(tap: .cghidEventTap)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    private func replaceText(in context: FocusedTextContext, with text: String) -> String? {
        guard let range = context.selectedRange else { return nil }
        return replaceText(in: context, range: range, replacement: text)
    }

    private func replaceText(in context: FocusedTextContext, range: CFRange, replacement: String) -> String? {
        guard let value = context.value else { return nil }
        let nsValue = value as NSString
        let safeLocation = max(0, min(range.location, nsValue.length))
        let safeLength = max(0, min(range.length, nsValue.length - safeLocation))
        let safeRange = NSRange(location: safeLocation, length: safeLength)
        let newValue = nsValue.replacingCharacters(in: safeRange, with: replacement)

        guard AXUIElementSetAttributeValue(context.element, kAXValueAttribute as CFString, newValue as CFString) == .success else {
            return nil
        }

        let newLocation = safeLocation + (replacement as NSString).length
        var newRange = CFRange(location: newLocation, length: 0)
        if let axRange = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(context.element, kAXSelectedTextRangeAttribute as CFString, axRange)
        }

        return newValue
    }

    private func fetchFocusedTextContextSync() -> FocusedTextContext? {
        let systemWide = AXUIElementCreateSystemWide()

        if let focusedAny = AccessibilityHelpers.focusedElement(),
           let resolvedAny = AccessibilityHelpers.resolveEditableElement(from: focusedAny),
           let axElement = AccessibilityHelpers.axElementIfAvailable(resolvedAny) {
            if let context = buildContext(from: axElement) {
                #if DEBUG
                //print("[Typofast] fetchContext: found via AccessibilityHelpers, caretRect=\(String(describing: context.caretRect))")
                #endif
                return context
            }
        }

        guard let appElement = copyAXElement(systemWide, attribute: kAXFocusedApplicationAttribute as CFString)
            ?? copyFrontmostAppElement() else {
            #if DEBUG
            print("[Typofast] fetchContext: no app element")
            #endif
            return nil
        }

#if DEBUG
        if let focusedWindow = copyAXElement(appElement, attribute: kAXFocusedWindowAttribute as CFString) {
            var frameRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(focusedWindow, "AXFrame" as CFString, &frameRef) == .success,
               let frameRef,
               CFGetTypeID(frameRef) == AXValueGetTypeID() {
                var frame = CGRect.zero
                if AXValueGetValue(frameRef as! AXValue, .cgRect, &frame) {
                    print("[Typofast] focusedWindow frame=\(frame)")
                }
            }
        }
#endif

        if let focusedElement = copyAXElement(appElement, attribute: kAXFocusedUIElementAttribute as CFString),
           let directContext = buildContext(from: focusedElement) {
            #if DEBUG
            print("[Typofast] fetchContext: direct focusedElement, caretRect=\(String(describing: directContext.caretRect))")
            #endif
            return directContext
        }

        if let focusedElement = copyAXElement(appElement, attribute: kAXFocusedUIElementAttribute as CFString),
           let textElement = resolveTextElement(startingAt: focusedElement) {
            let context = buildContext(from: textElement)
            #if DEBUG
            if context != nil {
                //print("[Typofast] fetchContext: found via focusedElement, caretRect=\(String(describing: context?.caretRect))")
            }
            #endif
            return context
        }

        if let focusedElement = copyAXElement(appElement, attribute: kAXFocusedUIElementAttribute as CFString),
           let caretElement = findCaretElement(startingAt: focusedElement, maxDepth: 8),
           let context = buildContext(from: caretElement) {
            #if DEBUG
            //print("[Typofast] fetchContext: found via caretElement, caretRect=\(String(describing: context.caretRect))")
            #endif
            return context
        }

        if let focusedElement = copyAXElement(appElement, attribute: kAXFocusedUIElementAttribute as CFString),
           let fallbackContext = buildContext(from: focusedElement),
           fallbackContext.elementFrame != nil {
            #if DEBUG
            print("[Typofast] fetchContext: fallback to focusedElement frame, caretRect=\(String(describing: fallbackContext.caretRect))")
            #endif
            return fallbackContext
        }

        if let textElement = resolveTextElement(startingAt: appElement) {
            let context = buildContext(from: textElement)
            #if DEBUG
            //if context != nil {
            //    print("[Typofast] fetchContext: found via appElement search, caretRect=\(String(describing: context?.caretRect))")
            //}
            #endif
            return context
        }

        if let focusedWindow = copyAXElement(appElement, attribute: kAXFocusedWindowAttribute as CFString),
           let windowFrame = readElementFrame(from: focusedWindow) {
            #if DEBUG
            print("[Typofast] fetchContext: fallback to focusedWindow frame, frame=\(windowFrame)")
            #endif
            return FocusedTextContext(
                element: focusedWindow,
                value: nil,
                selectedRange: nil,
                caretRect: nil,
                elementFrame: bestScreenRect(forAXRect: windowFrame),
                font: nil
            )
        }

        #if DEBUG
        print("[Typofast] fetchContext: no text element found")
        #endif
        return nil
    }

    private func focusedWindowFrame() -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()
        if let focusedWindow = copyAXElement(systemWide, attribute: kAXFocusedWindowAttribute as CFString),
           let frame = readElementFrame(from: focusedWindow) {
            return bestScreenRect(forAXRect: frame)
        }
        if let focusedApp = copyAXElement(systemWide, attribute: kAXFocusedApplicationAttribute as CFString),
           let focusedWindow = copyAXElement(focusedApp, attribute: kAXFocusedWindowAttribute as CFString),
           let frame = readElementFrame(from: focusedWindow) {
            return bestScreenRect(forAXRect: frame)
        }
        if let fallback = frontmostWindowFrame() {
            return fallback
        }
        return nil
    }

    private func frontmostWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var bestRect: CGRect?
        var bestArea: CGFloat = 0

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else {
                continue
            }
            let isOnscreen = (info[kCGWindowIsOnscreen as String] as? Int ?? 0) == 1
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard isOnscreen, layer == 0 else { continue }

            guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = (bounds["X"] as? CGFloat) ?? 0
            let y = (bounds["Y"] as? CGFloat) ?? 0
            let w = (bounds["Width"] as? CGFloat) ?? 0
            let h = (bounds["Height"] as? CGFloat) ?? 0
            guard w > 0 && h > 0 else { continue }

            let area = w * h
            if area > bestArea {
                let quartzRect = CGRect(x: x, y: y, width: w, height: h)
                bestRect = convertQuartzRectToAppKit(quartzRect) ?? quartzRect
                bestArea = area
            }
        }

        if let bestRect {
            return bestRect
        }

        return nil
    }

    private func convertQuartzRectToAppKit(_ quartzRect: CGRect) -> CGRect? {
        let center = CGPoint(x: quartzRect.midX, y: quartzRect.midY)
        for screen in NSScreen.screens {
            guard let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            let displayBounds = CGDisplayBounds(displayId)
            if displayBounds.contains(center) {
                let appKitX = quartzRect.origin.x - displayBounds.origin.x + screen.frame.origin.x
                let appKitY = (displayBounds.origin.y + displayBounds.size.height) - (quartzRect.origin.y + quartzRect.size.height) + screen.frame.origin.y
                return CGRect(x: appKitX, y: appKitY, width: quartzRect.width, height: quartzRect.height)
            }
        }
        return nil
    }

    private func resolveTextElement(startingAt element: AXUIElement) -> AXUIElement? {
        if canResolveTextElement(element) {
            return element
        }

        if let focusedChild = copyAXElement(element, attribute: kAXFocusedUIElementAttribute as CFString),
           canResolveTextElement(focusedChild) {
            return focusedChild
        }

        if let caretElement = findCaretElement(startingAt: element, maxDepth: 8) {
            return caretElement
        }

        if let parentMatch = findEditableAncestor(startingAt: element, maxDepth: 8) {
            return parentMatch
        }

        return findTextElement(in: element, maxDepth: 6, maxNodes: 300)
    }

    private func findCaretElement(startingAt element: AXUIElement, maxDepth: Int) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < maxDepth {
            if let range = readSelectedRange(from: node),
               boundsForRange(CFRange(location: range.location, length: 0), element: node) != nil {
                return node
            }
            current = copyAXElement(node, attribute: kAXParentAttribute as CFString)
            depth += 1
        }
        return nil
    }

    private func findEditableAncestor(startingAt element: AXUIElement, maxDepth: Int) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < maxDepth {
            if canResolveTextElement(node) {
                return node
            }
            current = copyAXElement(node, attribute: kAXParentAttribute as CFString)
            depth += 1
        }
        return nil
    }

    private func canResolveTextElement(_ element: AXUIElement) -> Bool {
        let role = readRole(from: element)
        let editable = readEditable(from: element) ?? false
        let allowedRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            "AXSearchField",
            kAXComboBoxRole as String,
            "AXRichTextArea",
            "AXWebArea",
            "AXGroup",
            "AXLayoutArea",
            "AXScrollArea"
        ]
        let roleOK = role.map { allowedRoles.contains($0) } ?? false

        let hasSelection = readSelectedRange(from: element) != nil
        let hasValue = readValue(from: element) != nil
        let hasFrame = readElementFrame(from: element) != nil

        if hasSelection {
            return true
        }
        return editable || (roleOK && (hasValue || hasFrame))
    }

    private func buildContext(from element: AXUIElement) -> FocusedTextContext? {
        let range = readSelectedRange(from: element)
        let value = readValue(from: element)
        let caretRect: CGRect? = range.flatMap { r in
            self.caretRect(for: element, range: r).map { rect in
                self.bestScreenRect(forAXRect: rect)
            }
        }
        let elementFrame: CGRect? = readElementFrame(from: element).map { self.bestScreenRect(forAXRect: $0) }
        if range == nil && value == nil && elementFrame == nil {
            return nil
        }
#if DEBUG
        let role = readRole(from: element) ?? "nil"
        let editable = readEditable(from: element).map { $0 ? "true" : "false" } ?? "nil"
        let hasSelection = range != nil ? "true" : "false"
#endif
        let font = readFont(from: element, value: value, range: range)
        return FocusedTextContext(
            element: element,
            value: value,
            selectedRange: range,
            caretRect: caretRect,
            elementFrame: elementFrame,
            font: font
        )
    }

    private func readValue(from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let valueRef else {
            return nil
        }

        if let stringValue = valueRef as? String {
            return stringValue
        }
        if let attributedValue = valueRef as? NSAttributedString {
            return attributedValue.string
        }
        return nil
    }

    private func readSelectedRange(from element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef,
           CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            let rangeValue = rangeRef as! AXValue
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) {
                return range
            }
        }

        // Fallback: TextMarker range (e.g., TextEdit)
        var markerRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextMarkerRangeAttribute as CFString, &markerRef) == .success,
           let markerRef {
            if let range = textMarkerRangeToCFRange(element: element, markerRange: markerRef) {
                return range
            }
        }

        return nil
    }

    private func readEditable(from element: AXUIElement) -> Bool? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &valueRef) == .success,
              let valueRef,
              let number = valueRef as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    private func readRole(from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &valueRef) == .success,
              let valueRef,
              let role = valueRef as? String else {
            return nil
        }
        return role
    }

    private func readElementFrame(from element: AXUIElement) -> CGRect? {
        var frameRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameRef) == .success,
           let frameRef,
           CFGetTypeID(frameRef) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(frameRef as! AXValue, .cgRect, &rect) {
                return rect
            }
        }

        frameRef = nil
        if AXUIElementCopyAttributeValue(element, "AXBounds" as CFString, &frameRef) == .success,
           let frameRef,
           CFGetTypeID(frameRef) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(frameRef as! AXValue, .cgRect, &rect) {
                return rect
            }
        }

        return nil
    }
    private func readFont(from element: AXUIElement, value: String?, range: CFRange?) -> NSFont? {
        guard let value, let range else { return nil }
        var lookupRange = range
        if lookupRange.length == 0 {
            let length = (value as NSString).length
            let location = max(0, min(lookupRange.location, max(0, length - 1)))
            let effectiveLength = length > 0 ? 1 : 0
            lookupRange = CFRange(location: location, length: effectiveLength)
        }

        guard let rangeValue = AXValueCreate(.cfRange, &lookupRange) else { return nil }
        var attributedRef: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &attributedRef
        )
        guard result == .success, let attributedRef else { return nil }

        let attributedString = attributedRef as! NSAttributedString
        guard attributedString.length > 0 else { return nil }
        let attributes = attributedString.attributes(at: 0, effectiveRange: nil)
        return attributes[.font] as? NSFont
    }

    private func caretRect(for element: AXUIElement, range: CFRange) -> CGRect? {
        var caretRange = range
        caretRange.length = 0

        if let rect = boundsForRange(caretRange, element: element), isValidCaret(rect) {
            return rect
        }

        if range.location > 0 {
            let prevRange = CFRange(location: range.location - 1, length: 1)
            if let rect = boundsForRange(prevRange, element: element), isValidCaret(rect) {
                return CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
            }
        }

        // Fallback: bounds for text marker range
        if let markerRange = selectedTextMarkerRange(from: element),
           let rect = boundsForTextMarkerRange(markerRange, element: element),
           isValidCaret(rect) {
            return rect
        }

        return nil
    }

    private func boundsForRange(_ range: CFRange, element: AXUIElement) -> CGRect? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var rectRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rectRef
        ) == .success, let rectRef else {
            return nil
        }

        let rectValue = rectRef as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(rectValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func selectedTextMarkerRange(from element: AXUIElement) -> CFTypeRef? {
        var markerRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextMarkerRangeAttribute as CFString, &markerRef) == .success else {
            return nil
        }
        return markerRef
    }

    private func boundsForTextMarkerRange(_ markerRange: CFTypeRef, element: AXUIElement) -> CGRect? {
        var rectRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            markerRange,
            &rectRef
        )
        guard err == .success, let rectRef, CFGetTypeID(rectRef) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(rectRef as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func textMarkerRangeToCFRange(element: AXUIElement, markerRange: CFTypeRef) -> CFRange? {
        var rangeRef: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXRangeForTextMarkerRange" as CFString,
            markerRange,
            &rangeRef
        )
        guard err == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func isValidCaret(_ rect: CGRect) -> Bool {
        guard rect.height > 2 else { return false }
        return rect.origin.x.isFinite && rect.origin.y.isFinite
    }


    private func bestScreenRect(forAXRect rect: CGRect) -> CGRect {
        // AX bounds are commonly in Quartz/global coordinates (top-left origin).
        // Convert to AppKit screen coordinates when possible.
        return convertQuartzRectToAppKit(rect) ?? rect
    }

    private func findTextElement(in root: AXUIElement, maxDepth: Int, maxNodes: Int) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = Set<ObjectIdentifier>()
        var index = 0
        var nodesVisited = 0

        while index < queue.count && nodesVisited < maxNodes {
            let (element, depth) = queue[index]
            index += 1
            nodesVisited += 1

            let identifier = ObjectIdentifier(element)
            if visited.contains(identifier) {
                continue
            }
            visited.insert(identifier)

            if canResolveTextElement(element) {
                return element
            }

            guard depth < maxDepth else { continue }
            let children = collectAXChildren(element)
            for child in children {
                queue.append((child, depth + 1))
            }
        }

        return nil
    }

    private func copyAXElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success,
              let valueRef else {
            return nil
        }
        if CFGetTypeID(valueRef) == AXUIElementGetTypeID() {
            return unsafeBitCast(valueRef, to: AXUIElement.self)
        }
        return nil
    }

    private func copyFrontmostAppElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func collectAXChildren(_ element: AXUIElement) -> [AXUIElement] {
        let attributes: [CFString] = [
            kAXChildrenAttribute as CFString,
            kAXContentsAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString,
            kAXWindowsAttribute as CFString,
            kAXFocusedWindowAttribute as CFString,
            "AXDocument" as CFString,
            "AXSections" as CFString
        ]

        var results: [AXUIElement] = []
        for attribute in attributes {
            results.append(contentsOf: copyAXChildren(element, attribute: attribute))
        }

        return results
    }

    private func copyAXChildren(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success, let valueRef else { return [] }

        if CFGetTypeID(valueRef) == AXUIElementGetTypeID() {
            return [unsafeBitCast(valueRef, to: AXUIElement.self)]
        }

        if CFGetTypeID(valueRef) == CFArrayGetTypeID() {
            let cfArray = valueRef as! CFArray
            let count = CFArrayGetCount(cfArray)
            var result: [AXUIElement] = []
            result.reserveCapacity(count)
            for index in 0..<count {
                let value = CFArrayGetValueAtIndex(cfArray, index)
                let valueRef = unsafeBitCast(value, to: CFTypeRef.self)
                if CFGetTypeID(valueRef) == AXUIElementGetTypeID() {
                    let element = unsafeBitCast(valueRef, to: AXUIElement.self)
                    result.append(element)
                }
            }
            return result
        }

        return []
    }

    private static func hasScreenRecordingPermission() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }
}

private enum RefreshTrigger {
    case timer
    case key
    case ax
}

private struct FocusedTextContext {
    let element: AXUIElement
    let value: String?
    let selectedRange: CFRange?
    let caretRect: CGRect?
    let elementFrame: CGRect?
    let font: NSFont?
}

enum OverlayMode: String {
    case hidden
    case inline
    case mirror

    var label: String {
        switch self {
        case .hidden: return "Hidden"
        case .inline: return "Inline"
        case .mirror: return "Mirror"
        }
    }
}

private extension CGEvent {
    var unicodeString: String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 16)
        keyboardGetUnicodeString(maxStringLength: 16, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }
}
