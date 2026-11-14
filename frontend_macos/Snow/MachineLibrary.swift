import Foundation
import Observation

/// A machine the user has set up: a folder in Application Support holding a Snow
/// workspace, the machine's saved state and its PRAM.
///
///     Machines/<Name>/Machine.snoww   settings, also usable by the egui frontend
///     Machines/<Name>/State.snows     the state the machine was suspended in, if any
///     Machines/<Name>/PRAM.pram       PRAM contents
///     Machines/<Name>/<ROM>           copies of its ROM and display ROM, and of
///                                     ones it had before
struct MachineEntry: Identifiable, Hashable {
    let folder: URL
    /// Model name, for display
    var modelName: String
    var hasSavedState: Bool
    /// The model's identifier, like "Early128K", or nil if it's not known
    var modelIdentifier: String? = nil

    var id: URL { folder }
    var name: String { folder.lastPathComponent }
    var workspaceURL: URL { folder.appending(path: "Machine.snoww") }
    var stateURL: URL { folder.appending(path: "State.snows") }
    var pramURL: URL { folder.appending(path: "PRAM.pram") }
}

extension URL {
    var filePath: String { path(percentEncoded: false) }
}

/// What a machine is set up with, as edited in the setup sheet and the inspector
struct MachineSetup: Equatable {
    static let scsiTargets = 7

    var name = ""
    var romPath = ""
    /// Model index, or nil to detect it from the ROM
    var model: UInt32?
    var displayROMPath = ""
    var displayCard = DisplayCard.mdc824
    /// What's attached at each SCSI ID
    var scsi = [ScsiDevice](repeating: .none, count: scsiTargets)
    /// How an Ethernet controller connects. NAT, as in the egui frontend, until
    /// it's changed.
    var ethernetLink = EthernetLink.nat
    /// RAM size in bytes, or nil for the model's default
    var ramSize: UInt64?
    /// Video RAM size in bytes, or nil for the model's default
    var vramSize: UInt64?
    var fpu = false
    var pmmu = false
    var floppy800K = false
    /// The monitor connected, or nil for the model's default
    var monitor: Monitor?

    // These only affect how the machine starts, so changing them keeps a saved state
    var audio = true
    var keepPRAM = true

    init() {}

    init(name: String, config: MachineConfig) {
        self.name = name
        romPath = config.romPath
        model = config.model
        displayROMPath = config.displayRomPath ?? ""
        displayCard = config.displayCard
        scsi = (0..<Self.scsiTargets).map { id in
            id < config.scsiDevices.count ? config.scsiDevices[id] : .none
        }
        ethernetLink = config.ethernetLink
        ramSize = config.ramSize
        vramSize = config.vramSize
        fpu = config.fpu
        pmmu = config.pmmu
        floppy800K = config.floppy800k
        monitor = config.monitor
        audio = config.audio
        keepPRAM = config.pramPath != nil
    }

    var effectiveModel: ModelInfo? {
        if let model { ModelInfo.named(model) } else { ModelInfo.detect(romPath: romPath) }
    }

    /// Monitors that can be connected. Empty if there's no choice.
    var monitorChoices: [Monitor] {
        guard let model = effectiveModel else { return [] }
        // Only the Display Card 8•24 drives other monitors
        if model.hasDisplayCard, displayCard != .mdc824 { return [] }
        return model.monitors
    }

    /// Why the machine can't start with this setup, if it can't
    var problem: String? {
        if romPath.isEmpty { return "Choose a ROM." }
        guard let model = effectiveModel else { return "The ROM was not recognized. Choose the model." }
        if model.needsDisplayRom, displayROMPath.isEmpty {
            return model.hasDisplayCard ? "Choose a display card ROM." : "Choose a video ROM."
        }
        return nil
    }

    /// The emulated hardware, without the settings that only affect how it starts.
    /// A saved state only matches the hardware it was saved from. The discs in the
    /// CD-ROM drives and the Ethernet link aren't hardware: they can be changed as
    /// the machine runs.
    var hardware: MachineSetup {
        var hardware = self
        hardware.name = ""
        hardware.ethernetLink = .nat
        hardware.scsi = scsi.map { device in
            if case .cdrom = device { .cdrom(disc: nil) } else { device }
        }
        hardware.audio = true
        hardware.keepPRAM = true
        return hardware
    }

