import SwiftUI

struct InputSourcePicker: View {
    let sources: [InputSource]
    @Binding var selection: String?

    var body: some View {
        Picker("Input Source", selection: Binding(
            get: { selection ?? "" },
            set: { selection = $0.isEmpty ? nil : $0 }
        )) {
            Text("None").tag("")
            ForEach(sources) { source in
                Text(source.localizedName).tag(source.id)
            }
        }
    }
}
