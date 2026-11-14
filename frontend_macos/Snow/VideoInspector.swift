import SwiftUI

/// How the selected machine's display is shown: scaling and the CRT effect. Changes
/// show at once, and are saved to the machine's workspace.
struct VideoSettingsForm: View {
    @Environment(EmulatorModel.self) private var emulator

    private var video: Binding<VideoSettings> {
        Binding(get: { emulator.video }, set: { emulator.setVideo($0) })
    }

    /// The machine's screen is a CRT: its built-in display or its monitor
    private var hasCRT: Bool { emulator.crtParameters != nil }

    /// The size of the machine's screen is known, so the display can be shown at it
    private var knowsRealSize: Bool { emulator.screenPixelsPerInch != nil }

    /// Shown at its real size, which takes over from the other scaling settings
    private var showsRealSize: Bool { knowsRealSize && video.wrappedValue.physicalSize }

    /// Off for a screen whose size isn't known, whatever the setting
    private var physicalSize: Binding<Bool> {
        Binding(
            get: { showsRealSize },
            set: { video.wrappedValue.physicalSize = $0 })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Real size", isOn: physicalSize)
                    .disabled(!knowsRealSize)
                Toggle("Scale to fit window", isOn: video.scaling)
                    .disabled(showsRealSize)
                Toggle("Integer scaling", isOn: video.integerScaling)
                    .disabled(showsRealSize || !video.wrappedValue.scaling)
                Picker("Algorithm", selection: video.scalingAlgorithm) {
                    ForEach(ScalingAlgorithm.allCases) { algorithm in
                        Text(algorithm.label).tag(algorithm)
                    }
                }
            } header: {
                VStack(spacing: 0) {
                    if let screen = emulator.screen {
                        ScreenHeader(
                            screen: screen, modelIdentifier: emulator.displayedEntry?.modelIdentifier)
                    }
                    Text("Scaling")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } footer: {
                Text(
                    knowsRealSize
                        ? "Real size scales the display to the same size as the original hardware, measured on this Mac's display."
                        : "The size of this Macintosh's screen isn't known, so it can't be shown at its real size."
                )
            }

            Section {
                Toggle("CRT effect", isOn: crtEffect)
                    .disabled(!hasCRT)
            } footer: {
                Text(
                    hasCRT
                        ? "Simulates the scanlines and dot mask of the selected display."
                        : "The seleted display isn't a CRT."
                )
            }
        }
        .formStyle(.grouped)
    }

    /// Off for a screen that isn't a CRT, whatever the setting
    private var crtEffect: Binding<Bool> {
        Binding(
            get: { hasCRT && video.wrappedValue.crtEffect },
            set: { video.wrappedValue.crtEffect = $0 })
    }
}

/// The machine's screen, as the machine tab's header shows the machine: its
/// monitor's symbol, or the machine's for a built-in display, its name and its
/// resolution. Goes in a section's header, as a form draws a box behind the rows
/// of its sections.
private struct ScreenHeader: View {
    let screen: ScreenInfo
    let modelIdentifier: String?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let monitor = screen.monitor {
                    Image(monitor.symbolName)
                        .symbolRenderingMode(.hierarchical)
                } else {
                    ModelSymbol(identifier: modelIdentifier)
                }
            }
            .font(.system(size: 32))
            .foregroundStyle(.tint)
            .frame(height: 56)
            Text(name)
                .font(.title2.weight(.bold))
            // Verbatim, so the numbers aren't grouped, as in "1,152"
            Text(verbatim: "\(screen.width) × \(screen.height), \(screen.color ? "Color" : "Black & White")")
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        // Shown as a section header, which would make it secondary
        .foregroundStyle(.primary)
        .textCase(nil)
        .font(.body)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    private var name: String {
        if let monitor = screen.monitor { return monitor.name }
        // Only the Portable's LCD isn't a CRT
        return screen.crtParameters == nil ? "Built-in LCD" : "Built-in Display"
    }
}
