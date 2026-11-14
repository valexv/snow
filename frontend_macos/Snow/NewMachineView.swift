import SwiftUI

/// Sets up a new machine from a ROM, with a few basic options. Everything else can be
/// changed afterwards in the inspector.
struct NewMachineView: View {
    @Environment(EmulatorModel.self) private var emulator
    @Environment(\.dismiss) private var dismiss
    @State private var setup: MachineSetup
    /// Size of the hard disk to create with the machine, or nil for none
    @State private var diskSize: UInt64?
    @State private var choosingMonitor = false
    /// Height of the form's contents, so the sheet can fit them
    @State private var formHeight: CGFloat?
    /// What the chosen display ROM was identified as
    @State private var displayROM: DisplayRom?

    /// Height of the sheet while it asks for a ROM, as it was before it fitted the
    /// form's contents
    private static let promptHeight: CGFloat = 520

    static let mb: UInt64 = 1024 * 1024
    static let diskSizes: [UInt64] = [20, 40, 80, 160, 230, 400, 500, 1024].map { $0 * mb }

    /// - Parameter setup: what the sheet starts with, for previews
    init(setup: MachineSetup = MachineSetup()) {
        var setup = setup
        if setup.ramSize == nil {
            setup.ramSize = Self.lowestRAMSize(of: setup.effectiveModel)
        }
        if setup.vramSize == nil {
            setup.vramSize = setup.effectiveModel?.lowestVRAMSize
        }
        _setup = State(initialValue: setup)
        _diskSize = State(initialValue: Self.stockDiskSize(of: setup.effectiveModel))
    }

    /// New machines start with the least memory the model can have. The size is
    /// saved explicitly: without one, the core uses its own default, often the most.
    private static func lowestRAMSize(of model: ModelInfo?) -> UInt64? {
        model?.ramSizes.min()
    }

    /// The size of the hard disk the base model shipped with, if it had one
    private static func stockDiskSize(of model: ModelInfo?) -> UInt64? {
        guard let model, model.hasScsi, let size = model.specs.hardDiskSize else { return nil }
        return diskSizes.contains(size) ? size : nil
    }

    private var model: ModelInfo? { setup.effectiveModel }

