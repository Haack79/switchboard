import AppKit
import SwitchboardCore

/// Which input in a stopped session's Claude terminal resumes the session.
enum TerminalWake {
  /// A mouse-up farther than this from its mouse-down is a drag, which selects text to copy.
  static let clickSlop: CGFloat = 4

  /// A key with ⌘ is a menu shortcut or a copy from the stopped screen, so it doesn't wake.
  static func wakes(key modifiers: NSEvent.ModifierFlags) -> Bool { !modifiers.contains(.command) }

  /// A ⌘-click opens a link.
  static func isClick(down: CGPoint, up: CGPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
    !modifiers.contains(.command) && hypot(up.x - down.x, up.y - down.y) <= clickSlop
  }
}

extension SessionSummary {
  /// A queued session waits for a live slot, and the header's Start Now starts it.
  var wakesOnTerminalInput: Bool { hasTerminals && !live && queued != true && !waitsToStart }
}
