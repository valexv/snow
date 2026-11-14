import SwiftUI

struct ContentView: View {
    @Environment(EmulatorModel.self) private var emulator
    /// Width of the inspector column, which the machine's screen extends under
    @State private var inspectorWidth: CGFloat = 0
    /// Which columns show: the sidebar can be hidden
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var hasMachines: Bool { !emulator.library.machines.isEmpty }

    /// Without machines there's nothing for the sidebar to list, so it stays hidden
    /// until the first is made
    private var visibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { hasMachines ? columnVisibility : .detailOnly },
            set: { if hasMachines { columnVisibility = $0 } })
    }

    var body: some View {
        @Bindable var emulator = emulator

        NavigationSplitView(columnVisibility: visibility) {
            MachineSidebar(isShown: visibility.wrappedValue != .detailOnly)
                // Nor can it be opened from the toolbar. This only takes effect on
                // the sidebar column's view, not on the split view.
                .toolbar(removing: hasMachines ? nil : .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            MachineDetail(inspectorWidth: emulator.showsInspector ? inspectorWidth : 0)
                .inspector(isPresented: $emulator.showsInspector) {
                    MachineInspector()
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                            inspectorWidth = $0
                        }
                }
        }
        // The first machine opens it, even if it was hidden before the last one
        // went
        .onChange(of: hasMachines) { _, hasMachines in
            if hasMachines {
                columnVisibility = .all
            }
        }
        .navigationTitle(emulator.displayedEntry?.name ?? "Snow")
        .navigationSubtitle(emulator.isActive ? "\(emulator.speedPercent)%" : "")
        .sheet(isPresented: $emulator.showsNewMachine) {
            NewMachineView()
        }
        .alert(
            "Snow",
            isPresented: Binding(
                get: { emulator.alert != nil },
                set: { if !$0 { emulator.alert = nil } }),
            presenting: emulator.alert
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message.text)
        }
    }
}

// MARK: - Sidebar

private struct MachineSidebar: View {
    @Environment(EmulatorModel.self) private var emulator
    @State private var renaming: MachineEntry?
    @State private var newName = ""
    @State private var deleting: MachineEntry?
    /// The sidebar is open. Its toolbar items would otherwise stay when it's hidden.
    var isShown = true

    var body: some View {
        List(selection: selection) {
            // Only shown with machines in it
            Section("Macintoshes") {
                ForEach(emulator.library.machines) { entry in
                    MachineRow(entry: entry)
                        .tag(entry.id)
                        .contextMenu { menu(for: entry) }
                }
            }
        }
        // Ignores clicks while busy, rather than being disabled: a disabled list
        // dims its icons, so running machines would look off for a moment
        .allowsHitTesting(!emulator.isBusy)
        .toolbar {
            if isShown {
                ToolbarItem {
                    Button {
                        emulator.showsNewMachine = true
                    } label: {
                        Label("New Macintosh", systemImage: "plus")
                    }
                    .help("New Macintosh")
                    .disabled(emulator.isBusy)
                }
            }
        }
        .alert("Rename Macintosh", isPresented: isPresent($renaming)) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { emulator.rename(renaming, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Move “\(deleting?.name ?? "")” to the Trash?", isPresented: isPresent($deleting),
            presenting: deleting
        ) { entry in
            Button("Move to Trash", role: .destructive) {
                Task { await emulator.delete(entry) }
            }
        } message: { _ in
            Text("This will delete the Macintosh, with all of its settings, drives, and ROMs.")
        }
    }

    private var selection: Binding<MachineEntry.ID?> {
        Binding(
            get: { emulator.selectedEntry?.id },
            // A machine stays selected while there is one: clicking off the list,
            // or Command-clicking the selected row, leaves it as it is
            set: { id in
                guard let entry = emulator.library.entry(id) else { return }
                Task { await emulator.select(entry) }
            })
    }

    @ViewBuilder
    private func menu(for entry: MachineEntry) -> some View {
        let isRunning = entry.id == emulator.current?.id && emulator.isActive
        Button("Settings") { Task { await emulator.showSettings(of: entry) } }
        Button("Rename…") {
            newName = entry.name
            renaming = entry
        }
        if entry.hasSavedState && !isRunning {
            Button("Discard Saved State") { emulator.discardSavedState(of: entry) }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.workspaceURL]) }
        Divider()
        Button("Move to Trash…", role: .destructive) { deleting = entry }
    }

    private func isPresent<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

private struct MachineRow: View {
    @Environment(EmulatorModel.self) private var emulator
    let entry: MachineEntry

