import Foundation
import Testing

@testable import SwitchboardCore

/// The fields of a `GitHubRef`, which a test can build for any form. `GitHubRef`'s own initializer builds only a
/// shorthand.
struct GitHubRefFields: Sendable, Equatable {
  let repo: String
  let number: Int
  let form: GitHubRef.Form

  init(_ repo: String, _ number: Int, _ form: GitHubRef.Form) {
    self.repo = repo
    self.number = number
    self.form = form
  }

  init(_ ref: GitHubRef) {
    self.init(ref.repo, ref.number, ref.form)
  }
}

/// One input and what each parser reads from it. Nil means the parser refuses the input.
struct GitHubRefParseRow: Sendable, CustomTestStringConvertible {
  let text: String
  let issue: IssueRef?
  let pull: Wait.PullRequest?
  let ref: GitHubRefFields?

  init(_ text: String, issue: IssueRef?, pull: Wait.PullRequest?, ref: GitHubRefFields?) {
    self.text = text
    self.issue = issue
    self.pull = pull
    self.ref = ref
  }

  var testDescription: String { text.debugDescription }
}

private let posthog = "PostHog/posthog"
private let site = "https://github.com/PostHog/posthog"

private func issue(_ number: Int, _ repo: String? = posthog) -> IssueRef { IssueRef(repo: repo, number: number) }
private func pull(_ number: Int, _ repo: String? = posthog) -> Wait.PullRequest {
  Wait.PullRequest(repository: repo, number: number)
}
private func shorthand(_ number: Int, _ repo: String = posthog) -> GitHubRefFields {
  GitHubRefFields(repo, number, .shorthand)
}
private func issueURL(_ number: Int) -> GitHubRefFields { GitHubRefFields(posthog, number, .issueURL) }
private func pullURL(_ number: Int) -> GitHubRefFields { GitHubRefFields(posthog, number, .pullURL) }

@Suite struct GitHubRefTests {
  static let accepted: [GitHubRefParseRow] = [
    .init("123", issue: issue(123, nil), pull: pull(123, nil), ref: nil),
    .init("#123", issue: issue(123, nil), pull: pull(123, nil), ref: nil),
    .init("999999999", issue: issue(999_999_999, nil), pull: pull(999_999_999, nil), ref: nil),
    .init("pr:123", issue: nil, pull: pull(123, nil), ref: nil),
    .init("pr:#123", issue: nil, pull: pull(123, nil), ref: nil),
    .init("pr:PostHog/posthog#123", issue: nil, pull: pull(123), ref: nil),
    .init("PostHog/posthog#123", issue: issue(123), pull: pull(123), ref: shorthand(123)),
    .init("PostHog/posthog#012", issue: issue(12), pull: pull(12), ref: shorthand(12)),
    .init("PostHog/posthog#999999999", issue: issue(999_999_999), pull: pull(999_999_999), ref: shorthand(999_999_999)),
    .init("o-x/r_y.z#1", issue: issue(1, "o-x/r_y.z"), pull: pull(1, "o-x/r_y.z"), ref: shorthand(1, "o-x/r_y.z")),
    .init("1/2#3", issue: issue(3, "1/2"), pull: pull(3, "1/2"), ref: shorthand(3, "1/2")),

    .init("\(site)/issues/123", issue: issue(123), pull: nil, ref: issueURL(123)),
    .init("\(site)/issues/123/", issue: issue(123), pull: nil, ref: issueURL(123)),
    .init("\(site)/issues/123/timeline", issue: issue(123), pull: nil, ref: issueURL(123)),
    .init("\(site)/issues/123?q=1", issue: issue(123), pull: nil, ref: issueURL(123)),
    .init("\(site)/issues/123#issuecomment-1", issue: issue(123), pull: nil, ref: issueURL(123)),
    .init("http://github.com/PostHog/posthog/issues/123", issue: issue(123), pull: nil, ref: issueURL(123)),
    .init("HTTPS://github.com/PostHog/posthog/issues/123", issue: issue(123), pull: nil, ref: issueURL(123)),
    .init("https://GITHUB.COM/PostHog/posthog/issues/123", issue: issue(123), pull: nil, ref: issueURL(123)),

    .init("\(site)/pull/1204", issue: nil, pull: pull(1204), ref: pullURL(1204)),
    .init("\(site)/pull/1204/files", issue: nil, pull: pull(1204), ref: pullURL(1204)),
    .init("\(site)/pull/1204/commits/abc123", issue: nil, pull: pull(1204), ref: pullURL(1204)),
    .init("\(site)/pull/1204?x=1", issue: nil, pull: pull(1204), ref: pullURL(1204)),
    .init("\(site)/pull/1204#discussion_r1", issue: nil, pull: pull(1204), ref: pullURL(1204)),
    .init("http://github.com/PostHog/posthog/pull/1204", issue: nil, pull: pull(1204), ref: pullURL(1204)),
    // Wait.PullRequest compares the scheme case-sensitively and keeps that answer.
    .init("HTTPS://github.com/PostHog/posthog/pull/1204", issue: nil, pull: nil, ref: pullURL(1204)),
    .init("https://GitHub.com/PostHog/posthog/pull/1204", issue: nil, pull: pull(1204), ref: pullURL(1204)),
    .init("Https://github.com/PostHog/posthog/pull/1204", issue: nil, pull: nil, ref: pullURL(1204)),
    .init("pr:\(site)/pull/1204", issue: nil, pull: pull(1204), ref: nil),

    .init("  PostHog/posthog#123  ", issue: issue(123), pull: pull(123), ref: shorthand(123)),
    .init("\t#123\t", issue: issue(123, nil), pull: pull(123, nil), ref: nil),
    .init("  \(site)/issues/123  ", issue: issue(123), pull: nil, ref: issueURL(123)),
    .init("  \(site)/pull/1204  ", issue: nil, pull: pull(1204), ref: pullURL(1204)),
  ]

