import Combine
import Carbon
import Foundation
import os.log

@MainActor
protocol InputSourceControlling: AnyObject {
    var availableInputSources: [InputSource] { get }
    var currentInputSourceIDValue: String? { get }
    /// Fires whenever the system input source changes *not* as a result of our
    /// own `selectInputSource` call — i.e., the user manually switched (Shift,
    /// Ctrl-Space, menu, etc.). Carries the previous and new source IDs.
    var onUserInitiatedChange: ((_ previousID: String?, _ currentID: String?) -> Void)? { get set }
    func startObservingSystemSourceChanges()
    func refreshInputSources()
    func selectInputSource(id: String) -> Bool
    func inputSource(with id: String) -> InputSource?
}

@MainActor
final class InputSourceController: ObservableObject, InputSourceControlling {
    @Published private(set) var availableInputSources: [InputSource] = []
    @Published private(set) var currentInputSourceIDValue: String?

    var onChange: (() -> Void)?
    var onUserInitiatedChange: ((_ previousID: String?, _ currentID: String?) -> Void)?

    private let logger = Logger(subsystem: "dev.autoswitch", category: "input-source")
    private var observerTokens: [NSObjectProtocol] = []
    private var inputSourceRefsByID: [String: TISInputSource] = [:]
    private var inputSourcesByID: [String: InputSource] = [:]

    func startObservingSystemSourceChanges() {
        guard observerTokens.isEmpty else { return }

        let enabledSourcesToken = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshInputSources()
            }
        }
        observerTokens.append(enabledSourcesToken)

        let selectedSourceToken = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCurrentInputSource()
            }
        }
        observerTokens.append(selectedSourceToken)
    }

    func refreshInputSources() {
        let entries = enumerateKeyboardInputSources()
        let sources = entries.map(\.1).sorted { lhs, rhs in
            lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
        }
        let currentID = currentKeyboardInputSourceID()

        inputSourceRefsByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.1.id, $0.0) })
        inputSourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })

        var didChange = false
        if availableInputSources != sources {
            availableInputSources = sources
            didChange = true
        }
        if currentInputSourceIDValue != currentID {
            currentInputSourceIDValue = currentID
            didChange = true
        }
        if didChange {
            onChange?()
        }
    }

    func selectInputSource(id: String) -> Bool {
        guard currentInputSourceIDValue != id else {
            return true
        }
        guard let source = inputSourceRefsByID[id] else {
            logger.error("missing input source for id \(id, privacy: .public)")
            return false
        }

        let status = TISSelectInputSource(source)
        guard status == noErr else {
            logger.error("TISSelectInputSource failed with status \(status)")
            return false
        }

        currentInputSourceIDValue = id
        onChange?()
        return true
    }

    func inputSource(with id: String) -> InputSource? {
        inputSourcesByID[id]
    }

    private func refreshCurrentInputSource() {
        let currentID = currentKeyboardInputSourceID()
        guard currentInputSourceIDValue != currentID else { return }
        // We only get here via the system notification path (i.e., the user
        // changed sources externally — Shift toggle, Ctrl-Space, menu pick,
        // etc.). When *we* drive a change via `selectInputSource`, the value
        // is synchronously updated in that method, so this guard short-circuits
        // and `onUserInitiatedChange` does not fire.
        let previousID = currentInputSourceIDValue
        currentInputSourceIDValue = currentID
        onChange?()
        onUserInitiatedChange?(previousID, currentID)
    }

    private func enumerateKeyboardInputSources() -> [(TISInputSource, InputSource)] {
        let filter: [CFString: CFTypeRef] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource
        ]

        guard let unmanagedList = TISCreateInputSourceList(filter as CFDictionary, false) else {
            logger.error("failed to list input sources")
            return []
        }
        let list = unmanagedList.takeRetainedValue()

        let count = CFArrayGetCount(list)
        var result: [(TISInputSource, InputSource)] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            let rawValue = CFArrayGetValueAtIndex(list, index)
            let source = unsafeBitCast(rawValue, to: TISInputSource.self)
            guard let inputSource = makeInputSource(from: source) else { continue }
            result.append((source, inputSource))
        }

        return result
    }

    private func makeInputSource(from source: TISInputSource) -> InputSource? {
        guard let sourceID = stringProperty(source, key: kTISPropertyInputSourceID) else {
            return nil
        }

        let name = stringProperty(source, key: kTISPropertyLocalizedName) ?? sourceID
        let category = stringProperty(source, key: kTISPropertyInputSourceCategory) ?? "unknown"
        let languages = stringArrayProperty(source, key: kTISPropertyInputSourceLanguages)
        let isEnabled = boolProperty(source, key: kTISPropertyInputSourceIsEnabled)
        let isSelectCapable = boolProperty(source, key: kTISPropertyInputSourceIsSelectCapable)
        let kind = classify(sourceID: sourceID, category: category, languages: languages)

        return InputSource(
            id: sourceID,
            localizedName: name,
            category: category,
            languages: languages,
            kind: kind,
            isEnabled: isEnabled,
            isSelectCapable: isSelectCapable
        )
    }

    private func currentKeyboardInputSourceID() -> String? {
        guard let unmanagedSource = TISCopyCurrentKeyboardInputSource() else { return nil }
        let source = unmanagedSource.takeRetainedValue()
        return stringProperty(source, key: kTISPropertyInputSourceID)
    }

    private func property<T>(_ source: TISInputSource, key: CFString, as type: T.Type) -> T? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue() as? T
    }

    private func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
        property(source, key: key, as: String.self)
    }

    private func stringArrayProperty(_ source: TISInputSource, key: CFString) -> [String] {
        property(source, key: key, as: [String].self) ?? []
    }

    private func boolProperty(_ source: TISInputSource, key: CFString) -> Bool {
        guard let value = TISGetInputSourceProperty(source, key) else { return false }
        let object = Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
        if let bool = object as? Bool {
            return bool
        }
        if let number = object as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private func classify(sourceID: String, category: String, languages: [String]) -> InputSourceKind {
        let normalized = sourceID.lowercased()
        let languageBlob = languages.joined(separator: " ").lowercased()
        if normalized.contains("abc") || normalized.contains("us") || normalized.contains("keyboardlayout") && languageBlob.contains("en") {
            return .ascii
        }
        if languageBlob.contains("zh") || normalized.contains("pinyin") || normalized.contains("zhuyin") || normalized.contains("wubi") || normalized.contains("cangjie") || normalized.contains("shuangpin") {
            return .chinese
        }
        if normalized.hasPrefix("com.apple") {
            return .system
        }
        if category.lowercased().contains("inputmethod") {
            return .other
        }
        return .other
    }
}
