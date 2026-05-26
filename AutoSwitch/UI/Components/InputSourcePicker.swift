import SwiftUI

struct InputSourceOption: Identifiable, Hashable {
    let id: String
    let label: String
}

enum InputSourceOptions {
    static func make(from sources: [InputSource]) -> [InputSourceOption] {
        let pickerSources = sources.selectableForPicker()
        let nameCounts = Dictionary(grouping: pickerSources, by: \.localizedName)
            .mapValues(\.count)

        return pickerSources.map { source in
            InputSourceOption(
                id: source.id,
                label: displayLabel(for: source, duplicateNameCount: nameCounts[source.localizedName] ?? 0)
            )
        }
    }

    static func label(for id: String?, options: [InputSourceOption], missingPrefix: String = "缺失") -> String {
        guard let id, !id.isEmpty else {
            return options.first?.label ?? ""
        }
        return options.first { $0.id == id }?.label ?? "\(missingPrefix) (\(id))"
    }

    private static func displayLabel(for source: InputSource, duplicateNameCount: Int) -> String {
        guard duplicateNameCount > 1 else { return source.localizedName }
        if let lang = source.languages.first, !lang.isEmpty {
            return "\(source.localizedName) (\(lang))"
        }
        if let suffix = source.id.split(separator: ".").last {
            return "\(source.localizedName) — \(suffix)"
        }
        return source.localizedName
    }
}

struct InputSourcePicker: View {
    private let sources: [InputSource]
    private let options: [InputSourceOption]?
    @Binding var selection: String?
    private let allowNone: Bool
    private let noneLabel: String

    init(
        sources: [InputSource],
        selection: Binding<String?>,
        allowNone: Bool = false,
        noneLabel: String = "无"
    ) {
        self.sources = sources
        self.options = nil
        self._selection = selection
        self.allowNone = allowNone
        self.noneLabel = noneLabel
    }

    init(
        options: [InputSourceOption],
        selection: Binding<String?>,
        allowNone: Bool = false,
        noneLabel: String = "无"
    ) {
        self.sources = []
        self.options = options
        self._selection = selection
        self.allowNone = allowNone
        self.noneLabel = noneLabel
    }

    private var pickerOptions: [InputSourceOption] {
        options ?? InputSourceOptions.make(from: sources)
    }

    private var fallbackSelectionID: String { pickerOptions.first?.id ?? "" }
    private var resolvedSelectionID: String {
        guard let selection, !selection.isEmpty else {
            return allowNone ? "" : fallbackSelectionID
        }
        return selection
    }

    var body: some View {
        Picker("输入法", selection: Binding(
            get: { resolvedSelectionID },
            set: { newValue in
                selection = newValue.isEmpty && allowNone ? nil : newValue
            }
        )) {
            if allowNone {
                Text(noneLabel).tag("")
            }
            if let id = selection, !id.isEmpty, !pickerOptions.contains(where: { $0.id == id }) {
                Text("缺失 (\(id))").tag(id)
            }
            ForEach(pickerOptions) { option in
                Text(option.label).tag(option.id)
            }
        }
    }
}
