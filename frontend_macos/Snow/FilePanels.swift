import AppKit
import UniformTypeIdentifiers

/// Open and save panels. ROMs and disk images come in many formats without
/// registered types, so the panels accept any file unless told otherwise.
@MainActor
enum FilePanels {
    /// The CD-ROM image formats the emulator reads
    static let discImageTypes = ["iso", "toast", "cue"]

    static func chooseFile(title: String, startingAt path: String = "", types extensions: [String] = []) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !extensions.isEmpty {
            panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        }
        if !path.isEmpty {
            panel.directoryURL = URL(filePath: path).deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseSaveLocation(title: String, name: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }
}
