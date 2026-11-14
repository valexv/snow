import SwiftUI

// The hard disks and CD-ROM drives on a machine's SCSI bus, in the inspector

extension MachineSetup {
    /// A free SCSI ID, trying them in the order given, or nil if all are taken
    func freeSCSIID(preferring order: [Int]) -> Int? {
        order.first { scsi[$0] == .none }
    }

    /// Hard disks start at ID 0, as on a real Mac, keeping ID 3 for a CD-ROM drive
    var freeDiskID: Int? { freeSCSIID(preferring: [0, 1, 2, 4, 5, 6, 3]) }

    /// Apple's CD-ROM drives came set to ID 3
    var freeCDROMID: Int? { freeSCSIID(preferring: [3, 4, 5, 6, 2, 1, 0]) }
}

/// The hard disks, with buttons to create a new one or add an existing image
struct HardDisksSection: View {
    @Binding var setup: MachineSetup
    /// The machine's folder, where new disks are made
    let folder: URL?
    @State private var creating = false

    private var disks: [(id: Int, path: String)] {
        setup.scsi.indices.compactMap { id in
            if case .disk(let path) = setup.scsi[id] { (id, path) } else { nil }
        }
    }

    var body: some View {
        Section("Hard Disks") {
            ForEach(disks, id: \.id) { disk in
                DriveRow(
                    title: URL(filePath: disk.path).lastPathComponent,
                    detail: detail(of: disk), systemImage: "internaldrive", path: disk.path
                ) {
                    Button("Choose Another Image…") { addExisting(at: disk.id) }
                    Divider()
                    Button("Show in Finder") { showInFinder(disk.path) }
                    Divider()
                    Button("Remove") { setup.scsi[disk.id] = .none }
                }
            }
            HStack {
                Spacer()
                Menu("Add Disk") {
                    Button("New Disk…") { creating = true }
                        .disabled(folder == nil)
                    Button("Existing Disk Image…") { addExisting(at: setup.freeDiskID) }
                }
                .fixedSize()
                Spacer()
            }
            .disabled(setup.freeDiskID == nil)
        }
        .sheet(isPresented: $creating) {
            if let folder {
                NewDiskSheet(folder: folder) { url in
                    if let id = setup.freeDiskID {
                        setup.scsi[id] = .disk(path: url.filePath)
                    }
                }
            }
        }
    }

    private func detail(of disk: (id: Int, path: String)) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: disk.path)[.size]) as? UInt64
        let missing = !FileManager.default.fileExists(atPath: disk.path)
        return ["SCSI ID \(disk.id)", missing ? "Missing" : size.map(formatSize)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func addExisting(at id: Int?) {
        guard let id,
            let url = FilePanels.chooseFile(
                title: "Choose a Hard Disk Image", startingAt: folder?.filePath ?? "")
        else { return }
        setup.scsi[id] = .disk(path: url.filePath)
    }
}

/// The CD-ROM drives, with the disc in each, and a menu to add one
struct CDROMSection: View {
    @Binding var setup: MachineSetup

    var body: some View {
        Section("CD-ROM") {
            ForEach(setup.scsi.indices, id: \.self) { id in
                switch setup.scsi[id] {
                case .cdrom(let disc):
                    discRow(id: id, disc: disc)
                case .cdromFolder(let path):
                    DriveRow(
                        title: URL(filePath: path).lastPathComponent,
                        detail: "SCSI ID \(id) · Toolbox managed folder",
                        systemImage: "folder", path: path
                    ) {
                        Button("Choose Another Folder…") {
                            if let url = chooseFolder("Choose a Folder of Disc Images") {
                                setup.scsi[id] = .cdromFolder(path: url.filePath)
                            }
                        }
                        Divider()
                        Button("Show in Finder") { showInFinder(path) }
                        Divider()
                        Button("Remove Drive") { setup.scsi[id] = .none }
                    }
                default:
                    EmptyView()
                }
            }
            HStack {
                Spacer()
                Menu("Add Drive") {
                    Button("With Disc Image…") { add(chooseDisc()) }
                    Button("With Folder as Disc…") { add(chooseFolderDisc()) }
                    Button("Toolbox Managed Folder…") {
                        if let url = chooseFolder("Choose a Folder of Disc Images") {
                            add(.cdromFolder(path: url.filePath))
                        }
                    }
                    .help("A folder of disc images, which the Mac switches between with the BlueSCSI Toolbox")
                    Divider()
                    Button("No Disc") { add(.cdrom(disc: nil)) }
                }
                .fixedSize()
                Spacer()
            }
            .disabled(setup.freeCDROMID == nil)
        }
    }

