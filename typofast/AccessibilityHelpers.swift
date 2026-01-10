import AppKit
import ApplicationServices

enum AccessibilityHelpers {
    private static func isRemoteAccessibilityElement(_ object: AnyObject) -> Bool {
        let name = String(describing: type(of: object))
        if name.contains("AccessibilityRemoteUIElement") { return true }
        let objcName = NSStringFromClass(type(of: object))
        return objcName.contains("AccessibilityRemoteUIElement")
    }

    private static func asAXUIElement(_ object: AnyObject?) -> AXUIElement? {
        guard let object = object else { return nil }
        if isRemoteAccessibilityElement(object) { return nil }
        if object is NSAccessibilityElement { return nil }
        guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(object, to: AXUIElement.self)
    }

    static func axElementIfAvailable(_ object: AnyObject?) -> AXUIElement? {
        return asAXUIElement(object)
    }

    private static func asAccessibleElement(_ object: AnyObject?) -> AnyObject? {
        guard let object = object else { return nil }
        if isRemoteAccessibilityElement(object) { return nil }
        if object is NSArray { return object }
        if CFGetTypeID(object) == AXUIElementGetTypeID() {
            return unsafeBitCast(object, to: AXUIElement.self) as AnyObject
        }
        return nil
    }

    static func isProcessTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func focusedElement() -> AnyObject? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        if error == .success, let element = asAccessibleElement(focused) {
            return element
        }

        // Fallback: query focused element from focused application.
        var focusedApp: AnyObject?
        let appError = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        if appError == .success, let appAX = asAXUIElement(focusedApp) {
            var appFocused: AnyObject?
            let focusedError = AXUIElementCopyAttributeValue(appAX, kAXFocusedUIElementAttribute as CFString, &appFocused)
            if focusedError == .success, let element = asAccessibleElement(appFocused) {
                return element
            }
        }