    /// This setup with the start settings of another
    func withStartSettings(of other: MachineSetup) -> MachineSetup {
        var setup = self
        setup.audio = other.audio
        setup.keepPRAM = other.keepPRAM
        setup.ethernetLink = other.ethernetLink
        for id in setup.scsi.indices {
            if case .cdrom = setup.scsi[id], case .cdrom(let disc) = other.scsi[id] {
                setup.scsi[id] = .cdrom(disc: disc)
            }
        }
        return setup
    }

    /// Sets the display ROM, and selects the display card it belongs to if it's a
    /// known one
    mutating func setDisplayROM(_ path: String) {
        displayROMPath = path
        if case .card(let card) = identifyDisplayRom(path: path) {
            displayCard = card
        }
        fitToModel()
    }

    /// Clears a display ROM the model can't use, after the model changed, so the
    /// user chooses another: a card ROM for the SE/30, the SE/30's video ROM for a
    /// display card, or one that isn't a known dump. Kept for models without one,
    /// which ignore it, in case the model changes back.
    mutating func dropUnsupportedDisplayROM() {
        guard let model = effectiveModel, model.needsDisplayRom, !displayROMPath.isEmpty
        else { return }
        switch identifyDisplayRom(path: displayROMPath) {
        case .card(let card) where model.hasDisplayCard:
            displayCard = card
        case .se30Video where !model.hasDisplayCard:
            break
        default:
            displayROMPath = ""
        }
    }

    /// Drops choices the model doesn't offer, after the model changed
    mutating func fitToModel() {
        guard let model = effectiveModel else { return }
        if let ramSize, !model.ramSizes.contains(ramSize) {
            self.ramSize = nil
        }
        if let vramSize, !model.vramSizes.contains(vramSize) {
            self.vramSize = nil
        }
        if !model.has800kFloppyOption {
            floppy800K = false
        }
        if let monitor, !monitorChoices.contains(monitor) {
            self.monitor = nil
        }
    }

    func config(pramURL: URL) -> MachineConfig {
        MachineConfig(
            romPath: romPath,
            model: model,
            displayRomPath: effectiveModel?.needsDisplayRom == true && !displayROMPath.isEmpty
                ? displayROMPath : nil,
            displayCard: displayCard,
            scsiDevices: scsi,
            ethernetLink: ethernetLink,
            pramPath: keepPRAM ? pramURL.filePath : nil,
            audio: audio,
            ramSize: ramSize,
            vramSize: vramSize,
            fpu: fpu,
            pmmu: pmmu,
            floppy800k: floppy800K,
            monitor: monitorChoices.isEmpty ? nil : monitor
        )
    }
}

/// The machines in Application Support
@MainActor
@Observable
final class MachineLibrary {
    static let root = URL.applicationSupportDirectory
        .appending(path: "Snow", directoryHint: .isDirectory)
        .appending(path: "Machines", directoryHint: .isDirectory)

    private(set) var machines: [MachineEntry] = []

