import SwiftUI
import SwitchboardCore

/// The warning for a session whose folder moved off the branch it started on, or nothing.
struct BranchSwitchNote: View {
  let session: SessionSummary

  var body: some View {
    if let note = session.branchSwitchNote {
      CaptionNote(text: note, icon: "arrow.triangle.branch", style: .secondary)
    }
  }
}
