import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct LeftInboxBannerText {
  @Test func namesTheStateTheSessionMovedTo() {
    #expect(LeftInboxBanner.message(.working) == "Left the Inbox: \(AttentionState.working.title)")
  }
}
