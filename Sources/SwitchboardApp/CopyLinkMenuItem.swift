import AppKit
import SwiftUI
import SwitchboardCore

/// Copy Link: the session's id link as a Markdown link labeled with its name. It is disabled without a session.
struct CopyLinkMenuItem: View {
  let session: SessionSummary?

  static func copy(_ session: SessionSummary, to pasteboard: NSPasteboard = .general) {
    DraftCopy.copy(SessionLink.markdown(name: session.name, id: session.id), to: pasteboard)
  }

  var body: some View {
    Button("Copy Link") { session.map { Self.copy($0) } }
      .disabled(session == nil)
  }
}
