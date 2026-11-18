import SwiftUI
import SwitchboardCore

/// The items that every session context menu starts with.
struct SessionMenuItems: View {
  let session: SessionSummary

  var body: some View {
    HighlightMenuItem(session: session)
    SnoozeMenuItems(session: session)
  }
}