    var body: some View {
        VStack(spacing: 0) {
            if model == nil {
                // No ROM yet, or one Snow doesn't recognize
                chooseROMPrompt
            } else {
                VStack() {
                    ModelSymbol(identifier: model?.identifier)
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                        .frame(height: 64)
                        .padding()
                    modelTitle
                    if let model {
                        Text(model.specs.formFactorAndYear)
                            .foregroundStyle(.tertiary)
                    }
                    Button("Change ROM…", action: chooseROM)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .padding(.top, 8)
                }
                .padding()
                Form {
                    machineSection
                    if let model {
                        Section() {
                            LabeledContent {
                                Text(model.specs.cpu) +
                                Text(" at \(model.specs.cpuSpeed)")
                            } label: {
                                Label("Processor", systemImage: "cpu")
                            }
                            MemoryPicker(setup: $setup, model: model)
                            LabeledContent {
                                Text(model.specs.floppies)
                            } label: {
                                Label("Floppy drive", systemImage: "opticaldiscdrive")
                            }
                            if model.hasScsi {
                                diskPicker
                            } else {
                                // No SCSI bus to attach one to
                                LabeledContent {
                                    Text("None")
                                } label: {
                                    Label("Hard disk", systemImage: "internaldrive")
                                }
                            }
                            monitorRow(model)
                        }
                    }
                }
                .formStyle(.grouped)
                // The sheet's background, rather than the form's own, which differs
                // from it in dark mode
                .scrollContentBackground(.hidden)
                .fittingContentHeight($formHeight, max: 560)
                .sheet(isPresented: $choosingMonitor) {
                    if let model {
                        MonitorChooser(setup: $setup, model: model)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if model != nil {
                    Button("Create") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(setup.problem != nil || displayROMProblem != nil)
                }
            }
            .padding()
        }
        // Once there's a form, as tall as the contents: the sheet grows and shrinks
        // with it
        .frame(width: 480, height: model == nil ? Self.promptHeight : nil)
    }

    // MARK: Sections

    /// Asks for a ROM, or for another one after one Snow didn't recognize
    private var chooseROMPrompt: some View {
        let unrecognized = !setup.romPath.isEmpty
        return VStack(spacing: 12) {
            Image(systemName: "snowflake")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(unrecognized ? "Unrecognized ROM" : "New Macintosh")
                .font(.title2.weight(.semibold))
            Group {
                if unrecognized {
                    Text("Snow doesn't recognize “\(URL(filePath: setup.romPath).lastPathComponent)”. Choose the ROM of a supported Macintosh.")
                } else {
                    Text("Choose the ROM of the Macintosh to emulate.")
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 300)
            Button("Choose ROM…", action: chooseROM)
                .prominentButtonStyle()
                .controlSize(.large)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The model detected from the ROM, as the sheet's title
    private var modelTitle: some View {
        Group {
            if let name = model?.name {
                Text(name)
                    .font(.title.weight(.bold))
                    .padding(.bottom, 1)
            } else {
                Text("Unrecognized ROM")
                    .font(.title2.weight(.semibold))
                    .padding()
            }
        }
    }

    /// The model, for a ROM more than one shares, and the display card ROM or video
    /// ROM, for models that need one. The display card is the one the ROM belongs to.
    private var machineSection: some View {
        Section {
            // For a ROM more than one model shares
            ModelChoicePicker(setup: $setup, changed: fitToModel)
            if let model, model.needsDisplayRom {
                PathRow(
                    title: model.hasDisplayCard ? "Display card ROM" : "Video ROM",
                    path: displayROMPath, clearable: false, choosesWhenEmpty: true)
                if model.hasDisplayCard, case .card(let card) = displayROM {
                    LabeledContent("Display card", value: card.label)
                }
            }
        } footer: {
            if let displayROMProblem {
                Label(displayROMProblem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Why the chosen display ROM can't be used, if it can't: it isn't a known dump
    /// of a display ROM for the model
    private var displayROMProblem: String? {
        guard let model, model.needsDisplayRom, !setup.displayROMPath.isEmpty else { return nil }
        switch displayROM {
        case .card where model.hasDisplayCard, .se30Video where !model.hasDisplayCard:
            return nil
        default:
            return model.hasDisplayCard
                ? "Snow doesn't recognize this display card ROM. Choose another one."
                : "Snow doesn't recognize this video ROM. Choose another one."
        }
    }

    /// The selected monitor, with a button to choose another. Models without a choice
    /// say why instead.
    private func monitorRow(_ model: ModelInfo) -> some View {
        LabeledContent {
            if !setup.monitorChoices.isEmpty {
                HStack {
                    if let monitor = setup.monitor ?? model.defaultMonitor {
                        Text(monitor.name)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Button("Change…") { choosingMonitor = true }
                }
            } else if model.hasDisplayCard {
                // Only the Display Card 8•24 drives a choice of monitors
                Text("Set by the display card")
            } else {
                // The compact Macs, the Portable and the SE/30
                Text("Built-in display")
            }
        } label: {
            Label("Monitor", systemImage: "display")
        }
    }

    /// The size of a new blank hard disk, or None
    private var diskPicker: some View {
        Picker("Hard disk", systemImage: "internaldrive", selection: $diskSize) {
            Text("None").tag(UInt64?.none)
            Divider()
            ForEach(Self.diskSizes, id: \.self) { size in
                Text(formatSize(size)).tag(Optional(size))
            }
        }
    }

    // MARK: Actions

    private func chooseROM() {
        guard let url = FilePanels.chooseFile(title: "Choose a Macintosh ROM", startingAt: setup.romPath)
        else { return }
        setup.romPath = url.filePath
        // Select the model the ROM is detected as; one shared by models can be
        // changed
        setup.model = ModelInfo.detect(romPath: setup.romPath)?.index
        fitToModel()
    }

    /// Starts the settings over for the model, as a new machine of it
    private func fitToModel() {
        setup.fitToModel()
        setup.dropUnsupportedDisplayROM()
        displayROM = identifyDisplayRom(path: setup.displayROMPath)
        setup.ramSize = Self.lowestRAMSize(of: model)
        setup.vramSize = model?.lowestVRAMSize
        // Start with the hard disk the model came with
        diskSize = Self.stockDiskSize(of: model)
    }

    private var displayROMPath: Binding<String> {
        Binding(
            get: { setup.displayROMPath },
            set: {
                setup.setDisplayROM($0)
                displayROM = identifyDisplayRom(path: $0)
            })
    }

    private func create() {
        var setup = setup
        setup.name = emulator.library.uniqueName(model?.name ?? "Macintosh")
        let newDiskSize = model?.hasScsi == true ? diskSize : nil
        dismiss()
        Task { await emulator.create(setup, newDiskSize: newDiskSize) }
    }
}

extension View {
    /// Sizes a scrolling view, like a form, to the height of its contents, up to a
    /// maximum past which it scrolls. A form otherwise has no height of its own, so a
    /// sheet showing one can't size itself to it. Needs macOS 15; before that, the
    /// view gets a fixed height and scrolls.
    @ViewBuilder
    func fittingContentHeight(_ height: Binding<CGFloat?>, max: CGFloat) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top
                    + geometry.contentInsets.bottom
            } action: { _, newHeight in
                height.wrappedValue = newHeight
            }
            .frame(height: height.wrappedValue.map { Swift.min($0, max) } ?? 300)
            // Everything shows, so there's nothing to scroll to, or bounce
            .scrollDisabled(fits(height.wrappedValue, max: max))
            .scrollIndicators(fits(height.wrappedValue, max: max) ? .never : .automatic)
        } else {
            frame(height: 360)
        }
    }

    private func fits(_ height: CGFloat?, max: CGFloat) -> Bool {
        height.map { $0 <= max } ?? false
    }

    /// The Liquid Glass prominent style on macOS 26 and later, and the bordered
    /// prominent style before it
    @ViewBuilder
    func prominentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// Chooses the monitor from a grid of the ones the model can drive
private struct MonitorChooser: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var setup: MachineSetup
    let model: ModelInfo
    /// The choice so far, kept until the user confirms it
    @State private var draft: MachineSetup

    init(setup: Binding<MachineSetup>, model: ModelInfo) {
        _setup = setup
        self.model = model
        _draft = State(initialValue: setup.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a Monitor")
                .font(.title2.weight(.semibold))
            MonitorGrid(setup: $draft, model: model)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose") {
                    setup.monitor = draft.monitor
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        // As tall as the grid needs: no model has more than six monitors, two rows
        .frame(width: 400)
    }
}

/// The monitors the model can drive, three to a row, or as many as given. Clicking
/// one selects it. Also in the inspector.
struct MonitorGrid: View {
    @Binding var setup: MachineSetup
    let model: ModelInfo
    var columnCount = 3

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columnCount)
    }

    var body: some View {
        let selected = setup.monitor ?? model.defaultMonitor
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(setup.monitorChoices) { monitor in
                MonitorTile(monitor: monitor, isSelected: monitor == selected) {
                    setup.monitor = monitor
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MonitorTile: View {
    let monitor: Monitor
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        Button(action: select) {
            VStack(spacing: 4) {
                Image(monitor.symbolName)
                    .font(.system(size: 36))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 60)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(monitor.name)
                    .font(.callout.weight(.medium))
                Text(monitor.resolution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(shape.fill(isSelected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear)))
            .overlay(
                shape.strokeBorder(
                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                    lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Choose a ROM") {
    NewMachineView()
        .environment(EmulatorModel(restoringSession: false))
}

/// The sheet as it is once a model's ROM is chosen, by the model's identifier
@MainActor
private func newMachinePreview(model identifier: String) -> some View {
    let model = ModelInfo.all.first { $0.identifier == identifier }
    var setup = MachineSetup()
    setup.romPath = "/ROMs/\(model?.name ?? identifier).rom"
    setup.model = model?.index
    return NewMachineView(setup: setup)
        .environment(EmulatorModel(restoringSession: false))
}

// One of each kind: compact Macs with no hard disk and with one, a display card,
// a built-in video ROM, built-in video with video RAM, and the Portable

#Preview("Macintosh 128K") { newMachinePreview(model: "Early128K") }

#Preview("Macintosh Plus") { newMachinePreview(model: "Plus") }

#Preview("Macintosh II") { newMachinePreview(model: "MacII") }

#Preview("Macintosh SE/30") { newMachinePreview(model: "SE30") }

#Preview("Macintosh LC III") { newMachinePreview(model: "MacIIcx") }

#Preview("Macintosh Quadra 700") { newMachinePreview(model: "Quadra700") }

#Preview("Macintosh Portable") { newMachinePreview(model: "Portable") }

/// The monitor chooser for a model, by its identifier
private struct MonitorChooserPreview: View {
    @State private var setup: MachineSetup
    private let model: ModelInfo?

    init(model identifier: String) {
        model = ModelInfo.all.first { $0.identifier == identifier }
        var setup = MachineSetup()
        setup.model = model?.index
        _setup = State(initialValue: setup)
    }

    var body: some View {
        if let model {
            MonitorChooser(setup: $setup, model: model)
        }
    }
}

#Preview("Monitors: Macintosh II") {
    MonitorChooserPreview(model: "MacII")
}

#Preview("Monitors: Quadra 700") {
    MonitorChooserPreview(model: "Quadra700")
}

#Preview("Monitors: LC 475") {
    MonitorChooserPreview(model: "LCIII")
}
