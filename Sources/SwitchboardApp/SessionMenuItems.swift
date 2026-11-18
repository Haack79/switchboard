import AppKit
import SwiftUI
import SwitchboardCore

/// The items that every session context menu starts with.
struct SessionMenuItems: View {
  let session: SessionSummary

  var body: some View {
    HighlightMenuItem(session: session)
    SnoozeMenuItems(session: session)
    CopyLinkMenuItem(session: session)
  }
}

/// Copy Link: the session's id link as a Markdown link labeled with its name.
struct CopyLinkMenuItem: View {
  let session: SessionSummary

  static func copy(_ session: SessionSummary, to pasteboard: NSPasteboard = .general) {
    DraftCopy.copy(SessionLink.markdown(name: session.name, id: session.id), to: pasteboard)
  }

  var body: some View {
    Button("Copy Link") { Self.copy(session) }
  }
}
