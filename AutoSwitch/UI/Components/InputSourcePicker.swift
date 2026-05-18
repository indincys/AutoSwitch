import SwiftUI

struct InputSourcePicker: View {
    let sources: [InputSource]
    @Binding var selection: String?
    var allowNone: Bool = false
    var noneLabel: String = "无"

    private var pickerSources: [InputSource] { sources.selectableForPicker() }
    private var fallbackSelectionID: String { pickerSources.first?.id ?? "" }
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
            if let id = selection, !id.isEmpty, !pickerSources.contains(where: { $0.id == id }) {
                Text("缺失 (\(id))").tag(id)
            }
            ForEach(pickerSources) { source in
                Text(pickerSources.displayLabel(for: source)).tag(source.id)
            }
        }
    }
}
