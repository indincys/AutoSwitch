import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

struct AddAppItem {
    let bundleID: String
    let displayName: String
    let path: String?
}

struct InstalledApp: Hashable {
    let bundleID: String
    let displayName: String
    let bundleURL: URL
}

enum InstalledAppScanner {
    static var canonicalAppsFolders: [String] {
        let home = NSHomeDirectory()
        return [
            "/Applications",
            "/System/Applications",
            "\(home)/Applications",
            "/Network/Applications"
        ]
    }

    static func scan() -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for folder in canonicalAppsFolders {
            scan(folder: folder, depth: 0, fm: fm, seen: &seen, apps: &apps)
        }
        return apps.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func scan(folder: String, depth: Int, fm: FileManager, seen: inout Set<String>, apps: inout [InstalledApp]) {
        guard fm.fileExists(atPath: folder) else { return }
        guard let entries = try? fm.contentsOfDirectory(atPath: folder) else { return }
        for name in entries {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            if name.hasSuffix(".app") {
                addApp(at: url, seen: &seen, apps: &apps)
            } else if depth < 1 {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    scan(folder: url.path, depth: depth + 1, fm: fm, seen: &seen, apps: &apps)
                }
            }
        }
    }

    private static func addApp(at url: URL, seen: inout Set<String>, apps: inout [InstalledApp]) {
        guard let bundle = Bundle(url: url) else { return }
        guard let bundleID = bundle.bundleIdentifier, !seen.contains(bundleID) else { return }
        seen.insert(bundleID)
        let displayName = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? FileManager.default.displayName(atPath: url.path)
        apps.append(InstalledApp(
            bundleID: bundleID,
            displayName: displayName,
            bundleURL: url
        ))
    }
}

struct AddAppPopover: View {
    let availableInputSources: [InputSource]
    let defaultInputSourceID: String?
    let onCommit: (_ items: [AddAppItem], _ inputSourceID: String?) -> Void

    init(
        availableInputSources: [InputSource],
        defaultInputSourceID: String?,
        onCommit: @escaping (_ items: [AddAppItem], _ inputSourceID: String?) -> Void
    ) {
        self.availableInputSources = availableInputSources
        self.defaultInputSourceID = defaultInputSourceID
        self.onCommit = onCommit
        _pickedInputSourceID = State(initialValue: defaultInputSourceID)
    }

    @State private var search: String = ""
    @State private var manualBundleID: String = ""
    @State private var manualDisplayName: String = ""
    @State private var manualExpanded: Bool = false
    @State private var selectedBundleIDs: Set<String> = []
    @State private var manualEntries: [AddAppItem] = []
    @State private var pickedInputSourceID: String?
    @State private var installedApps: [InstalledApp] = []
    @State private var runningBundleIDs: Set<String> = []
    @State private var isScanning: Bool = false

    private var filteredApps: [InstalledApp] {
        guard !search.isEmpty else { return installedApps }
        let needle = search.lowercased()
        return installedApps.filter { app in
            app.displayName.lowercased().contains(needle)
                || app.bundleID.lowercased().contains(needle)
        }
    }

