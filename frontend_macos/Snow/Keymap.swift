import AppKit

/// Translation of macOS virtual keycodes (`NSEvent.keyCode`) to 'Snow universal'
/// scancodes, which are those of the Apple Extended Keyboard M0115.
///
/// macOS keycodes descend from the ADB scancodes, so most keys map to themselves.
/// Only modifiers and arrow keys are numbered differently.
enum Keymap {
    static func scancode(forKeyCode keyCode: UInt16) -> UInt8? {
        switch keyCode {
        case 0x36: 0x37 // Right Command -> Command
        case 0x37: 0x37 // Command
        case 0x38: 0x38 // Shift
        case 0x39: 0x39 // Caps Lock
        case 0x3A: 0x3A // Option
        case 0x3B: 0x36 // Control
        case 0x3C: 0x7B // Right Shift
        case 0x3D: 0x7C // Right Option
        case 0x3E: 0x7D // Right Control
        case 0x3F: nil // fn
        case 0x48, 0x49, 0x4A: nil // Volume up/down, mute
        case 0x7B: 0x3B // Left arrow
        case 0x7C: 0x3C // Right arrow
        case 0x7D: 0x3D // Down arrow
        case 0x7E: 0x3E // Up arrow
        case 0x00...0x7A: UInt8(keyCode)
        default: nil
        }
    }

    /// Whether a modifier key is down after a `flagsChanged` event for it, or nil if
    /// the event is not for a modifier key.
    static func modifierIsDown(_ event: NSEvent) -> Bool? {
        // Device-dependent flags tell the left and right keys apart (IOKit's NX_DEVICE*KEYMASK)
        let raw = event.modifierFlags.rawValue
        let mask: UInt
        switch event.keyCode {
        case 0x3B: mask = 0x0001 // Left Control
        case 0x38: mask = 0x0002 // Left Shift
        case 0x3C: mask = 0x0004 // Right Shift
        case 0x37: mask = 0x0008 // Left Command
        case 0x36: mask = 0x0010 // Right Command
        case 0x3A: mask = 0x0020 // Left Option
        case 0x3D: mask = 0x0040 // Right Option
        case 0x3E: mask = 0x2000 // Right Control
        case 0x39: return event.modifierFlags.contains(.capsLock)
        default: return nil
        }
        return raw & mask != 0
    }
}
