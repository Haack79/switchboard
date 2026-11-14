import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

extension Service {
  /// Adds a session to the service and to the store, paused by the user when `paused` is true.
  fileprivate func addSession(_ id: String, paused: Bool) throws {
    var s = Session(id: id, name: "t", cwd: "/tmp", branch: nil, claudeSessionId: "c-\(id)", model: nil, created: 0)
    if paused { s.pause = Pause(by: .you, since: 1) }
    try store.save(s)
    queue.sync { entries[id] = Entry(session: s) }
  }
}

/// `requireStartable` refuses a paused session even when the caller has no pause check of its own. Every sb
/// command checks the pause before it reaches a launch, so only these tests reach the refusal.
@Suite struct PauseStartGateTests {
  static func expectPauseRefusal(_ error: APIError?) {
    let text = error?.description ?? "no error"
    #expect(text.contains("Paused by you"), "\(text)")
    #expect(text.contains("Resume it with: sb resume s1"), "\(text)")
  }

  @Test func requireStartableRefusesAPausedSession() throws {
    try withService { service, _ in
      try service.addSession("s1", paused: true)

      let error = #expect(throws: APIError.self) { try service.queue.sync { try service.requireStartable("s1") } }

      Self.expectPauseRefusal(error)
    }
  }

  @Test func requireStartableAcceptsTheSameSessionUnpaused() throws {
    try withService { service, _ in
      try service.addSession("s1", paused: false)

      #expect(throws: Never.self) { try service.queue.sync { try service.requireStartable("s1") } }
    }
  }

  /// With the live cap full, `launch` would queue the start. The refusal comes first, so no start queues.
  @Test func launchWithTheCapFullQueuesNoStartForAPausedSession() throws {
    try withService { service, _ in
      try service.addSession("s1", paused: true)
      service.queue.sync { service.liveCap = 0 }

      let error = #expect(throws: APIError.self) {
        try service.queue.sync { try service.launch("s1", prompt: nil, trigger: .pending) }
      }

      Self.expectPauseRefusal(error)
      #expect(service.queue.sync { service.entries["s1"]?.queuedSince } == nil)
    }
  }
}

/// A new wait or pause condition draws its id from `waitIds`. An ordinary wait with the condition's id would end
/// the pause when it resolved.
@Suite struct PauseConditionIdTests {
  @Test func theTakenIdsHoldTheOpenWaitsAndThePauseCondition() throws {
    try withService { service, _ in
      try service.addSession("s1", paused: true)
      try service.queue.sync {
        try service.update("s1") { s in
          s.waits = [Wait(id: "wa", kind: .ci, created: 0)]
          s.pause?.until = Wait(id: "wb", kind: .date, until: 10, created: 0)
        }
      }

      #expect(service.queue.sync { service.waitIds("s1") } == ["wa", "wb"])
    }
  }
}