  static let refused: [GitHubRefParseRow] = [
    "", "#", "abc", "0", "#0", "-1", "12a", "PostHog/posthog#", "PostHog/posthog#0", "PostHog/posthog#-3",
    "PostHog/posthog#12a", "/posthog#1", "PostHog/#1", "owner#1", "PostHog/posthog/x#1",
    "PostHog/posthog#99999999999999999999999", "PostHog/posthog#123\n",
    "\(site)/issues/", "\(site)/issues", "\(site)/issues/0", "\(site)/issues/abc", "\(site)/issues/1234567890",
    "\(site)/pull/", "\(site)/pull/0", "\(site)/pull/12a", "\(site)/pull/new/x", "\(site)/pulls/1",
    "\(site)/discussions/1", "https://github.com/PostHog/issues/123", "https://github.com/PostHog/pull/123",
    "https://gitlab.com/PostHog/posthog/issues/123", "https://gitlab.com/PostHog/posthog/pull/1204",
    "https://www.github.com/PostHog/posthog/issues/123", "https://www.github.com/PostHog/posthog/pull/1204",
    "https://github.com.evil.com/PostHog/posthog/pull/1204", "ftp://github.com/PostHog/posthog/issues/123",
    "file:///tmp/PostHog/posthog/issues/123", "https://example.com/page#12", "https://github.com/PostHog/posthog#1",
    "pr:\(site)/issues/123", "pr: 123", "pr: \(site)/pull/1204",
  ].map { GitHubRefParseRow($0, issue: nil, pull: nil, ref: nil) }

  /// Wait.PullRequest requires `Issues.validRepo` and at most 9 digits, as IssueRef does.
  static let tightened: [GitHubRefParseRow] = [
    "PostHog/posthog#1#2", "o/na me#1", "1234567890", "#1234567890", "pr:1234567890",
    "PostHog/posthog#1234567890", "\(site)/pull/1234567890", "https://github.com/Post%20Hog/posthog/pull/1",
    "pr: PostHog/posthog#1",
  ].map { GitHubRefParseRow($0, issue: nil, pull: nil, ref: nil) }

  static let rows = accepted + refused + tightened

  @Test(arguments: rows)
  func issueRefReadsTheTableValue(_ row: GitHubRefParseRow) {
    #expect(IssueRef(parsing: row.text) == row.issue)
  }

  @Test(arguments: rows)
  func pullRequestReadsTheTableValue(_ row: GitHubRefParseRow) {
    #expect(Wait.PullRequest(parsing: row.text) == row.pull)
  }

  @Test(arguments: rows)
  func gitHubRefReadsTheTableValue(_ row: GitHubRefParseRow) {
    #expect(GitHubRef(parsing: row.text).map(GitHubRefFields.init) == row.ref)
  }

  @Test(
    arguments: [
      ("\(site)/issues/123#issuecomment-1", issueURL(123)),
      ("\(site)/pull/1204/files", pullURL(1204)),
      ("http://github.com/PostHog/posthog/pull/1204", pullURL(1204)),
    ] as [(String, GitHubRefFields)])
  func urlInitReadsIssueAndPullURLs(_ link: String, _ expected: GitHubRefFields) {
    #expect(GitHubRef(url: link).map(GitHubRefFields.init) == expected)
  }

  @Test(arguments: [
    "PostHog/posthog#123", "#123", "123", "https://example.com/page#12", "https://example.com/#12",
    "\(site)/discussions/1", "\(site)/pull/new/x", "https://www.github.com/PostHog/posthog/pull/1204",
    "mailto:someone@example.com", "switchboard-session:seb4ec",
  ])
  func urlInitRefusesEverythingElse(_ link: String) {
    #expect(GitHubRef(url: link) == nil)
  }

  @Test(arguments: [
    "PostHog/posthog#123", "\(site)/issues/123", "\(site)/pull/123/files",
    "https://GitHub.com/POSTHOG/PostHog/pull/123",
  ])
  func keyIsTheLowercasedRepositoryAndNumber(_ text: String) throws {
    let ref = try #require(GitHubRef(parsing: text))

    #expect(ref.key == "posthog/posthog#123")
  }

  @Test(arguments: [
    ("PostHog/posthog#123", "https://github.com/PostHog/posthog/issues/123"),
    ("\(site)/issues/123#issuecomment-1", "https://github.com/PostHog/posthog/issues/123"),
    ("http://github.com/PostHog/posthog/issues/123", "https://github.com/PostHog/posthog/issues/123"),
    ("\(site)/pull/1204/files", "https://github.com/PostHog/posthog/pull/1204"),
    ("http://github.com/PostHog/posthog/pull/1204?x=1", "https://github.com/PostHog/posthog/pull/1204"),
  ])
  func urlIsBuiltFromTheValidatedPartsOverHTTPS(_ text: String, _ url: String) throws {
    let ref = try #require(GitHubRef(parsing: text))

    #expect("\(ref.url)" == url)
  }

  @Test(arguments: [
    ("\(site)/pull/1204", true), ("\(site)/issues/1204", false), ("PostHog/posthog#1204", false),
  ])
  func isPullIsTrueOnlyForAPullURL(_ text: String, _ isPull: Bool) throws {
    let ref = try #require(GitHubRef(parsing: text))

    #expect(ref.isPull == isPull)
  }
}