    init() {
        reload()
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(
            at: Self.root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []

        machines = folders.compactMap { folder in
            let workspace = folder.appending(path: "Machine.snoww")
            guard fm.fileExists(atPath: workspace.filePath) else { return nil }
            let config = try? readWorkspace(path: workspace.filePath)
            let model = config.flatMap { MachineSetup(name: "", config: $0).effectiveModel }
            return MachineEntry(
                folder: folder,
                modelName: model?.name ?? "Unknown model",
                hasSavedState: fm.fileExists(atPath: folder.appending(path: "State.snows").filePath),
                modelIdentifier: model?.identifier
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func entry(_ id: MachineEntry.ID?) -> MachineEntry? {
        machines.first { $0.id == id }
    }

    func entry(named name: String) -> MachineEntry? {
        machines.first { $0.name == name }
    }

    // MARK: Changes

    /// Name of the hard disk image created with a machine, in its folder
    static let newDiskName = "Hard Disk.img"

    /// Creates a machine. With a disk size, it also gets a new blank hard disk of
    /// that many bytes at SCSI ID 0, kept in its folder.
    func create(_ setup: MachineSetup, newDiskSize: UInt64? = nil) throws -> MachineEntry {
        let folder = Self.root.appending(path: uniqueName(setup.name), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = MachineEntry(folder: folder, modelName: "", hasSavedState: false)
        do {
            var setup = try Self.withROMsCopied(setup, into: folder)
            if let newDiskSize {
                let disk = folder.appending(path: Self.newDiskName)
                try Self.createBlankDisk(at: disk, size: newDiskSize)
                setup.scsi[0] = .disk(path: disk.filePath)
            }
            try writeWorkspace(path: entry.workspaceURL.filePath, config: setup.config(pramURL: entry.pramURL))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return refreshed(entry)
    }

    /// Creates a blank disk image, as the egui frontend does. The file is sparse, so
    /// it takes no space until the guest writes to it.
    static func createBlankDisk(at url: URL, size: UInt64) throws {
        guard FileManager.default.createFile(atPath: url.filePath, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.filePath])
        }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: size)
    }

    /// Adds a machine from a workspace file made elsewhere, like in the egui frontend
    func importWorkspace(from url: URL) throws -> MachineEntry {
        let name = uniqueName(url.deletingPathExtension().lastPathComponent)
        let folder = Self.root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = MachineEntry(folder: folder, modelName: "", hasSavedState: false)
        do {
            try Snow.importWorkspace(source: url.filePath, destination: entry.workspaceURL.filePath)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return refreshed(entry)
    }

    func setup(of entry: MachineEntry) throws -> MachineSetup {
        MachineSetup(name: entry.name, config: try readWorkspace(path: entry.workspaceURL.filePath))
    }

    /// Saves a machine's settings, with copies of its ROMs in its folder. ROMs it had
    /// before stay there. Returns the settings as saved, with the copies' paths.
    func update(_ entry: MachineEntry, with setup: MachineSetup) throws
        -> (entry: MachineEntry, setup: MachineSetup)
    {
        let setup = try Self.withROMsCopied(setup, into: entry.folder)
        try writeWorkspace(path: entry.workspaceURL.filePath, config: setup.config(pramURL: entry.pramURL))
        return (refreshed(entry), setup)
    }

    // MARK: ROMs

    /// The setup with its ROM and display ROM copied into the folder, so the machine
    /// keeps working if the originals move. Files already in the folder stay as
    /// they are.
    static func withROMsCopied(_ setup: MachineSetup, into folder: URL) throws -> MachineSetup {
        var setup = setup
        setup.romPath = try copy(setup.romPath, into: folder)
        setup.displayROMPath = try copy(setup.displayROMPath, into: folder)
        return setup
    }

    /// Copies a file into the folder and returns the copy's path. A file in the
    /// folder already, or one the folder has an identical copy of, isn't copied
    /// again; a different file of the same name gets a number.
    private static func copy(_ path: String, into folder: URL) throws -> String {
        guard !path.isEmpty else { return path }
        let fm = FileManager.default
        let source = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        if source.deletingLastPathComponent().filePath == folder.filePath {
            return path
        }
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var n = 1
        while true {
            let numbered = n == 1 ? name : "\(name) \(n)"
            let destination = folder.appending(path: ext.isEmpty ? numbered : "\(numbered).\(ext)")
            if !fm.fileExists(atPath: destination.filePath) {
                try fm.copyItem(at: source, to: destination)
                return destination.filePath
            }
            if fm.contentsEqual(atPath: source.filePath, andPath: destination.filePath) {
                return destination.filePath
            }
            n += 1
        }
    }

    func rename(_ entry: MachineEntry, to name: String) throws -> MachineEntry {
        let name = Self.sanitized(name)
        guard name != entry.name else { return entry }
        let folder = Self.root.appending(path: uniqueName(name), directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: entry.folder, to: folder)
        return refreshed(MachineEntry(folder: folder, modelName: "", hasSavedState: false))
    }

    /// Moves the machine's folder to the Trash, with the ROMs and disks in it. Ones
    /// elsewhere stay.
    func delete(_ entry: MachineEntry) throws {
        try FileManager.default.trashItem(at: entry.folder, resultingItemURL: nil)
        reload()
    }

    func discardSavedState(of entry: MachineEntry) throws -> MachineEntry {
        if FileManager.default.fileExists(atPath: entry.stateURL.filePath) {
            try FileManager.default.removeItem(at: entry.stateURL)
        }
        return refreshed(entry)
    }

    /// Reloads the list and returns the up to date entry
    func refreshed(_ entry: MachineEntry) -> MachineEntry {
        reload()
        return self.entry(entry.id) ?? entry
    }

    // MARK: Names

    private static func sanitized(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.hasPrefix(".") ? String(cleaned.drop { $0 == "." }) : cleaned
        return trimmed.isEmpty ? "Macintosh" : trimmed
    }

    /// The name, or the name with a number if a machine already has it
    func uniqueName(_ name: String) -> String {
        let base = Self.sanitized(name)
        let taken = Set(machines.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}
