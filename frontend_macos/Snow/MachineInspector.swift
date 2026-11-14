import SwiftUI

/// The settings of the selected machine, in the inspector beside its screen.
///
/// Changes are saved as they're made, except hardware changes to a machine that's
/// running or suspended: its state only matches the hardware it has, so those wait
/// until the user applies them, which starts the machine over.
struct MachineInspector: View {
    @Environment(EmulatorModel.self) private var emulator
    @AppStorage("inspectorTab") private var tab = InspectorTab.machine

    var body: some View {
        if let entry = emulator.displayedEntry {
            VStack(spacing: 0) {
                InspectorTabBar(selection: $tab)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                // Both stay, so edits waiting to be applied in one aren't lost while
                // the other is shown
                ZStack {
                    MachineSettingsForm(entry: entry)
                        .shown(tab == .machine)
                    VideoSettingsForm()
                        .shown(tab == .video)
                }
            }
        } else {
            ContentUnavailableView(
                "No Macintosh Selected", systemImage: "desktopcomputer",
                description: Text("Select a Macintosh to see its settings."))
        }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case machine
    case video

    var id: Self { self }

    var label: String {
        switch self {
        case .machine: "Hardware"
        case .video: "Display"
        }
    }

    var symbol: String {
        switch self {
        case .machine: "cpu"
        case .video: "display"
        }
    }
}

/// Switches the inspector's tabs: AppKit's segmented control, which on macOS 27
/// takes the tabs role, as in Xcode's inspector and Calendar, with a glass thumb that
/// follows the pointer. SwiftUI's picker can't show an icon and a name in a segment.
private struct InspectorTabBar: NSViewRepresentable {
    @Binding var selection: InspectorTab

    private static let tabs = InspectorTab.allCases

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: Self.tabs.map(\.label), trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.select(_:)))
        for (index, tab) in Self.tabs.enumerated() {
            control.setImage(
                NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil),
                forSegment: index)
        }
        if #available(macOS 27, *) {
            control.role = .tabs
        }
        // At the regular size it's a rounded rectangle; Xcode's and Calendar's are
        // capsules
        if #available(macOS 26, *) {
            control.borderShape = .capsule
        }
        // As wide as the inspector, the tabs sharing it equally
        control.segmentDistribution = .fillEqually
        return control
    }

    /// The width it's offered, at its own height
    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl, context: Context)
        -> CGSize?
    {
        let fitting = control.fittingSize
        return CGSize(width: max(proposal.width ?? fitting.width, fitting.width), height: fitting.height)
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = Self.tabs.firstIndex(of: selection) ?? 0
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<InspectorTab>

        init(selection: Binding<InspectorTab>) {
            self.selection = selection
        }

        @objc func select(_ sender: NSSegmentedControl) {
            guard InspectorTab.allCases.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = InspectorTab.allCases[sender.selectedSegment]
        }
    }
}

extension View {
    /// Hides a view without removing it, so it keeps its state
    fileprivate func shown(_ isShown: Bool) -> some View {
        opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .disabled(!isShown)
            .accessibilityHidden(!isShown)
    }
}

private struct MachineSettingsForm: View {
    @Environment(EmulatorModel.self) private var emulator
    let entry: MachineEntry

    /// The settings as saved in the machine's workspace, or nil if they can't be read
    @State private var saved: MachineSetup?
    /// The settings as edited
    @State private var draft = MachineSetup()
    /// The machine the settings are of. Follows the machine when it's renamed here.
    @State private var loadedID: MachineEntry.ID?
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    #if DEBUG
    @Environment(\.previewEdit) private var previewEdit
    #endif

    private var isInUse: Bool { emulator.isInUse(entry) }

    private var hasPendingHardware: Bool {
        guard let saved else { return false }
        return draft.hardware != saved.hardware
    }

