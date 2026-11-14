import SwiftUI

// The settings sections of the inspector, and the controls they share with the
// new machine sheet

// MARK: - Form sections

/// The emulated hardware: display ROMs, memory, CPU options, hard disks, CD-ROM
/// drives, Ethernet and the printer
struct MachineHardwareSections: View {
    @Binding var setup: MachineSetup
    /// The machine's folder, where new hard disks are made
    var folder: URL?

    private var model: ModelInfo? { setup.effectiveModel }

    var body: some View {
        if model != nil || ModelChoicePicker.offersChoice(of: setup) {
            Section("Hardware") {
                // The model, for a ROM more than one shares, and the display's ROM
                ModelChoicePicker(setup: $setup) {
                    setup.fitToModel()
                    setup.dropUnsupportedDisplayROM()
                    if setup.vramSize == nil {
                        setup.vramSize = setup.effectiveModel?.lowestVRAMSize
                    }
                }
                if model?.needsDisplayRom == true {
                    PathRow(
                        title: model?.hasDisplayCard == true ? "Display card ROM" : "Video ROM",
                        path: displayROMPath, choosesWhenEmpty: true)
                }
                // The card is the one its ROM belongs to, as in the new machine sheet
                if model?.hasDisplayCard == true,
                    case .card(let card) = identifyDisplayRom(path: setup.displayROMPath)
                {
                    LabeledContent("Display card", value: card.label)
                }

                if let model {
                    MemoryPicker(setup: $setup, model: model)

                    switch model.fpuOption {
                    case .coprocessor:
                        Toggle("68882 FPU", systemImage: "cpu", isOn: $setup.fpu)
                    case .cpu68040:
                        Picker("CPU", systemImage: "cpu", selection: $setup.fpu) {
                            Text("68LC040").tag(false)
                            Text("68040").tag(true)
                        }
                    case .none:
                        EmptyView()
                    }
                    if model.hasPmmuOption {
                        Toggle("68851 PMMU", systemImage: "cpu", isOn: $setup.pmmu)
                    }
                    if model.has800kFloppyOption {
                        Toggle("800K floppy drive", systemImage: "opticaldiscdrive", isOn: $setup.floppy800K)
                    }
                }
            }
        }

        // As in the new machine sheet, in two columns to fit the inspector
        if let model, !setup.monitorChoices.isEmpty {
            Section("Monitor") {
                MonitorGrid(setup: $setup, model: model, columnCount: 2)
            }
        }

        if model?.hasScsi == true {
            HardDisksSection(setup: $setup, folder: folder)
            CDROMSection(setup: $setup)
            NetworkSection(setup: $setup)
            PrinterSection(setup: $setup)
        }
    }

    /// Choosing a known display card ROM selects its card
    private var displayROMPath: Binding<String> {
        Binding(get: { setup.displayROMPath }, set: { setup.setDisplayROM($0) })
    }

}

/// The machine's model, as in the new machine sheet: its symbol, name and year, with
/// a button to change its ROM, which changes the model to the ROM's. Goes in a
/// section's header, as a form draws a box behind the rows of its sections.
struct MachineHeader: View {
    @Binding var setup: MachineSetup

    private var model: ModelInfo? { setup.effectiveModel }

    var body: some View {
        VStack(spacing: 4) {
            ModelSymbol(identifier: model?.identifier)
                .font(.system(size: 32))
                .foregroundStyle(.tint)
                .frame(height: 56)
            if let model {
                Text(model.name)
                    .font(.title2.weight(.bold))
                Text(model.specs.formFactorAndYear)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Unrecognized ROM")
                    .font(.title3.weight(.semibold))
                Text(setup.romPath.isEmpty
                    ? "Choose the ROM of a supported Macintosh."
                    : "Snow doesn't recognize “\(URL(filePath: setup.romPath).lastPathComponent)”. Choose the ROM of a supported Macintosh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Change ROM…", action: chooseROM)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .padding(.top, 6)
                .help(setup.romPath)
        }
        .multilineTextAlignment(.center)
        // Shown as a section header, which would make it secondary
        .foregroundStyle(.primary)
        .textCase(nil)
        .font(.body)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }

    private func chooseROM() {
        guard let url = FilePanels.chooseFile(title: "Choose a Macintosh ROM", startingAt: setup.romPath)
        else { return }
        setup.romPath = url.filePath
        // The model the ROM is detected as; one shared by models can be changed
        setup.model = ModelInfo.detect(romPath: setup.romPath)?.index
        setup.fitToModel()
        setup.dropUnsupportedDisplayROM()
        // Video memory the new model can't have starts at its least, as on a new
        // machine
        if setup.vramSize == nil {
            setup.vramSize = setup.effectiveModel?.lowestVRAMSize
        }
    }
}

/// The models the machine's ROM runs in, for a ROM that more than one model shares,
/// like the Macintosh II (FDHD), IIx, IIcx and SE/30's. Shows nothing for a ROM of
/// one model.
struct ModelChoicePicker: View {
    @Binding var setup: MachineSetup
    /// Called after the model changes, to fit the other settings to it
    let changed: () -> Void