    private var selectionCount: Int {
        selectedBundleIDs.count + manualEntries.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add Apps").font(.headline)
                Spacer()
                if selectionCount > 0 {
                    Button("Clear") {
                        selectedBundleIDs.removeAll()
                        manualEntries.removeAll()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search installed apps", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            ScrollView {
                if isScanning && installedApps.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Scanning Applications…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !manualEntries.isEmpty {
                            ForEach(manualEntries, id: \.bundleID) { item in
                                ManualEntryRow(item: item) {
                                    manualEntries.removeAll { $0.bundleID == item.bundleID }
                                }
                            }
                            Divider().padding(.vertical, 4)
                        }
                        ForEach(filteredApps, id: \.bundleID) { app in
                            AppRowItem(
                                app: app,
                                isRunning: runningBundleIDs.contains(app.bundleID),
                                isSelected: selectedBundleIDs.contains(app.bundleID),
                                onToggle: {
                                    if selectedBundleIDs.contains(app.bundleID) {
                                        selectedBundleIDs.remove(app.bundleID)
                                    } else {
                                        selectedBundleIDs.insert(app.bundleID)
                                    }
                                }
                            )
                        }
                        if filteredApps.isEmpty && manualEntries.isEmpty && !isScanning {
                            Text(search.isEmpty ? "No apps found in standard locations." : "No matches.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 20)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 340)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

            Button {
                browseApplications()
            } label: {
                Label("Browse Applications…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)

            VStack(alignment: .leading, spacing: 4) {
                Text("Input source for selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                InputSourcePicker(
                    sources: availableInputSources,
                    selection: $pickedInputSourceID
                )
                .labelsHidden()
            }

            DisclosureGroup("Add by Bundle ID", isExpanded: $manualExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Display Name (optional)", text: $manualDisplayName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Bundle ID", text: $manualBundleID)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("Add to Selection") {
                            addManualEntry()
                        }
                        .disabled(manualBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.top, 6)
            }

            Divider()

            HStack {
                Text("\(selectionCount) selected")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer()
                Button(commitButtonLabel) {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectionCount == 0)
            }
        }
        .padding(16)
        .frame(width: 440, height: 660)
        .task {
            runningBundleIDs = Set(
                NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
            )
            guard installedApps.isEmpty else { return }
            isScanning = true
            let scanned = await Task.detached(priority: .userInitiated) {
                InstalledAppScanner.scan()
            }.value
            installedApps = scanned
            isScanning = false
        }
    }

    private var commitButtonLabel: String {
        if selectionCount == 0 { return "Add" }
        if selectionCount == 1 { return "Add 1 App" }
        return "Add \(selectionCount) Apps"
    }

    private func addManualEntry() {
        let bid = manualBundleID.trimmingCharacters(in: .whitespaces)
        guard !bid.isEmpty else { return }
        let name = manualDisplayName.trimmingCharacters(in: .whitespaces)
        manualEntries.removeAll { $0.bundleID == bid }
        manualEntries.append(AddAppItem(
            bundleID: bid,
            displayName: name.isEmpty ? bid : name,
            path: nil
        ))
        manualBundleID = ""
        manualDisplayName = ""
    }

    private func browseApplications() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps to add (double-click an app to add it)"
        panel.prompt = "Add"

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
            let displayName = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? FileManager.default.displayName(atPath: url.path)
            manualEntries.removeAll { $0.bundleID == bundleID }
            manualEntries.append(AddAppItem(
                bundleID: bundleID,
                displayName: displayName,
                path: url.path
            ))
        }
    }

    private func commit() {
        var items: [AddAppItem] = []
        for bid in selectedBundleIDs {
            if let installed = installedApps.first(where: { $0.bundleID == bid }) {
                items.append(AddAppItem(
                    bundleID: bid,
                    displayName: installed.displayName,
                    path: installed.bundleURL.path
                ))
            } else {
                items.append(AddAppItem(bundleID: bid, displayName: bid, path: nil))
            }
        }
        items.append(contentsOf: manualEntries)
        onCommit(items, pickedInputSourceID)
    }
}

private struct AppRowItem: View {
    let app: InstalledApp
    let isRunning: Bool
    let isSelected: Bool
    let onToggle: () -> Void

    private var icon: NSImage {
        NSWorkspace.shared.icon(forFile: app.bundleURL.path)
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 15))
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 22, height: 22)
                    if isRunning {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                            .overlay(
                                Circle()
                                    .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1.2)
                            )
                            .offset(x: 1, y: 1)
                    }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.displayName).lineLimit(1)
                    Text(app.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

private struct ManualEntryRow: View {
    let item: AddAppItem
    let onRemove: () -> Void

    private var icon: NSImage? {
        guard let path = item.path else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 15))
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "doc.text")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName).lineLimit(1)
                Text(item.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Color.accentColor.opacity(0.10))
    }
}
