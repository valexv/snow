import AppKit
import SwiftUI

@main
struct SnowApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Snow", id: "main") {
            ContentView()
                .environment(appDelegate.emulator)
        }
        .defaultSize(width: 1180, height: 800)
        .commands { SnowCommands(emulator: appDelegate.emulator) }
    }
}

/// Suspends the running machine before the app quits, so it resumes at the next launch
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let emulator = EmulatorModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard emulator.isActive || emulator.isBusy else { return .terminateNow }
        Task {
            await emulator.suspendForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// While the guest has the keyboard, it receives every key except Control-Command
/// combinations, so the machine's shortcuts use those.
private struct SnowCommands: Commands {
    let emulator: EmulatorModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Macintosh…") { emulator.showsNewMachine = true }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(emulator.isBusy)
            Button("Import Snow Workspace…") {
                if let url = FilePanels.chooseFile(title: "Import Snow Workspace", types: ["snoww"]) {
                    Task { await emulator.importWorkspace(from: url) }
                }
            }
            .disabled(emulator.isBusy)
            Divider()
            Button("Export State…") {
                let name = "\(emulator.current?.name ?? "Snow").snows"
                if let url = FilePanels.chooseSaveLocation(title: "Export State", name: name) {
                    emulator.exportState(to: url)
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(!emulator.isActive)
        }

        CommandMenu("Emulation") {
            if emulator.isActive {
                Button(emulator.isRunning ? "Pause" : "Run") { emulator.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .control])
                Button("Reset") { emulator.reset() }
                    .keyboardShortcut("r", modifiers: [.command, .control])
                Button("Programmer's Key") { emulator.programmerKey() }
                Divider()
                Picker(
                    "Speed",
                    selection: Binding(get: { emulator.speed }, set: { emulator.setSpeed($0) })
                ) {
                    ForEach(EmulationSpeed.allCases) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                Divider()
                Button("Power Off") { Task { await emulator.powerOff() } }
                    .keyboardShortcut("q", modifiers: [.command, .control])
                    .disabled(emulator.isBusy)
            } else if let current = emulator.current {
                if current.hasSavedState {
                    Button("Resume") { Task { await emulator.resume() } }
                        .keyboardShortcut("r", modifiers: [.command, .control])
                    Button("Start Fresh") { Task { await emulator.startFresh() } }
                } else {
                    Button("Start") { Task { await emulator.startFresh() } }
                        .keyboardShortcut("r", modifiers: [.command, .control])
                }
            }
        }

        CommandGroup(after: .sidebar) {
            Button(emulator.showsInspector ? "Hide Settings" : "Show Settings") {
                emulator.showsInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .control])
        }

        CommandMenu("Drives") {
            ForEach(emulator.floppies.filter(\.present)) { drive in
                Section("Floppy \(drive.drive + 1)") {
                    Button("Insert Disk…") {
                        if let url = FilePanels.chooseFile(title: "Insert Floppy Disk") {
                            emulator.insertFloppy(drive: drive.drive, url: url)
                        }
                    }
                    .disabled(drive.inserted)
                    Button(drive.inserted ? "Force Eject “\(drive.title)”" : "Force Eject") {
                        emulator.ejectFloppy(drive: drive.drive)
                    }
                    .disabled(!drive.inserted)
                }
            }
            // Only the guest ejects a disc, so a drive takes one while it's empty
            ForEach(emulator.cdromDrives, id: \.title) { title, drive in
                let disc = drive?.discPath ?? drive?.managedFolder
                Section(title) {
                    Button("Insert Disc Image…") {
                        if let url = FilePanels.chooseFile(
                            title: "Insert Disc Image", types: FilePanels.discImageTypes)
                        {
                            emulator.insertDisc(.image(path: url.filePath), drive: drive.map { Int($0.id) })
                        }
                    }
                    .disabled(disc != nil)
                    Button("Insert Folder as Disc…") {
                        if let url = FilePanels.chooseFolder(title: "Choose a Folder to Make into a Disc") {
                            emulator.insertDisc(.folder(path: url.filePath), drive: drive.map { Int($0.id) })
                        }
                    }
                    .disabled(disc != nil)
                    if let disc {
                        Button("Show “\(URL(filePath: disc).lastPathComponent)” in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: disc)])
                        }
                    }
                }
            }
        }
    }
}