    private func discRow(id: Int, disc: CdromDisc?) -> some View {
        let (path, isFolder): (String?, Bool) =
            switch disc {
            case .image(let path): (path, false)
            case .folder(let path): (path, true)
            case nil: (nil, false)
            }
        return DriveRow(
            title: path.map { URL(filePath: $0).lastPathComponent } ?? "No disc",
            detail: isFolder ? "SCSI ID \(id) · Folder as disc" : "SCSI ID \(id)",
            systemImage: "opticaldisc", path: path ?? ""
        ) {
            Button("Insert Disc Image…") {
                if let disc = chooseDisc() { setup.scsi[id] = disc }
            }
            Button("Insert Folder as Disc…") {
                if let disc = chooseFolderDisc() { setup.scsi[id] = disc }
            }
            if let path {
                Button("Eject Disc") { setup.scsi[id] = .cdrom(disc: nil) }
                Divider()
                Button("Show in Finder") { showInFinder(path) }
            }
            Divider()
            Button("Remove Drive") { setup.scsi[id] = .none }
        }
        .foregroundStyle(path == nil ? .secondary : .primary)
    }

    private func add(_ device: ScsiDevice?) {
        guard let device, let id = setup.freeCDROMID else { return }
        setup.scsi[id] = device
    }

    private func chooseDisc() -> ScsiDevice? {
        FilePanels.chooseFile(title: "Choose a Disc Image", types: FilePanels.discImageTypes)
            .map { .cdrom(disc: .image(path: $0.filePath)) }
    }

    /// A folder whose files go on a disc, made each time it's inserted
    private func chooseFolderDisc() -> ScsiDevice? {
        chooseFolder("Choose a Folder to Make into a Disc")
            .map { .cdrom(disc: .folder(path: $0.filePath)) }
    }

    private func chooseFolder(_ title: String) -> URL? {
        FilePanels.chooseFolder(title: title)
    }
}

/// A drive: what's in it, its SCSI ID, and a menu of what can be done with it
private struct DriveRow<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    /// The file or folder, shown on hover
    let path: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
            }
            .help(path)
            Spacer()
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private func showInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
}

/// Makes a blank hard disk image in the machine's folder, of a size from those the
/// new machine sheet offers
struct NewDiskSheet: View {
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    let created: (URL) -> Void

    @State private var name: String
    @State private var size: UInt64 = 80 * NewMachineView.mb
    @State private var error: String?

    init(folder: URL, created: @escaping (URL) -> Void) {
        self.folder = folder
        self.created = created
        _name = State(initialValue: Self.uniqueName("Hard Disk", in: folder))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Size", selection: $size) {
                        ForEach(NewMachineView.diskSizes, id: \.self) { size in
                            Text(formatSize(size)).tag(size)
                        }
                    }
                } header: {
                    Text("New Hard Disk")
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("The disk is blank, so the Mac offers to initialize it. It's kept in the Macintosh's folder, and only takes up space as it's filled.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding()
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
    }

    private func create() {
        let url = folder.appending(path: Self.uniqueName(trimmedName, in: folder) + ".img")
        do {
            try MachineLibrary.createBlankDisk(at: url, size: size)
            created(url)
            dismiss()
        } catch {
            self.error = "The disk could not be created: \(error.localizedDescription)"
        }
    }

    /// The name, numbered if a disk by that name is already in the folder
    private static func uniqueName(_ name: String, in folder: URL) -> String {
        let taken = { (candidate: String) in
            FileManager.default.fileExists(atPath: folder.appending(path: candidate + ".img").filePath)
        }
        guard taken(name) else { return name }
        return (2...).lazy.map { "\(name) \($0)" }.first { !taken($0) }!
    }
}

extension MachineSetup {
    /// The SCSI ID of the Ethernet controller, if there is one
    var ethernetID: Int? { scsi.firstIndex(of: .ethernet) }

