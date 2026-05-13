import SwiftUI

struct InputSourcePicker: View {
    let sources: [InputSource]
    @Binding var selection: String?
    var allowNone: Bool = true
    var noneLabel: String = "None"

    private var pickerSources: [InputSource] { sources.selectableForPicker() }

    var body: some View {
        Picker("Input Source", selection: Binding(
            get: { selection ?? "" },
            set: { selection = $0.isEmpty ? nil : $0 }
        )) {
            if allowNone {
                Text(noneLabel).tag("")
            }
            if let id = selection, !id.isEmpty, !pickerSources.contains(where: { $0.id == id }) {
                Text("Missing (\(id))").tag(id)
            }
            ForEach(pickerSources) { source in
                Text(pickerSources.displayLabel(for: source)).tag(source.id)
            }
        }
    }
}
