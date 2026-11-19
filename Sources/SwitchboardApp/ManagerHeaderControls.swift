import SwiftUI
import SwitchboardCore

/// The controls in a Manager conversation's header that the Operator and group chats don't show.
struct ManagerHeaderControls: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    Button("New Task", systemImage: "plus") { model.openNewSession(parent: session.id) }
      .help("Start a session that this conversation follows")
      .fixedSize()
  }
}