    /// The DaynaPORT drivers find the controller most reliably at ID 3 (Snow's
    /// manual, "Ethernet"), so it goes there if it's free
    var freeEthernetID: Int? { freeSCSIID(preferring: [3, 6, 5, 4, 2, 1, 0]) }
}

extension MachineSetup {
    /// The SCSI ID of the printer, if there is one
    var printerID: Int? { scsi.firstIndex(of: .printer) }

    /// The printer driver looks for it at 4 first (Snow's manual, "Printing")
    var freePrinterID: Int? { freeSCSIID(preferring: [4, 5, 6, 2, 1, 0, 3]) }
}

extension EthernetLink: CaseIterable, Identifiable {
    public static let allCases: [EthernetLink] = [.down, .nat, .natHttpsStripping]
    public var id: Self { self }

    var label: String {
        switch self {
        case .down: "Not connected"
        case .nat: "NAT"
        case .natHttpsStripping: "NAT with HTTPS stripping"
        }
    }
}

/// The Ethernet controller, a DaynaPORT SCSI/Link, and how it connects
struct NetworkSection: View {
    @Binding var setup: MachineSetup

    private var isOn: Binding<Bool> {
        Binding(
            get: { setup.ethernetID != nil },
            set: { on in
                if on {
                    if setup.ethernetID == nil, let id = setup.freeEthernetID {
                        setup.scsi[id] = .ethernet
                    }
                } else if let id = setup.ethernetID {
                    setup.scsi[id] = .none
                }
            })
    }

    var body: some View {
        Section {
            Toggle(isOn: isOn) {
                Label {
                    Text("DaynaPORT SCSI/Link")
                    if let id = setup.ethernetID {
                        Text("SCSI ID \(id)")
                    }
                } icon: {
                    Image(systemName: "network")
                }
            }
            .disabled(setup.ethernetID == nil && setup.freeEthernetID == nil)
            if setup.ethernetID != nil {
                Picker("Connection", selection: $setup.ethernetLink) {
                    ForEach(EthernetLink.allCases) { link in
                        Text(link.label).tag(link)
                    }
                }
            }
        } header: {
            Text("Network")
        } footer: {
            if setup.ethernetID != nil {
                Text(footer)
                    .foregroundStyle(.secondary)
            } else if setup.freeSCSIID(preferring: Array(0..<MachineSetup.scsiTargets)) == nil {
                Text("Every SCSI ID is taken. Remove a drive to add Ethernet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: String {
        switch setup.ethernetLink {
        case .down:
            "The cable is unplugged."
        case .nat:
            "The emulated Mac reaches the internet through this Mac's connection. The gateway is 10.0.0.1."
        case .natHttpsStripping:
            "The emulated Mac reaches the internet through this Mac's connection and can visit HTTPS-only sites. Snow makes the secure connection for it. The gateway is 10.0.0.1."
        }
    }
}

/// The LaserWriter IISC, which saves what it prints to the Desktop
struct PrinterSection: View {
    @Binding var setup: MachineSetup

    private var isOn: Binding<Bool> {
        Binding(
            get: { setup.printerID != nil },
            set: { on in
                if on {
                    if setup.printerID == nil, let id = setup.freePrinterID {
                        setup.scsi[id] = .printer
                    }
                } else if let id = setup.printerID {
                    setup.scsi[id] = .none
                }
            })
    }

    var body: some View {
        Section {
            Toggle(isOn: isOn) {
                Label {
                    Text("LaserWriter IISC")
                    if let id = setup.printerID {
                        Text("SCSI ID \(id)")
                    }
                } icon: {
                    Image(systemName: "printer")
                }
            }
            .disabled(setup.printerID == nil && setup.freePrinterID == nil)
            if setup.printerID != nil {
                LabeledContent("Saves pages to") {
                    Button("Desktop") {
                        NSWorkspace.shared.open(URL.desktopDirectory)
                    }
                    .help("Each page is saved as a PNG image, named after when it was printed")
                }
            }
        } header: {
            Text("Printer")
        } footer: {
            if setup.printerID != nil {
                Text("Choose LaserWriter IISC or Personal LaserWriter SC in the Chooser, using the driver that came with the Mac's system software.")
                    .foregroundStyle(.secondary)
            } else if setup.freePrinterID == nil {
                Text("Every SCSI ID is taken. Remove a drive to add the printer.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