    private var state: String? {
        if entry.id == emulator.current?.id, emulator.isActive {
            return emulator.isRunning ? "Running" : "Paused"
        }
        // Being saved or shut down: on until it's done, so its icon doesn't flicker
        if entry.id == emulator.stoppingID { return "Stopping" }
        return entry.hasSavedState ? "Suspended" : nil
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
            }
        } icon: {
            // Machines with a state to resume, or running, stand out from those
            // that are off
            ModelSymbol(identifier: entry.modelIdentifier)
                .foregroundStyle(state == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }
}

// MARK: - Detail

private struct MachineDetail: View {
    @Environment(EmulatorModel.self) private var emulator
    /// Width of the inspector column beside it, or 0 if it's hidden
    var inspectorWidth: CGFloat = 0

    var body: some View {
        // While switching machines, the one switched from stays as it was, under a
        // blur, until the other is ready
        let switching = emulator.switching
        // Switching machines, and starting, saving or stopping one, all show the
        // same: a blur over what's there, with a spinner
        let loading = switching != nil || emulator.isBusy
        Group {
            if emulator.isActive || switching?.showsScreen == true {
                // Extends under the inspector rather than shrinking beside it. The
                // inspector column is a safe area inset, so ignoring the trailing
                // safe area is enough (checked on macOS 26). The screen view leaves
                // the mouse alone in the strip the inspector covers.
                ScreenView(
                    model: emulator, video: switching?.video ?? emulator.video,
                    crtParameters: switching.map(\.crtParameters)
                        ?? (emulator.video.crtEffect ? emulator.crtParameters : nil),
                    screenPixelsPerInch: switching.map(\.screenPixelsPerInch)
                        ?? emulator.screenPixelsPerInch,
                    coveredTrailingWidth: inspectorWidth)
                    .ignoresSafeArea(.container, edges: .trailing)
                    // A compact Mac's screen at its actual size, and the margin around it.
                    // A little wider than that: at exactly that width, with the sidebar
                    // open and two drives, the toolbar is on the edge of fitting, and
                    // its last item flickers in and out of the overflow menu.
                    .frame(minWidth: 512 + 48, minHeight: 342 + 32)
                    .background(.black)
                    .dropDestination(for: URL.self) { urls, _ in
                        emulator.insertDroppedImages(urls)
                    }
                    .overlay(alignment: .bottom) { BannerView(message: emulator.banner) }
            } else if let entry = emulator.displayedEntry {
                MachineStartView(entry: entry)
            } else {
                // A machine is always selected while there is one, so this is for
                // when there are none
                ContentUnavailableView {
                    Label("No Macintoshes", systemImage: "snowflake")
                } description: {
                    Text("Choose a ROM to get started.")
                } actions: {
                    Button("New Macintosh…") { emulator.showsNewMachine = true }
                        .glassProminentButtonStyle()
                        .buttonBorderShape(.capsule)
                        // The size of the start button of a machine that's off
                        .controlSize(.extraLarge)
                }
            }
        }
        .overlay {
            if loading {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea(.container, edges: .trailing)
                    .overlay {
                        ProgressView()
                            .controlSize(.large)
                            .accessibilityLabel(emulator.busyMessage ?? "Loading")
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: loading)
        .toolbar {
            EmulatorToolbar()
            // Keeps the settings button in a capsule of its own
            if emulator.isActive {
                if #available(macOS 26, *) {
                    ToolbarSpacer(.fixed)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                @Bindable var emulator = emulator
                Toggle(isOn: $emulator.showsInspector) {
                    Label("Settings", systemImage: "gearshape")
                }
                .help(emulator.showsInspector ? "Hide the Macintosh's settings" : "Show the Macintosh's settings")
            }
        }
    }
}

/// Shown for the selected machine while it isn't running
private struct MachineStartView: View {
    @Environment(EmulatorModel.self) private var emulator
    let entry: MachineEntry

    var body: some View {
        VStack(spacing: 12) {
            ModelSymbol(identifier: entry.modelIdentifier)
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(entry.name)
                .font(.title.weight(.semibold))
            if entry.hasSavedState {
                Text("Suspended")
                    .foregroundStyle(.secondary)
            }

            if let setup = try? emulator.library.setup(of: entry), let model = setup.effectiveModel {
                MachineSpecsTable(setup: setup, model: model)
            } else {
                Text(entry.modelName)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if entry.hasSavedState {
                    Button("Start Fresh") { Task { await emulator.startFresh() } }
                    Button("Resume") { Task { await emulator.resume() } }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start", systemImage: "play.fill") {
                        Task { await emulator.startFresh() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButtonStyle()
                }
            }
            // The view's one thing to do, so it stands out
            .controlSize(.extraLarge)
            .padding(.top, 8)
            .disabled(emulator.isBusy)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What a machine has, as the new machine sheet lists it, but not to be edited
private struct MachineSpecsTable: View {
    let setup: MachineSetup
    let model: ModelInfo

    var body: some View {
        // Rows on their own, without a form's box or the lines between them
        VStack(alignment: .leading, spacing: 10) {
            Group {
                row("Model", "apple.logo", model.name)
                row("Processor", "cpu", processor)
                row("Memory", "memorychip", "\(formatSize(setup.ramSize ?? model.defaultRamSize)) RAM")
                if let vram = setup.vramSize ?? model.defaultVramSize, !model.vramSizes.isEmpty {
                    row("Video memory", "memorychip.fill", "\(formatSize(vram)) VRAM")
                }
                row("Floppy drive", "opticaldiscdrive", model.specs.floppies)
                if model.hasScsi {
                    if let disks = names(of: disks) {
                        row("Hard disk", "internaldrive", disks)
                    }
                    if hasCDROM {
                        row("CD-ROM", "opticaldisc", "CD-ROM drive")
                    }
                    if setup.ethernetID != nil {
                        row("Network", "network", "Ethernet")
                    }
                    if setup.printerID != nil {
                        row("Printer", "printer", "LaserWriter IISC")
                    }
                }
                row("Monitor", "display", monitor)
            }
        }
        .padding(.vertical, 8)
        // As wide as its longest row, so it's centered under the machine's name
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(.secondary)
    }

    /// The value beside its icon. The title isn't shown: the icon and value say
    /// enough, and VoiceOver reads the title.
    private func row(_ title: String, _ systemImage: String, _ value: String) -> some View {
        Label {
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                // Long values, like several disks, wrap rather than widen the table
                .frame(maxWidth: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            // All as wide, so the values line up
            Image(systemName: systemImage)
                .frame(width: 22)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }

    /// The CPU fitted, with its FPU if it has one as an option
    private var processor: String {
        let speed = model.specs.cpuSpeed
        return switch model.fpuOption {
        case .cpu68040: "\(setup.fpu ? "68040" : "68LC040") at \(speed)"
        case .coprocessor where setup.fpu: "\(model.specs.cpu) at \(speed), 68882 FPU"
        default: "\(model.specs.cpu) at \(speed)"
        }
    }

    /// The size of each hard disk image, or "Missing" for one that isn't there
    private var disks: [String] {
        setup.scsi.compactMap { device in
            guard case .disk(let path) = device else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? UInt64
            return size.map(formatSize) ?? "Missing"
        }
    }

    private var hasCDROM: Bool {
        setup.scsi.contains { device in
            switch device {
            case .cdrom, .cdromFolder: true
            default: false
            }
        }
    }

    private func names(of items: [String]) -> String? {
        items.isEmpty ? nil : items.joined(separator: ", ")
    }

    private var monitor: String {
        if !setup.monitorChoices.isEmpty, let monitor = setup.monitor ?? model.defaultMonitor {
            return monitor.name
        }
        if model.hasDisplayCard, let monitor = model.defaultMonitor {
            return monitor.name
        }
        return "Built-in display"
    }
}

private struct EmulatorToolbar: ToolbarContent {
    @Environment(EmulatorModel.self) private var emulator

    var body: some ToolbarContent {
        // The floppy and CD-ROM drives, in a group of their own
        ToolbarItemGroup {
            if emulator.isActive {
                ForEach(emulator.floppies.filter(\.present)) { drive in
                    FloppyMenu(drive: drive)
                }
                ForEach(emulator.cdromDrives, id: \.title) { title, drive in
                    CDROMMenu(drive: drive, title: title)
                }
            }
        }

        // Splits the toolbar's glass, so the drives get a capsule of their own
        if emulator.isActive {
            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed)
            }
        }

        ToolbarItemGroup {
            if emulator.isActive {
                // On, and highlighted as the fast-forward button is, while paused
                Toggle(
                    isOn: Binding(
                        get: { !emulator.isRunning },
                        set: { _ in emulator.togglePause() })
                ) {
                    Label(
                        emulator.isRunning ? "Pause" : "Run",
                        systemImage: emulator.isRunning ? "pause" : "play")
                }
                .help(emulator.isRunning ? "Pause" : "Run")

                Toggle(
                    isOn: Binding(
                        // Not shown as on while paused, when nothing runs fast
                        get: { emulator.isFastForwarding && emulator.isRunning },
                        set: { _ in emulator.toggleFastForward() })
                ) {
                    Label("Fast Forward", systemImage: "forward")
                }
                .help(emulator.isFastForwarding ? "Run at normal speed" : "Fast forward")
                // As in the egui frontend. It keeps its speed for when the machine runs.
                .disabled(!emulator.isRunning)

                Button {
                    emulator.reset()
                } label: {
                    Label("Restart", systemImage: "restart.circle")
                }
                .help("Restart the Macintosh")

                Button {
                    Task { await emulator.powerOff() }
                } label: {
                    Label("Power Off", systemImage: "power")
                }
                .help("Power off the Macintosh")
                .disabled(emulator.isBusy)
            }
        }

        // Sound and screenshots, in a capsule of their own
        if emulator.isActive {
            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed)
            }
        }

        ToolbarItemGroup {
            if emulator.isActive {
                Button {
                    emulator.isMuted.toggle()
                } label: {
                    Label {
                        Text(emulator.isMuted ? "Unmute" : "Mute")
                    } icon: {
                        // Both icons take up room, so the button keeps the width of
                        // the wider one as it switches between them
                        ZStack {
                            Image(systemName: "speaker.wave.2")
                                .opacity(emulator.isMuted ? 0 : 1)
                            Image(systemName: "speaker.slash")
                                .opacity(emulator.isMuted ? 1 : 0)
                        }
                    }
                }
                .help(emulator.isMuted ? "Unmute" : "Mute")

                Button {
                    emulator.takeScreenshot()
                } label: {
                    Label("Take Screenshot", systemImage: "camera")
                }
                .help("Save a screenshot to the Desktop")
            }
        }
    }
}

private struct FloppyMenu: View {
    @Environment(EmulatorModel.self) private var emulator
    let drive: FloppyStatus

    var body: some View {
        Menu {
            if drive.inserted {
                Text(drive.title.isEmpty ? "Disk" : drive.title)
                Button("Force Eject") { emulator.ejectFloppy(drive: drive.drive) }
            } else {
                Button("Insert Disk…") {
                    if let url = FilePanels.chooseFile(title: "Insert Floppy Disk") {
                        emulator.insertFloppy(drive: drive.drive, url: url)
                    }
                }
            }
        } label: {
            Label(
                "Floppy \(drive.drive + 1)",
                systemImage: drive.inserted ? "opticaldiscdrive.fill" : "opticaldiscdrive")
        }
        // Without the arrow, it joins the other drive's capsule like a button
        .menuIndicator(.hidden)
        .help(drive.inserted ? "Floppy \(drive.drive + 1): \(drive.title)" : "Floppy \(drive.drive + 1): empty")
    }
}

/// A CD-ROM drive: inserts a disc while it's empty, and shows the one in it. Only
/// the guest ejects a disc. With no drive, inserting a disc adds one.
private struct CDROMMenu: View {
    @Environment(EmulatorModel.self) private var emulator
    /// Nil for the drive a model that can have one hasn't got yet
    let drive: CdromStatus?
    let title: String

    var body: some View {
        Menu {
            if let folder = drive?.managedFolder {
                Text("Toolbox managed folder: \(name(of: folder))")
                Button("Show in Finder") { showInFinder(folder) }
            } else if let path = drive?.discPath {
                Text(name(of: path))
                Button("Show in Finder") { showInFinder(path) }
            } else {
                Button("Insert Disc Image…") {
                    if let url = FilePanels.chooseFile(
                        title: "Insert Disc Image", types: FilePanels.discImageTypes)
                    {
                        emulator.insertDisc(.image(path: url.filePath), drive: driveID)
                    }
                }
                Button("Insert Folder as Disc…") {
                    if let url = FilePanels.chooseFolder(title: "Choose a Folder to Make into a Disc") {
                        emulator.insertDisc(.folder(path: url.filePath), drive: driveID)
                    }
                }
            }
        } label: {
            Label(title, systemImage: hasDisc ? "opticaldisc.fill" : "opticaldisc")
        }
        // Without the arrow, it joins the other drives' capsule like a button
        .menuIndicator(.hidden)
        .help(help)
    }

    private var driveID: Int? { drive.map { Int($0.id) } }

    private var hasDisc: Bool { drive?.discPath != nil || drive?.managedFolder != nil }

    private var help: String {
        if let folder = drive?.managedFolder {
            return "\(title): \(name(of: folder)) (Toolbox managed folder)"
        }
        return "\(title): \(drive?.discPath.map(name(of:)) ?? "empty")"
    }

    private func name(of path: String) -> String { URL(filePath: path).lastPathComponent }

    private func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }
}

private struct BannerView: View {
    let message: UserMessage?

    var body: some View {
        if let message {
            Label(message.text, systemImage: icon(for: message.kind))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
                .transition(.opacity)
        }
    }

    private func icon(for kind: MessageKind) -> String {
        switch kind {
        case .success: "checkmark.circle"
        case .notice: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

extension View {
    /// Glass, tinted with the accent color, on macOS 26 and later; prominent before it
    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
