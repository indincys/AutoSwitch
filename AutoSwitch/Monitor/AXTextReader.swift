import ApplicationServices
import Foundation

/// Pure accessibility-tree text extraction for shell/TUI prompt detection.
///
/// Extracted from ``FocusedElementMonitor`` so that type only orchestrates *when*
/// to read and *what* to do with the result. Nothing here mutates monitor state
/// or reports detections — every method is a function of the AX elements passed
/// in, with explicit depth/character budgets so a pathological tree can't blow up
/// CPU.
struct AXTextReader {
    /// Text from the focused element plus a shallow descendant set. When the
    /// focused leaf has no text (e.g. an Electron canvas), walk up to parent and
    /// grandparent so sibling DOM/widget nodes that *do* expose text contribute.
    func readSearchableText(from element: AXUIElement) -> String {
        var pieces: [String] = []
        collectText(from: element, depth: 0, maxDepth: 3, pieces: &pieces, totalBudget: 4096)
        if joinedLength(pieces) < 16, let parentEl = parentElement(of: element) {
            collectText(from: parentEl, depth: 0, maxDepth: 3, pieces: &pieces, totalBudget: 8192)
            if joinedLength(pieces) < 16, let grandparentEl = parentElement(of: parentEl) {
                collectText(from: grandparentEl, depth: 0, maxDepth: 3, pieces: &pieces, totalBudget: 8192)
            }
        }
        return pieces.joined(separator: "\n")
    }

    /// Fallback when the app refuses to report a focused element (common in
    /// Electron apps that opt out of AX focus tracking): walk the focused window
    /// first, then the main window.
    func readWindowFallbackText(appElement: AXUIElement) -> String {
        var pieces: [String] = []
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(appElement, attr as CFString, &raw)
            guard status == .success, let raw else { continue }
            let window = raw as! AXUIElement
            collectText(from: window, depth: 0, maxDepth: 6, pieces: &pieces, totalBudget: 16384)
            if joinedLength(pieces) >= 16 { break }
        }
        return pieces.joined(separator: "\n")
    }

    /// Role/subrole/identifier description for diagnostics.
    func describeRole(_ element: AXUIElement) -> String {
        let role = stringAttribute(element, kAXRoleAttribute) ?? "?"
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let identifier = stringAttribute(element, kAXIdentifierAttribute)
        var parts = [role]
        if let subrole, !subrole.isEmpty { parts.append("sub=\(subrole)") }
        if let identifier, !identifier.isEmpty { parts.append("id=\(identifier)") }
        return parts.joined(separator: "/")
    }

    // MARK: - Private traversal

    private func joinedLength(_ pieces: [String]) -> Int {
        pieces.reduce(0) { $0 + $1.count }
    }

    private func parentElement(of element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &raw)
        guard status == .success, let raw else { return nil }
        return (raw as! AXUIElement)
    }

    private func collectText(
        from element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        pieces: inout [String],
        totalBudget: Int
    ) {
        let currentLength = pieces.reduce(0) { $0 + $1.count }
        guard currentLength < totalBudget else { return }

        if let value = stringAttribute(element, kAXValueAttribute) {
            pieces.append(value)
        }
        if let placeholder = stringAttribute(element, kAXPlaceholderValueAttribute) {
            pieces.append(placeholder)
        }

        guard depth < maxDepth else { return }

        if let children = arrayAttribute(element, kAXChildrenAttribute) {
            for child in children.prefix(16) {
                collectText(
                    from: child,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    pieces: &pieces,
                    totalBudget: totalBudget
                )
            }
        }
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard status == .success, let raw else { return nil }
        if let str = raw as? String, !str.isEmpty {
            return str
        }
        return nil
    }

    private func arrayAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard status == .success, let raw else { return nil }
        return raw as? [AXUIElement]
    }
}
