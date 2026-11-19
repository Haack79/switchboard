import SwiftUI
import SwitchboardCore

/// The row in a Manager conversation's status strip that suggests ending it, with End Conversation… and a button
/// that dismisses the suggestion.
struct EndConversationHint: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary
  let hint: EndHint

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "lightbulb")
      Text(hint.text)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
      EndConversationButton(session: session)
        .labelStyle(.titleOnly)
        .fixedSize()
      Button("Dismiss", systemImage: "xmark") { model.dismissEndHint(session.id) }
        .labelStyle(.iconOnly)
        .help("Hide this suggestion until another spawned session is done or the context grows further")
    }
  }
}