    var body: some View {
        let models = ModelInfo.compatible(withROM: setup.romPath)
        if models.count > 1 {
            Picker("Model", systemImage: "apple.logo", selection: model) {
                ForEach(models) { model in
                    Text(model.name).tag(Optional(model.index))
                }
            }
            .help("This ROM runs in more than one model")
        }
    }

    /// The setup's ROM runs in more than one model, so the picker shows
    @MainActor
    static func offersChoice(of setup: MachineSetup) -> Bool {
        ModelInfo.compatible(withROM: setup.romPath).count > 1
    }

    private var model: Binding<UInt32?> {
        Binding(
            get: { setup.effectiveModel?.index },
            set: {
                guard $0 != setup.effectiveModel?.index else { return }
                setup.model = $0
                changed()
            })
    }
}

/// The amount of memory, from what the model can have, and the amount of video RAM
/// below it, for models where it can be chosen
struct MemoryPicker: View {
    @Binding var setup: MachineSetup
    let model: ModelInfo

    var body: some View {
        if model.ramSizes.count > 1 {
            Picker("Memory", systemImage: "memorychip", selection: size) {
                ForEach(model.ramSizes, id: \.self) { size in
                    Text(formatSize(size)).tag(size)
                }
            }
        } else {
            // The amount is fixed, so the same row shows it without a picker
            LabeledContent {
                Text(formatSize(model.defaultRamSize))
            } label: {
                Label("Memory", systemImage: "memorychip")
            }
        }

        if let defaultVRAMSize = model.defaultVramSize, !model.vramSizes.isEmpty {
            Picker("Video memory", systemImage: "memorychip.fill", selection: vramSize(or: defaultVRAMSize)) {
                ForEach(model.vramSizes, id: \.self) { size in
                    Text(formatSize(size)).tag(size)
                }
            }
        }
    }

    private var size: Binding<UInt64> {
        Binding(get: { setup.ramSize ?? model.defaultRamSize }, set: { setup.ramSize = $0 })
    }

    private func vramSize(or fallback: UInt64) -> Binding<UInt64> {
        Binding(get: { setup.vramSize ?? fallback }, set: { setup.vramSize = $0 })
    }
}

/// A size in bytes, like "512 KB", "80 MB" or "2 GB"
func formatSize(_ bytes: UInt64) -> String {
    let kb: UInt64 = 1024
    let mb = kb * 1024
    let gb = mb * 1024
    return switch bytes {
    case ..<mb: "\(bytes / kb) KB"
    case ..<gb: "\(bytes / mb) MB"
    default: bytes % gb == 0 ? "\(bytes / gb) GB" : String(format: "%.1f GB", Double(bytes) / Double(gb))
    }
}

/// A file setting: shows the file's name, with a menu to choose another
struct PathRow: View {
    let title: String
    @Binding var path: String
    var clearable = true
    /// Show a button to choose the file until one is chosen, instead of the menu
    var choosesWhenEmpty = false

    var body: some View {
        LabeledContent(title) {
            if choosesWhenEmpty, path.isEmpty {
                Button("Choose…", action: choose)
            } else {
                menu
            }
        }
    }

    private func choose() {
        if let url = FilePanels.chooseFile(title: "Choose \(title)", startingAt: path) {
            path = url.filePath
        }
    }

    private var menu: some View {
        Menu {
            Button("Choose…", action: choose)
            if !path.isEmpty {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                }
                if clearable {
                    Divider()
                    Button("Remove") { path = "" }
                }
            }
        } label: {
            Text(path.isEmpty ? "None" : URL(filePath: path).lastPathComponent)
                .truncationMode(.middle)
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(path)
    }
}
