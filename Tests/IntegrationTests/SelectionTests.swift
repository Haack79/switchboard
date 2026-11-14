import SwitchboardCore
import Testing

@Suite struct SelectionProjection {
  let node: JSON

  init() throws {
    node = try #require(FakeGitHub.recorded("github-status.json").first)
  }

  @Test func statusQueryKeepsEverythingButTheBaseRef() throws {
    let selection = try #require(Selection(query: GitHub.statusQuery, on: "PullRequest"))
    for recorded in try FakeGitHub.recorded("github-status.json") {
      var expected = try #require(recorded.object)
      expected["baseRef"] = nil
      #expect(selection.project(recorded) == .object(expected))
    }
  }

  @Test func baseQueryKeepsOnlyTheBaseFields() throws {
    let selection = try #require(Selection(query: GitHub.baseQuery, on: "PullRequest"))
    let projected = try #require(selection.project(node).object)
    #expect(Set(projected.keys) == ["id", "baseRefName", "repository", "baseRef"])
    #expect(projected["repository"]?["defaultBranchRef"]?["name"] != nil)
    #expect(projected["repository"]?["nameWithOwner"] == nil)
    #expect(projected["baseRef"]?["associatedPullRequests"]?["nodes"]?.array?.first?["number"] != nil)
  }

  @Test func aSelectedFieldTheNodeLacksStaysAbsent() throws {
    let selection = try #require(Selection(query: "{ ... on PullRequest { id missing } }", on: "PullRequest"))
    #expect(selection.project(["id": "x", "extra": 1]) == ["id": "x"])
  }

  static let directiveQuery = """
    query($ids: [ID!]!, $on: Boolean!) {
      nodes(ids: $ids) {
        ... on PullRequest { id a: comments(first: 1) @include(if: $on) { nodes { body } } b @skip(if: $on) c }
      }
    }
    """

  static let directiveNode: JSON = ["id": "x", "a": ["nodes": [["body": "hi", "url": "u"]]], "b": 2, "c": 3]

  @Test func includeKeepsItsFieldWhenTheVariableIsTrue() throws {
    let selection = try #require(Selection(query: Self.directiveQuery, on: "PullRequest", variables: ["on": true]))
    #expect(selection.project(Self.directiveNode) == ["id": "x", "a": ["nodes": [["body": "hi"]]], "c": 3])
  }

  @Test func skipKeepsItsFieldWhenTheVariableIsFalse() throws {
    let selection = try #require(Selection(query: Self.directiveQuery, on: "PullRequest", variables: ["on": false]))
    #expect(selection.project(Self.directiveNode) == ["id": "x", "b": 2, "c": 3])
  }

  @Test func aDirectiveVariableTheRequestLacksIsFalse() throws {
    let selection = try #require(Selection(query: Self.directiveQuery, on: "PullRequest"))
    #expect(selection.project(Self.directiveNode) == ["id": "x", "b": 2, "c": 3])
  }

  /// A thread as FakeGitHub.reviewThreads(_:details:) stores it.
  static let threadNode: JSON = [
    "isResolved": false, "isOutdated": false, "path": "a.swift", "line": 3, "originalLine": 3,
    "first": [
      "nodes": [["url": "https://github.com/o/r/pull/1#discussion_r9", "body": "b", "author": ["login": "x"]]]
    ],
    "last": ["totalCount": 1, "nodes": [["viewerDidAuthor": false]]],
  ]

  @Test func mergeDetailsQueryWithoutThreadsDropsTheThreadComments() throws {
    let selection = try #require(
      Selection(query: GitHub.mergeDetailsQuery, on: "PullRequest", variables: ["threads": false]))

    let projected = selection.project(["reviewThreads": ["totalCount": 1, "nodes": [Self.threadNode]]])

    let thread = try #require(projected["reviewThreads"]?["nodes"]?.array?.first)
    #expect(projected["reviewThreads"]?["totalCount"] == 1)
    #expect(thread["isResolved"] == false)
    #expect(thread["first"] == nil)
    #expect(thread["last"] == nil)
  }

  @Test func mergeDetailsQueryWithThreadsKeepsTheThreadComments() throws {
    let selection = try #require(
      Selection(query: GitHub.mergeDetailsQuery, on: "PullRequest", variables: ["threads": true]))

    let projected = selection.project(["reviewThreads": ["totalCount": 1, "nodes": [Self.threadNode]]])

    let thread = try #require(projected["reviewThreads"]?["nodes"]?.array?.first)
    #expect(thread["first"]?["nodes"]?.array?.first?["url"] == "https://github.com/o/r/pull/1#discussion_r9")
    #expect(thread["last"]?["nodes"]?.array?.first?["viewerDidAuthor"] == false)
    #expect(thread["path"] == "a.swift")
  }
}
