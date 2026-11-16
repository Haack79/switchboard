import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

private func reviewEvent(_ review: DocketReview) -> Event {
  Event(session: "s1", t: 1, kind: "docket", data: .object(["review": try! JSON(encoding: review)]))
}

private func facts(_ events: [Event]) -> SessionFacts {
  var f = SessionFacts()
  for e in events { f.apply(e) }
  return f
}

@Suite struct DocketReviewDecoding {
  /// A Review as docket's list_reviews sends it, with keys that DocketReview leaves out.
  static let docketJSON = #"""
    {
      "pull_request": "PostHog/posthog#41234",
      "url": "https://github.com/PostHog/posthog/pull/41234",
      "title": "Fix the \"flag\" cache — again",
      "author": "someone",
      "state": "reviewing",
      "pr_state": "OPEN",
      "engine": "claude",
      "mode": "background",
      "started_at": "2026-11-04T10:00:00Z",
      "review_id": 3412345678,
      "submittable": false,
      "notes_path": "/Users/x/Library/Application Support/docket/notes/41234.md",
      "error": "",
      "progress": {
        "detail": "Reading \"Docket.swift\"\nthen tests",
        "waiting": true,
        "needs": "approve `git push`",
        "agents": 2,
        "updated_at": "2026-11-04T10:05:00Z"
      },
      "handoff": {"session": "abc"}
    }
    """#

  func decoded() throws -> DocketReview {
    try DocketClient.review(try #require(JSON.parse(DocketReviewDecoding.docketJSON)))
  }

  @Test func decodesSnakeCaseKeys() throws {
    let r = try decoded()

    #expect(r.pullRequest == "PostHog/posthog#41234")
    #expect(r.url == "https://github.com/PostHog/posthog/pull/41234")
    #expect(r.prState == "OPEN")
    #expect(r.notesPath == "/Users/x/Library/Application Support/docket/notes/41234.md")
  }

  @Test func decodesEscapedTextAndProgress() throws {
    let r = try decoded()

    #expect(r.title == "Fix the \"flag\" cache — again")
    #expect(r.progress?.detail == "Reading \"Docket.swift\"\nthen tests")
    #expect(r.progress?.waiting == true)
    #expect(r.progress?.needs == "approve `git push`")
  }

  @Test func decodesAMinimalReview() throws {
    let json = try #require(
      JSON.parse(#"{"pull_request": "o/r#1", "url": "https://github.com/o/r/pull/1", "state": "not_started"}"#))

    let r = try DocketClient.review(json)

    #expect(r == DocketReview(pullRequest: "o/r#1", url: "https://github.com/o/r/pull/1", state: "not_started"))
  }

  @Test func reviewsWhoseProgressDiffersOnlyInUpdatedAtOrAgentsAreEqual() throws {
    let later = DocketReviewDecoding.docketJSON.replacingOccurrences(
      of: "2026-11-04T10:05:00Z", with: "2026-11-04T10:06:00Z"
    ).replacingOccurrences(of: #""agents": 2"#, with: #""agents": 3"#)

    let second = try DocketClient.review(try #require(JSON.parse(later)))

    #expect(second == (try decoded()))
  }

  @Test func aDecodedReviewSurvivesTheEventLog() throws {
    let r = try decoded()

    let f = facts([reviewEvent(r)])

    #expect(f.docket.review == r)
  }
}
