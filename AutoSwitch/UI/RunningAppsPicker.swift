import AppKit
import SwiftUI

struct RuleToolbar<AddContent: View>: View {
    @Binding var searchText: String
    let searchPrompt: String
    let addLabel: String
    let addAction: () -> Void
    @Binding var isAddPresented: Bool
    @ViewBuilder var addContent: () -> AddContent

    var body: some View {
        HStack(spacing: 8) {
            Button(action: addAction) {
                Label(addLabel, systemImage: "plus")
            }
            .controlSize(.regular)
            .popover(isPresented: $isAddPresented, arrowEdge: .top) {
                addContent()
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(searchPrompt, text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 240)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct AppIcon: View {
    let icon: NSImage?
    var fallbackSystemImage: String = "app.dashed"

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .frame(width: 28, height: 28)
    }
}

struct AddAppPopover: View {
    let title: String
    let onPick: (_ bundleID: String, _ displayName: String, _ path: String?) -> Void

    @State private var search: String = ""
    @State private var manualBundleID: String = ""
    @State private var manualDisplayName: String = ""

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier != nil && $0.activationPolicy != .prohibited }
            .sorted { lhs, rhs in
                (lhs.localizedName ?? lhs.bundleIdentifier ?? "")
                    .localizedCaseInsensitiveCompare(rhs.localizedName ?? rhs.bundleIdentifier ?? "")
                == .orderedAscending
            }
    }

    private var filteredApps: [NSRunningApplication] {
        guard !search.isEmpty else { return runningApps }
        let needle = search.lowercased()
        return runningApps.filter { app in
            (app.localizedName?.lowercased().contains(needle) ?? false)
                || (app.bundleIdentifier?.lowercased().contains(needle) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search running apps", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredApps, id: \.processIdentifier) { app in
                        Button {
                            guard let bundleID = app.bundleIdentifier else { return }
                            onPick(
                                bundleID,
                                app.localizedName ?? bundleID,
                                app.bundleURL?.path
                            )
                        } label: {
                            HStack(spacing: 10) {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown")
                                        .lineLimit(1)
                                    Text(app.bundleIdentifier ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 5)
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    if filteredApps.isEmpty {
                        Text("No matching running apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .frame(height: 220)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

            DisclosureGroup("Add manually") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Display Name (optional)", text: $manualDisplayName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Bundle ID", text: $manualBundleID)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("Add") {
                            let id = manualBundleID.trimmingCharacters(in: .whitespaces)
                            guard !id.isEmpty else { return }
                            onPick(id, manualDisplayName, nil)
                            manualBundleID = ""
                            manualDisplayName = ""
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(manualBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
