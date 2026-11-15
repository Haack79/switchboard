import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

extension Service {
  /// Holds `request` for card 7, then removes the card the way a fold does when its dialog leaves.
  fileprivate func holdAndRelease(_ request: HeldRequest) {
    queue.sync {
      held[7] = request
      releaseCards(request.session)
    }
  }

  fileprivate func kinds(_ session: String) throws -> [String] {
    try queue.sync { try store.events(session: session).map(\.kind) }
  }
}

/// A card can leave before the thread that holds its hook sees the hook close, as when the screen check
/// records `dialog_closed` right after Escape.
@Suite struct HeldRequestReleaseTests {
  @Test func aRequestWhoseHookIsGoneWhenItsCardLeavesStillRecordsCardClosed() throws {
    try withService { service, _ in
      try service.addLive("s1", name: "s1")
      let request = HeldRequest(session: "s1", hookGone: { true })

      service.holdAndRelease(request)
      let reply = service.awaitAnswer((7, request), else: ["unused": true]) { true }

      #expect(reply == [:])
      #expect(try service.kinds("s1") == ["card_closed"])
      #expect(service.queue.sync { service.held[7] == nil })
    }
  }

  @Test func aRequestWhoseHookIsOpenWhenItsCardLeavesGetsAnEmptyReplyAndRecordsNoCardClosed() throws {
    try withService { service, _ in
      try service.addLive("s1", name: "s1")
      let request = HeldRequest(session: "s1", hookGone: { false })

      service.holdAndRelease(request)
      var checked = false
      let reply = service.awaitAnswer((7, request), else: ["unused": true]) {
        checked = true
        return true
      }

      #expect(reply == [:])
      #expect(!checked)
      #expect(try service.kinds("s1").isEmpty)
      #expect(service.queue.sync { service.held[7] == nil })
    }
  }
}