    var body: some View {
        // The bar goes below the form rather than over it, so the settings don't
        // scroll behind it. Neither may ask for more height: the window's minimum
        // stays the same whether the bar is shown or not.
        VStack(spacing: 0) {
            form
                .frame(minHeight: 0)
            if hasPendingHardware {
                PendingChangesBar(
                    problem: draft.problem, isInUse: isInUse, isActive: emulator.isActive,
                    revert: revert, apply: apply)
            }
        }
        .frame(minHeight: 0, alignment: .top)
        .onAppear { if loadedID != entry.id { load() } }
        .onChange(of: entry.id) { if loadedID != entry.id { load() } }
        .onChange(of: draft) { save() }
        .onChange(of: emulator.driveChanges) { takeDriveChanges() }
        // Once the machine stops without a state, held back changes can be saved
        .onChange(of: isInUse) { save() }
        .onChange(of: nameFocused) { if !nameFocused { commitName() } }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor.gradient)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(status)
                    }
                }
                LabeledContent("Folder") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.workspaceURL])
                    }
                }
            } header: {
                if saved != nil {
                    MachineHeader(setup: $draft)
                }
            }

            if saved != nil {
                MachineHardwareSections(setup: $draft, folder: entry.folder)
            } else {
                Text("The settings of this Macintosh could not be read.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(emulator.isBusy)
    }

    /// The status's light: green running, yellow paused, orange suspended, gray off
    private var statusColor: Color {
        if emulator.isActive { return emulator.isRunning ? .green : .yellow }
        return entry.hasSavedState ? .orange : .gray
    }

    private var status: String {
        if emulator.isActive { return emulator.isRunning ? "Running" : "Paused" }
        return entry.hasSavedState ? "Suspended" : "Off"
    }

    private func load() {
        loadedID = entry.id
        name = entry.name
        saved = emulator.setup(of: entry)
        if let saved {
            draft = saved
            #if DEBUG
            previewEdit?(&draft)
            #endif
        }
    }

    /// Takes the drives that changed while the machine ran, as saved: a disc the
    /// guest ejected, or one dropped onto the machine. A drive changed here since
    /// keeps the change.
    private func takeDriveChanges() {
        guard let old = saved, loadedID == entry.id, let new = emulator.setup(of: entry),
            new.scsi.count == old.scsi.count, draft.scsi.count == old.scsi.count
        else { return }
        for id in new.scsi.indices where new.scsi[id] != old.scsi[id] {
            saved?.scsi[id] = new.scsi[id]
            if draft.scsi[id] == old.scsi[id] {
                draft.scsi[id] = new.scsi[id]
            }
        }
    }

    /// Saves what can be saved without losing the machine's state
    private func save() {
        guard var saved, loadedID == entry.id else { return }
        var target = saved.withStartSettings(of: draft)
        if hasPendingHardware, !isInUse, draft.problem == nil {
            target = draft
        }
        guard target != saved else { return }
        if let stored = emulator.saveSettings(entry, target) {
            emulator.applyLiveChanges(of: entry, from: saved, to: stored)
            self.saved = stored
            useCopiedROMs(of: target, in: stored)
        }
    }

    /// Saves hardware changes, starting the machine over
    private func apply() {
        let setup = draft
        Task {
            if let stored = await emulator.update(entry, with: setup) {
                saved = stored
                useCopiedROMs(of: setup, in: stored)
            }
        }
    }

    /// Points the draft at the copies of the ROMs saving made in the machine's
    /// folder, where it still has the ROMs that were saved
    private func useCopiedROMs(of setup: MachineSetup, in stored: MachineSetup) {
        if draft.romPath == setup.romPath {
            draft.romPath = stored.romPath
        }
        if draft.displayROMPath == setup.displayROMPath {
            draft.displayROMPath = stored.displayROMPath
        }
    }

    private func revert() {
        if let saved {
            draft = saved.withStartSettings(of: draft)
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else {
            name = entry.name
            return
        }
        if let renamed = emulator.rename(entry, to: trimmed) {
            // Keep the edits rather than reloading them when the entry changes
            loadedID = renamed.id
            name = renamed.name
        } else {
            name = entry.name
        }
    }
}

/// Explains why hardware changes haven't been saved, and applies or reverts them
private struct PendingChangesBar: View {
    let problem: String?
    let isInUse: Bool
    let isActive: Bool
    let revert: () -> Void
    let apply: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, 10)
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
    }

    private var content: some View {
        VStack(spacing: 10) {
            Group {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                } else if isActive {
                    Text("Restart to apply these changes.")
                } else {
                    Text("Applying these changes discards the Macintosh's saved state, so it starts over.")
                }
            }
            .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                if isInUse {
                    Button(action: apply) {
                        Text(isActive ? "Apply and Restart" : "Apply")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(problem != nil)
                }
                Button(action: revert) {
                    Text("Revert").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Previews

#if DEBUG
extension EnvironmentValues {
    /// Edits a preview's machine settings once they're loaded, as if the user had
    /// changed them
    @Entry var previewEdit: ((inout MachineSetup) -> Void)?
}

/// The inspector for a machine of a model, by its identifier. The machine's workspace
/// is written to a temporary folder, as the inspector reads and saves it there.
///
/// - Parameters:
///   - suspended: Whether the machine has a saved state, so hardware changes wait
///     to be applied
///   - edit: Changes to make to the settings, as if the user had made them
@MainActor
private func inspectorPreview(
    model identifier: String, suspended: Bool = false,
    edit: ((inout MachineSetup) -> Void)? = nil
) -> some View {
    let model = ModelInfo.all.first { $0.identifier == identifier }
    let name = model?.name ?? identifier
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "Snow Previews", directoryHint: .isDirectory)
        .appending(path: name, directoryHint: .isDirectory)
    let entry = MachineEntry(
        folder: folder, modelName: name, hasSavedState: suspended, modelIdentifier: model?.identifier)

    var setup = MachineSetup()
    setup.name = name
    setup.romPath = "/ROMs/\(name).rom"
    setup.model = model?.index
    setup.fitToModel()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? writeWorkspace(path: entry.workspaceURL.filePath, config: setup.config(pramURL: entry.pramURL))

    return MachineInspector()
        .frame(width: 340, height: 720)
        .environment(EmulatorModel(previewing: entry))
        .environment(\.previewEdit, edit)
}

#Preview("Macintosh Plus") { inspectorPreview(model: "Plus") }

#Preview("Macintosh II") { inspectorPreview(model: "MacII") }

#Preview("Macintosh SE/30") { inspectorPreview(model: "SE30") }

#Preview("Macintosh Quadra 700") { inspectorPreview(model: "Quadra700") }

#Preview("Pending Changes") {
    // An Ethernet controller added to a suspended machine waits to be applied
    inspectorPreview(model: "Plus", suspended: true) { $0.scsi[3] = .ethernet }
}

#Preview("Pending Changes with a Problem") {
    // The machine has no display card ROM, so adding an Ethernet controller can't
    // be applied until one is chosen
    inspectorPreview(model: "MacII", suspended: true) { $0.scsi[3] = .ethernet }
}

#Preview("No Macintosh Selected") {
    MachineInspector()
        .frame(width: 340, height: 400)
        .environment(EmulatorModel(restoringSession: false))
}
#endif
