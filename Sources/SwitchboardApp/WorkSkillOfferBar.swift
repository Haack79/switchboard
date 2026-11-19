import SwiftUI
import SwitchboardCore

/// The choice that a Manager conversation's or the operator's pane shows in place of sending a work skill's command.
struct WorkSkillOfferBar: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  static let spawnTitle = "Spawn a session with this"
  static let runHereTitle = "Run here anyway"
  static let cancelTitle = "Cancel"

  static func message(skill: String) -> String {
    "/\(skill) is a work skill. A Manager conversation pays for its text on every later turn."
  }

  var body: some View {
    if let offer = model.workSkillOffers[session.id] {
      let message = Self.message(skill: offer.skill)
      VStack(alignment: .leading, spacing: 6) {
        Text(message).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Button(Self.spawnTitle) { model.spawnFromOffer(session.id) }
            .help("Open New Session with this message as the first prompt")
          Button(Self.runHereTitle) { model.runHereAnyway(session.id, draft: model.messageDraft(for: session)) }
            .help("Send this message to \(session.name) once, past the work-skill check")
          Button(Self.cancelTitle) { model.dismissOffer(session.id) }
          Spacer()
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(Color.secondary.opacity(0.08))
      .onAppear { AccessibilityNotification.Announcement(message).post() }
    }
  }
}