        return nil
    }

    static func focusedApplicationElement() -> AnyObject? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        guard error == .success else { return nil }
        return asAccessibleElement(focusedApp)
    }

    static func focusedApplicationName() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        guard error == .success,
              let app = asAXUIElement(focusedApp) else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        if let running = NSRunningApplication(processIdentifier: pid) {
            return running.localizedName
        }
        return nil
    }

    static func frontmostApplicationElement() -> AnyObject? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    static func isEditableTextElement(_ element: AnyObject) -> Bool {
        if let object = element as? NSObject, isRemoteAccessibilityElement(object) { return false }
        if element is NSArray { return false }
        guard let role = role(of: element) else { return false }
        if role == "AXSecureTextField" { return false }

        let editable = boolAttributeOptional(element, key: "AXEditable")
        let allowedRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            "AXSearchField",
            kAXComboBoxRole as String,
            "AXRichTextArea"
        ]
        let webEditableRoles: Set<String> = [
            "AXWebArea",
            "AXGroup"
        ]
        if allowedRoles.contains(role) {
            // Some apps omit AXEditable; default to true for known text roles.
            return editable ?? true
        }
        if webEditableRoles.contains(role) {
            // Web views often expose editable fields without AXEditable.
            if editable == true { return true }
            let hasSelection = hasAttribute(element, key: kAXSelectedTextRangeAttribute as String)
            let hasSelectedText = hasAttribute(element, key: kAXSelectedTextAttribute as String)
            let hasValue = hasAttribute(element, key: kAXValueAttribute as String)
            let valueSettable = isAttributeSettable(element, key: kAXValueAttribute as String)
            return hasSelection || hasSelectedText || hasValue || valueSettable
        }
        return false
    }

    static func role(of element: AnyObject) -> String? {
        if let object = element as? NSObject, isRemoteAccessibilityElement(object) {
            return nil
        }
        if element is NSArray {
            return nil
        }
        return attributeValue(element, key: kAXRoleAttribute as String) as? String
    }

    static func resolveEditableElement(from element: AnyObject?) -> AnyObject? {
        guard let element = element else { return nil }
        if let object = element as? NSObject, isRemoteAccessibilityElement(object) {
            return nil
        }
        if let array = element as? [AnyObject] {
            for item in array {
                if let found = resolveEditableElement(from: item) {
                    return found
                }
            }
            return nil
        }
        if isEditableTextElement(element) { return element }

        if let focused = elementAttributeElement(element, key: kAXFocusedUIElementAttribute as String) {
            if isEditableTextElement(focused) { return focused }
        }

        if let focusedWindow = elementAttributeElement(element, key: kAXFocusedWindowAttribute as String) {
            if isEditableTextElement(focusedWindow) { return focusedWindow }
            if let focused = elementAttributeElement(focusedWindow, key: kAXFocusedUIElementAttribute as String) {
                if isEditableTextElement(focused) { return focused }
            }
        }

        return findEditableDescendant(in: element, depth: 8, limit: 1200)
    }

    static func stringValue(_ element: AnyObject) -> String? {
        let value = attributeValue(element, key: kAXValueAttribute as String)
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    static func selectedText(_ element: AnyObject) -> String? {
        let value = attributeValue(element, key: kAXSelectedTextAttribute as String)
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    static func selectedRange(_ element: AnyObject) -> NSRange? {
        let value = attributeValue(element, key: kAXSelectedTextRangeAttribute as String)
        if let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() {
            var range = CFRange(location: 0, length: 0)
            guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }
            return NSRange(location: range.location, length: range.length)
        }
        if let nsValue = value as? NSValue {
            return nsValue.rangeValue
        }
        return nil
    }

    static func setSelectedRange(_ element: AnyObject, range: NSRange) -> Bool {
        if let ax = asAXUIElement(element) {
            var cfRange = CFRange(location: range.location, length: range.length)
            guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
            return AXUIElementSetAttributeValue(ax, kAXSelectedTextRangeAttribute as CFString, value) == .success
        }
        return false
    }

    static func setStringValue(_ element: AnyObject, value: String) -> Bool {
        if let ax = asAXUIElement(element) {
            return AXUIElementSetAttributeValue(ax, kAXValueAttribute as CFString, value as CFString) == .success
        }
        return false
    }

    static func replaceText(in element: AnyObject, range: NSRange, with replacement: String) -> String? {
        guard let text = stringValue(element) else { return nil }
        let nsText = text as NSString
        let clampedRange = NSRange(
            location: max(0, min(range.location, nsText.length)),
            length: max(0, min(range.length, nsText.length - min(range.location, nsText.length)))
        )

        let newText = nsText.replacingCharacters(in: clampedRange, with: replacement)
        guard setStringValue(element, value: newText) else { return nil }

        let newLocation = clampedRange.location + (replacement as NSString).length
        _ = setSelectedRange(element, range: NSRange(location: newLocation, length: 0))
        return newText
    }

    static func caretRect(for element: AnyObject, selection: NSRange) -> CGRect? {
        if let rect = boundsForRange(element, range: NSRange(location: selection.location, length: 0)) {
            return rect
        }

        if selection.location > 0 {
            let fallbackRange = NSRange(location: selection.location - 1, length: 1)
            if let rect = boundsForRange(element, range: fallbackRange) {
                return CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
            }
        }

        return nil
    }

    static func fontForInsertionPoint(element: AnyObject, text: String, selection: NSRange) -> NSFont? {
        let nsText = text as NSString
        if nsText.length == 0 { return nil }

        let location = max(0, min(selection.location, nsText.length - 1))
        let range = NSRange(location: location, length: 1)
        if let attributed = attributedString(element, range: range) {
            if let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                return font
            }
        }
        return nil
    }

    private static func boundsForRange(_ element: AnyObject, range: NSRange) -> CGRect? {
        if let ax = asAXUIElement(element) {
            var cfRange = CFRange(location: range.location, length: range.length)
            guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
            var value: AnyObject?
            let error = AXUIElementCopyParameterizedAttributeValue(
                ax,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue,
                &value
            )
            guard error == .success, let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(axValue as! AXValue, .cgRect, &rect) else { return nil }
            return rect
        }
        return nil
    }

    private static func attributedString(_ element: AnyObject, range: NSRange) -> NSAttributedString? {
        if let ax = asAXUIElement(element) {
            var cfRange = CFRange(location: range.location, length: range.length)
            guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
            var value: AnyObject?
            let error = AXUIElementCopyParameterizedAttributeValue(
                ax,
                kAXAttributedStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &value
            )
            guard error == .success else { return nil }
            return value as? NSAttributedString
        }
        return nil
    }

    private static func boolAttributeOptional(_ element: AnyObject, key: String) -> Bool? {
        let value = attributeValue(element, key: key)
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    static func isAttributeSettable(_ element: AnyObject, key: String) -> Bool {
        if let ax = asAXUIElement(element) {
            var settable: DarwinBoolean = false
            let error = AXUIElementIsAttributeSettable(ax, key as CFString, &settable)
            return error == .success && settable.boolValue
        }
        return false
    }

    static func hasAttribute(_ element: AnyObject, key: String) -> Bool {
        return attributeValue(element, key: key) != nil
    }

    static func elementAtCursor(in appElement: AnyObject?) -> AnyObject? {
        guard let appElement = asAXUIElement(appElement) else { return nil }
        let location = NSEvent.mouseLocation
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(appElement, Float(location.x), Float(location.y), &element)
        guard error == .success, let found = element else { return nil }
        return found
    }

    static func attributeNames(of element: AnyObject) -> [String] {
        if let ax = asAXUIElement(element) {
            var names: CFArray?
            let error = AXUIElementCopyAttributeNames(ax, &names)
            guard error == .success, let array = names as? [String] else { return [] }
            return array
        }
        return []
    }

    static func childrenCount(of element: AnyObject) -> Int {
        return children(of: element).count
    }

    private static func elementAttributeElement(_ element: AnyObject, key: String) -> AnyObject? {
        return attributeValue(element, key: key)
    }

    private static func children(of element: AnyObject) -> [AnyObject] {
        if let object = element as? NSObject, isRemoteAccessibilityElement(object) {
            return []
        }
        if let array = element as? [AnyObject] {
            return array
        }
        let keys: [String] = [
            kAXChildrenAttribute as String,
            "AXChildrenInNavigationOrder",
            "AXVisibleChildren",
            "AXSelectedChildren",
            "AXSelectedChildrenInNavigationOrder",
            "AXContents",
            "AXUIElements",
            "AXRows",
            "AXCells"
        ]
        let singleKeys: [String] = [
            "AXDocument",
            "AXSections",
            "AXContent"
        ]
        var result: [AnyObject] = []
        for key in keys {
            let value = attributeValue(element, key: key)
            if let array = value as? [AnyObject] {
                result.append(contentsOf: array)
            }
        }
        for key in singleKeys {
            if let obj = attributeValue(element, key: key) {
                result.append(obj)
            }
        }
        return result
    }

    private static func findEditableDescendant(in element: AnyObject, depth: Int, limit: Int) -> AnyObject? {
        if depth <= 0 || limit <= 0 { return nil }
        let kids = children(of: element)
        if kids.isEmpty { return nil }

        var remaining = limit
        for child in kids {
            remaining -= 1
            if remaining <= 0 { return nil }
            if isEditableTextElement(child) { return child }
            if let found = findEditableDescendant(in: child, depth: depth - 1, limit: remaining) {
                return found
            }
        }
        return nil
    }

    private static func attributeValue(_ element: AnyObject, key: String) -> AnyObject? {
        if element is NSArray { return nil }
        if let object = element as? NSObject, isRemoteAccessibilityElement(object) {
            return nil
        }
        if let ax = asAXUIElement(element) {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(ax, key as CFString, &value)
            guard error == .success else { return nil }
            return value
        }
        return nil
    }
}
