import Combine
import Carbon
import Foundation
import os.log

@MainActor
protocol InputSourceControlling: AnyObject {
    var availableInputSources: [InputSource] { get }
    var currentInputSourceIDValue: String? { get }
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

    private let logger = Logger(subsystem: "dev.autoswitch", category: "input-source")
    private var observerTokens: [NSObjectProtocol] = []
    private var inputSourceRefsByID: [String: TISInputSource] = [:]

    func startObservingSystemSourceChanges() {
        guard observerTokens.isEmpty else { return }

        let names: [Notification.Name] = [
            Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        ]

        for name in names {
            let token = DistributedNotificationCenter.default().addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshInputSources()
                }
            }
            observerTokens.append(token)
        }
    }

    func refreshInputSources() {
        let entries = enumerateKeyboardInputSources()
        inputSourceRefsByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.1.id, $0.0) })
        availableInputSources = entries.map(\.1).sorted { lhs, rhs in
            lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
        }
        currentInputSourceIDValue = currentKeyboardInputSourceID()
        onChange?()
    }

    func selectInputSource(id: String) -> Bool {
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
        availableInputSources.first(where: { $0.id == id })
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
