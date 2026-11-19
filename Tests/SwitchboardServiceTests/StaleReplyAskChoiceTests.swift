import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

private let head = "abc123"

private func readyToMergePR() -> PullRequest {
  var pr = PullRequest(
    id: "PR_42", number: 42, url: "https://github.com/acme/widgets/pull/42", repo: "acme/widgets", head: "feature",
    headSha: head, reviewDecision: .approved,
    verdicts: [Review(author: "alice", state: "APPROVED", submittedAt: "2026-10-25T00:00:00Z", commit: head)],
    checks: "SUCCESS", reviewRequests: [], trunkConfig: false, reviewDecisionRead: true, mergeQueue: false)
  pr.codeOwnerRequests = []
  pr.mergeDetails = MergeDetails()
  return pr
}

private func event(_ kind: String, _ t: Int64, _ fields: [String: JSON] = [:]) -> Event {
  Event(session: "s1", t: t, kind: kind, data: .object(fields))
}

private func stop(_ t: Int64, _ reply: String) -> Event {
  event("Stop", t, ["last_assistant_message": .string(reply)])
}

extension Service {
  fileprivate func apply(_ events: [Event], to id: String) {
    queue.sync { for e in events { entries[id]!.facts.apply(e) } }
  }

  fileprivate func shownItem(_ id: String) throws -> TriageItem {
    try queue.sync { try #require(summary(id).triage) }
  }
}

@Suite struct StaleReplyAskChoiceTests {
  /// The card shows Yes, No, Merge #42, and Acknowledge. A later Stop that asks nothing leaves Merge first, so the
  /// still-shown Yes would send option 1 to Merge.
  @Test func aChoiceMadeAgainstTheAskIsRefusedOnceTheAskIsGone() throws {
    try withService { service, _ in
      try service.addLive("s1", name: "s1")
      service.apply(
        [
          event("UserPromptSubmit", 1, ["prompt": "go"]), stop(2, "I pushed the fix.\n\nWant me to push the tag too?"),
          event("pr", 3, ["pr": try JSON(encoding: readyToMergePR()), "comments": []]),
        ], to: "s1")
      let shown = try service.shownItem("s1")
      try #require(shown.source == .rule)
      try #require(
        shown.options.map(\.label) == ["Yes", "No", "Merge #42", "Acknowledge"], "\(shown.options.map(\.label))")

      service.apply([event("UserPromptSubmit", 4, ["prompt": "go on"]), stop(5, "Done.")], to: "s1")
      let now = try service.shownItem("s1")
      try #require(now.options.map(\.label) == ["Merge #42", "Acknowledge"], "\(now.options.map(\.label))")

      let response = service.handle(
        Request(op: "choose", args: ["session": "s1", "ref": .string(shown.ref), "option": "1"]))

      #expect(!response.ok)
      #expect(response.error?.contains("new item since you looked") == true, "\(response.error ?? "answered")")
    }
  }

  @Test func aChoiceMadeAgainstTheItemWithoutAnAskIsRefusedOnceTheAskAppears() throws {
    try withService { service, _ in
      try service.addLive("s1", name: "s1")
      service.apply(
        [
          event("UserPromptSubmit", 1, ["prompt": "go"]), stop(2, "Done."),
          event("pr", 3, ["pr": try JSON(encoding: readyToMergePR()), "comments": []]),
        ], to: "s1")
      let shown = try service.shownItem("s1")

      service.apply(
        [event("UserPromptSubmit", 4, ["prompt": "go on"]), stop(5, "Pushed.\n\nWant me to push the tag too?")],
        to: "s1")
      try #require(try service.shownItem("s1").options.first?.label == "Yes")

      let response = service.handle(
        Request(op: "choose", args: ["session": "s1", "ref": .string(shown.ref), "option": "1"]))

      #expect(!response.ok)
    }
  }

  @Test func theSameAskKeepsTheSameRef() throws {
    try withService { service, _ in
      try service.addLive("s1", name: "s1")
      service.apply(
        [
          event("UserPromptSubmit", 1, ["prompt": "go"]), stop(2, "Pushed.\n\nWant me to push the tag too?"),
          event("pr", 3, ["pr": try JSON(encoding: readyToMergePR()), "comments": []]),
        ], to: "s1")
      let first = try service.shownItem("s1")

      let second = try service.shownItem("s1")

      #expect(first.ref == second.ref)
    }
  }
}
