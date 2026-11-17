import Foundation
import Testing

@testable import SwitchboardCore

/// Fixtures/prs holds real PR bodies. posthog-133856.md is the body of
/// PostHog/posthog#133856 on 2026-11-11, from
/// `gh pr view 133856 -R PostHog/posthog --json body -q .body`.
private func prBody(_ name: String) throws -> String {
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/prs/\(name)")
  return try String(contentsOf: url, encoding: .utf8)
}

private let title133856 = "fix(flags): let siblings decide cohorts with unsupported group types"
private let head133856 = "8d0fdba9ba58d5eba512a7b2905fffc22ed5c4c4"

/// PostHog's PR template as an author leaves it: each section holds only
/// the template's HTML comment.
private let templateBody = """
  ## Problem

  <!-- Who are we building for, what are their needs, why is this important? -->

  ## Changes

  <!-- If there are frontend changes, please include screenshots. -->
  <!-- If a reference design was involved, include a link to the relevant Figma frame! -->

  ## How did you test this code?

  <!-- Briefly describe the steps you took. Not run: anything you skipped? -->
  <!--
  - [ ] Ran the unit tests
  - [ ] Ran the e2e suite
  -->

  ## Release status

  - [ ] Behind a feature flag <!-- release-status: flag -->
  """

/// A node of `GitHub.mergeDetailsQuery`'s response. `threads` gives each
/// review thread's `isResolved`, and nil gives a null node. `threadNodes`
/// replaces them with whole thread nodes. `reviews` gives the
/// `latestOpinionatedReviews` nodes and `commits` the oids of
/// `commits(last: 100)`, oldest first. Either is absent when nil.
private func detailsNode(
  id: JSON = "PR_kwDOJ6Ng5c7Bv2xQ", head: JSON = .string(head133856),
  title: String = title133856, body: String = "", additions: Int = 315, deletions: Int = 208, changedFiles: Int = 4,
  totalCount: Int? = nil, threads: [Bool?] = [], threadNodes: [JSON]? = nil, reviews: [JSON]? = nil,
  commits: [String]? = nil
) -> JSON {
  let nodes = threadNodes ?? threads.map { $0.map { ["isResolved": .bool($0)] } ?? .null }
  var reviewThreads: [String: JSON] = ["nodes": .array(nodes)]
  reviewThreads["totalCount"] = .number(Double(totalCount ?? nodes.count))
  var node: [String: JSON] = [
    "id": id, "headRefOid": head, "title": .string(title), "body": .string(body),
    "additions": .number(Double(additions)), "deletions": .number(Double(deletions)),
    "changedFiles": .number(Double(changedFiles)), "reviewThreads": .object(reviewThreads),
  ]
  if let reviews { node["latestOpinionatedReviews"] = ["nodes": .array(reviews)] }
  if let commits { node["commits"] = ["nodes": .array(commits.map { ["commit": ["oid": .string($0)]] })] }
  return .object(node)
}

private let pr133856 = "https://github.com/PostHog/posthog/pull/133856"

/// A review thread node as the merge details query reads it with
/// `threads: true`. `withComments: false` leaves out `first` and `last`, as
/// a read with `threads: false` does.
private func threadNode(
  resolved: Bool = false, outdated: Bool = false, path: String = "posthog/models/cohort.py", line: Int? = 42,
  originalLine: Int? = 40, author: String = "dmarticus", typename: String = "User",
  body: String = "Should this handle the empty group?", url: String = "\(pr133856)#discussion_r2512345678",
  comments: Int = 1, viewerWroteLast: Bool = false, withComments: Bool = true
) -> JSON {
  var node: [String: JSON] = [
    "isResolved": .bool(resolved), "isOutdated": .bool(outdated), "path": .string(path),
    "line": line.map { .number(Double($0)) } ?? .null,
    "originalLine": originalLine.map { .number(Double($0)) } ?? .null,
  ]
  if withComments {
    node["first"] = [
      "nodes": [
        [
          "url": .string(url), "body": .string(body),
          "author": ["__typename": .string(typename), "login": .string(author)],
        ]
      ]
    ]
    node["last"] = ["totalCount": .number(Double(comments)), "nodes": [["viewerDidAuthor": .bool(viewerWroteLast)]]]
  }
  return .object(node)
}

/// An inline comment node of a review.
private func noteNode(
  path: String = "posthog/models/cohort.py", line: Int? = 12, originalLine: Int? = 12, body: String = "Nit.",
  url: String = "\(pr133856)#discussion_r2600000001"
) -> JSON {
  [
    "path": .string(path), "line": line.map { .number(Double($0)) } ?? .null,
    "originalLine": originalLine.map { .number(Double($0)) } ?? .null, "body": .string(body), "url": .string(url),
  ]
}

/// A `latestOpinionatedReviews` node as the merge details query reads it.
private func reviewNode(
  author: String = "stamphog", typename: String = "User", state: String = "APPROVED", body: String = "Looks good.",
  url: String = "\(pr133856)#pullrequestreview-3400000001", commit: String? = head133856,
  notes: [JSON] = [], noteCount: Int? = nil
) -> JSON {
  [
    "author": ["__typename": .string(typename), "login": .string(author)], "state": .string(state),
    "body": .string(body), "url": .string(url), "submittedAt": "2026-11-11T10:00:00Z",
    "commit": commit.map { ["oid": .string($0)] } ?? .null,
    "comments": ["totalCount": .number(Double(noteCount ?? notes.count)), "nodes": .array(notes)],
  ]
}

private func removing(_ key: String, from node: JSON) -> JSON {
  var object = node.object ?? [:]
  object[key] = nil
  return .object(object)
}

/// The suites nest under one name, so `--filter MergeDetailsTests` runs them all.
@Suite struct MergeDetailsTests {}

// MARK: - The real #133856 body

extension MergeDetailsTests {
  @Suite struct Fixture133856 {
    @Test(arguments: ["Agent context", "claude.ai", "Closes", "<!--", "Release status"])
    func descriptionLeavesOutWhatTheReaderDoesNotNeed(_ excluded: String) throws {
      let description = MergeDetails.read(body: try prBody("posthog-133856.md"), title: "").description

      #expect(!description.contains(excluded))
    }

    @Test func descriptionLeavesOutTheTestSection() throws {
      let description = MergeDetails.read(body: try prBody("posthog-133856.md"), title: "").description

      #expect(!description.contains("database-backed suites"))
    }

    @Test func descriptionLeavesOutTheDetailsBlock() throws {
      let description = MergeDetails.read(body: try prBody("posthog-133856.md"), title: "").description

      #expect(!description.contains("More context for AI agents"))
    }

    @Test func descriptionKeepsTheProblem() throws {
      let description = MergeDetails.read(body: try prBody("posthog-133856.md"), title: "").description

      #expect(description.contains("the result depends on child order"))
    }

    @Test func descriptionKeepsTheTableAsText() throws {
      let description = MergeDetails.read(body: try prBody("posthog-133856.md"), title: "").description

      #expect(description.contains("no match"))
    }

    @Test func gistHasAtMost300Characters() throws {
      let body = try prBody("posthog-133856.md")

      let gist = try #require(MergeDetails.read(body: body, title: title133856).gist)

      #expect(gist.count <= 300)
    }

    @Test func gistSaysWhatTheProblemIs() throws {
      let body = try prBody("posthog-133856.md")

      let gist = try #require(MergeDetails.read(body: body, title: title133856).gist)

      #expect(gist.contains("the result depends on child order"))
    }

    @Test func gistDoesNotRepeatTheTitle() throws {
      let body = try prBody("posthog-133856.md")

      let gist = try #require(MergeDetails.read(body: body, title: title133856).gist)

      #expect(!gist.contains(title133856))
    }

    @Test func gistIsPlainText() throws {
      let body = try prBody("posthog-133856.md")

      let gist = try #require(MergeDetails.read(body: body, title: title133856).gist)

      #expect(!gist.contains("`"))
      #expect(!gist.contains("]("))
    }

    /// The release-status line holds an inline comment, and the docs section
    /// is a list. Neither is in a test section.
    @Test func testGapsAreOnlyTheSuitesThatDidNotRun() throws {
      let gaps = MergeDetails.read(body: try prBody("posthog-133856.md"), title: "").testGaps

      #expect(gaps == ["Not run: the database-backed suites."])
    }
  }
}

// MARK: - Description stripping

extension MergeDetailsTests {
  @Suite struct Description {
    @Test func removesAnInlineHTMLComment() {
      let body = "## Problem\n\nThe cache drops writes. <!-- fill this in later -->"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("fill this in later"))
      #expect(description.contains("The cache drops writes."))
    }

    @Test func removesABlockHTMLComment() {
      let body = "## Problem\n\n<!--\nWho are we building for?\n-->\n\nThe cache drops writes."

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("Who are we building for"))
      #expect(description.contains("The cache drops writes."))
    }

    @Test func removesADetailsBlock() {
      let body = """
        ## Problem

        The cache drops writes.

        <details>
        <summary>Logs</summary>

        stack trace here

        </details>
        """

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("stack trace here"))
      #expect(!description.contains("Logs"))
    }

    @Test func removesAnImage() {
      let body = "## Changes\n\nIt flushes before close.\n\n![screenshot](https://example.com/shot.png)"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("https://example.com/shot.png"))
    }

    @Test func removesATaskList() {
      let body = "## Changes\n\nIt flushes before close.\n\n- [ ] Update the runbook\n- [x] Add a metric"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("Update the runbook"))
      #expect(!description.contains("Add a metric"))
    }

    @Test func removesALineThatIsOnlyAURL() {
      let body = "## Changes\n\nIt flushes before close.\n\nhttps://claude.ai/code/session_01ABC"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("https://claude.ai/code/session_01ABC"))
    }

    @Test(arguments: [
      "Closes #12", "Fixes #12", "Resolves #12", "closes #12", "Closed #12", "Fixed #12", "Resolved #12", "Fix #12",
      "Close #12", "Resolve #12", "Closes: #12", "Closes acme/widgets#12",
      "Closes https://github.com/acme/widgets/issues/12",
    ])
    func removesALineThatIsOnlyAClosingKeyword(_ line: String) {
      let body = "## Problem\n\nThe cache drops writes.\n\n\(line)"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("12"), "\(line)")
    }

    @Test(arguments: [
      "Testing", "How did you test this code?", "Test plan", "Release notes", "Release status", "Docs", "Docs update",
      "Documentation", "🤖 Agent context", "Checklist", "Screenshots", "Changelog", "TESTING",
    ])
    func dropsASectionWhoseHeadingNamesIt(_ heading: String) {
      let body =
        "## Problem\n\nThe cache drops writes.\n\n## \(heading)\n\nDropped words here.\n\n## Changes\n\nKept words."

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("Dropped words here"), "\(heading)")
      #expect(description.contains("Kept words"), "\(heading)")
    }

    @Test(arguments: ["Latest numbers", "Attestation flow", "Contest rules", "Reagent costs"])
    func keepsASectionWhoseHeadingHasTheWordInsideAnotherWord(_ heading: String) {
      let body = "## Problem\n\nThe cache drops writes.\n\n## \(heading)\n\nKept words.\n\n- [ ] follow up"

      let read = MergeDetails.read(body: body, title: "")

      #expect(read.description.contains("Kept words"), "\(heading)")
      #expect(read.testGaps == [], "\(heading)")
    }

    @Test func dropsTheSubsectionsOfADroppedSection() {
      let body = "## Testing\n\n### Unit\n\nDropped words here.\n\n## Changes\n\nKept words."

      let description = MergeDetails.read(body: body, title: "").description

      #expect(!description.contains("Dropped words here"))
      #expect(description.contains("Kept words"))
    }

    @Test func keepsAListAsText() {
      let body = "## Changes\n\n- Adds a flush before close\n- Removes the retry loop"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(description.contains("Adds a flush before close"))
      #expect(description.contains("Removes the retry loop"))
    }

    @Test func keepsATableAsText() {
      let body = "## Changes\n\n| Input | Result |\n| --- | --- |\n| empty | no write |"

      let description = MergeDetails.read(body: body, title: "").description

      #expect(description.contains("no write"))
    }

    @Test func keepsAnAlertsTextAndItsTestGaps() {
      let body =
        "## Problem\n\n> [!WARNING]\n> The cache drops writes.\n\n## Testing\n\n> [!NOTE]\n> Not run: the e2e suite."

      let read = MergeDetails.read(body: body, title: "")

      #expect(read.description.contains("The cache drops writes."))
      #expect(read.testGaps == ["Not run: the e2e suite."])
    }

    @Test func hasAtMost4000Characters() {
      let body = "## Problem\n\n" + String(repeating: "The cache drops writes under load. ", count: 400)

      let description = MergeDetails.read(body: body, title: "").description

      #expect(description.count <= 4000)
    }

    @Test func emptyBodyGivesAnEmptyDescription() {
      #expect(MergeDetails.read(body: "", title: "").description == "")
    }
  }
}

// MARK: - Gist

extension MergeDetailsTests {
  @Suite struct Gist {
    @Test func takesTheFirstSentenceOfEachOfTheFirstTwoSections() throws {
      let body = """
        ## Problem

        The cache drops writes. It happens under load.

        ## Changes

        It flushes before close. It also logs.

        ## Notes

        Third section words.
        """

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(gist.contains("The cache drops writes."))
      #expect(gist.contains("It flushes before close."))
      #expect(!gist.contains("It happens under load"))
      #expect(!gist.contains("It also logs"))
      #expect(!gist.contains("Third section words"))
    }

    @Test func withoutHeadingsTakesTheFirstTwoParagraphs() throws {
      let body = "The cache drops writes. It happens under load.\n\nIt flushes before close.\n\nThird words."

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(gist.contains("The cache drops writes."))
      #expect(gist.contains("It flushes before close."))
      #expect(!gist.contains("It happens under load"))
      #expect(!gist.contains("Third words"))
    }

    @Test func withoutHeadingsTakesTheFirstTwoListItems() throws {
      let body = "- Adds a flush before close. Also a log.\n- Removes the retry loop.\n- Third item words."

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(gist.contains("Adds a flush before close."))
      #expect(gist.contains("Removes the retry loop."))
      #expect(!gist.contains("Also a log"))
      #expect(!gist.contains("Third item words"))
    }

    @Test func skipsASentenceThatEqualsTheTitle() throws {
      let body = "## Summary\n\nFlush the cache\n\n## Changes\n\nIt flushes before close."

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(!gist.contains("Flush the cache"))
      #expect(gist.contains("It flushes before close."))
    }

    @Test func isNilWhenOnlyTheTitleIsLeft() {
      let body = "## Summary\n\nFlush the cache"

      #expect(MergeDetails.read(body: body, title: "Flush the cache").gist == nil)
    }

    @Test func isNilForAnEmptyBody() {
      #expect(MergeDetails.read(body: "", title: "Flush the cache").gist == nil)
    }

    @Test func hasAtMost300Characters() throws {
      let long = String(repeating: "word ", count: 120)
      let body = "## Problem\n\n\(long)ends here.\n\n## Changes\n\n\(long)ends here too."

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(gist.count <= 300)
    }

    @Test func isPlainText() throws {
      let body = "## Problem\n\nThe `XOR` group [fails](https://example.com/x) on **child order**."

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(!gist.contains("`"))
      #expect(!gist.contains("**"))
      #expect(!gist.contains("https://example.com/x"))
      #expect(gist.contains("fails on child order"))
    }

    @Test func isOneLine() throws {
      let body = "The cache drops\nwrites under load.\n\nIt flushes\nbefore close."

      let gist = try #require(MergeDetails.read(body: body, title: "Flush the cache").gist)

      #expect(!gist.contains("\n"))
    }
  }
}

// MARK: - Test gaps

extension MergeDetailsTests {
  @Suite struct TestGaps {
    @Test func templateWhoseTestSectionIsOnlyACommentHasNoGaps() {
      #expect(MergeDetails.read(body: templateBody, title: "").testGaps == [])
    }

    @Test func bodyWithoutATestSectionHasNoGaps() {
      let body = "## Problem\n\nThe cache drops writes.\n\n## Changes\n\nIt flushes before close."

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func uncheckedTaskInATestSectionIsAGap() {
      let body = "## Test plan\n\n- [ ] Ran the migration locally\n- [x] Ran the unit tests"

      #expect(MergeDetails.read(body: body, title: "").testGaps == ["Ran the migration locally"])
    }

    @Test func checkedTasksInATestSectionAreNotGaps() {
      let body = "## Test plan\n\n- [x] Ran the migration locally\n- [x] Ran the unit tests"

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func uncheckedTaskOutsideATestSectionIsNotAGap() {
      let body = "## Docs update\n\n- [ ] Updated the docs\n\n## Testing\n\nUnit tests pass."

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test(arguments: [
      "These were not tested on Windows.",
      "It was never tested against prod.",
      "Not run: the database-backed suites.",
      "The importer was never run.",
      "The rollback has not been verified.",
      "The rollback was never verified.",
      "The flow has not been tested.",
      "The migration is untested.",
      "I didn't test the UI.",
      "We did not run the e2e suite.",
      "I haven't verified the rollback.",
      "We have not tested Safari.",
      "I couldn't test the webhook.",
      "I could not verify the email.",
      "I DID NOT RUN the load test.",
    ])
    func sentenceThatSaysSomethingWasNotTestedIsAGap(_ sentence: String) {
      let body = "## How did you test this code?\n\n\(sentence)"

      #expect(MergeDetails.read(body: body, title: "").testGaps == [sentence])
    }

    @Test(arguments: [
      "Tests run in CI.",
      "The unit tests ran and passed.",
      "I tested it by hand and verified the output.",
      "Nothing was skipped.",
      "Another test runs nightly.",
    ])
    func sentenceThatDoesNotSayItIsNotAGap(_ sentence: String) {
      let body = "## Testing\n\n\(sentence)"

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func gapIsTheSentenceNotTheParagraph() {
      let body = "## Testing\n\nUnit tests pass. Not run: the e2e suite. CI is green."

      #expect(MergeDetails.read(body: body, title: "").testGaps == ["Not run: the e2e suite."])
    }

    @Test func phraseOutsideATestSectionIsNotAGap() {
      let body = "## Problem\n\nThe old path was never tested.\n\n## Testing\n\nUnit tests pass."

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test(arguments: ["Testing", "Test plan", "How did you test this code?", "TESTS", "Manual testing"])
    func headingThatContainsTestStartsATestSection(_ heading: String) {
      let body = "## \(heading)\n\nNot run: the e2e suite."

      #expect(MergeDetails.read(body: body, title: "").testGaps == ["Not run: the e2e suite."], "\(heading)")
    }

    @Test func subheadingStaysInTheTestSection() {
      let body = "## Test plan\n\n### Manual\n\n- [ ] Clicked through the wizard"

      #expect(MergeDetails.read(body: body, title: "").testGaps == ["Clicked through the wizard"])
    }

    @Test func headingOfTheSameLevelEndsTheTestSection() {
      let body = "## Testing\n\nUnit tests pass.\n\n## Notes\n\nNot run: the e2e suite.\n\n- [ ] Tell the team"

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func headingOfAHigherLevelEndsTheTestSection() {
      let body = "### Testing\n\nUnit tests pass.\n\n## Notes\n\nNot run: the e2e suite."

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func inlineCommentInATestSectionIsNotAGap() {
      let body = "## Testing\n\nUnit tests pass. <!-- List anything that was not tested. -->"

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func blockCommentInATestSectionIsNotAGap() {
      let body = "## Testing\n\n<!--\n- [ ] Ran the e2e suite\nNot run: anything you skipped.\n-->\n\nUnit tests pass."

      #expect(MergeDetails.read(body: body, title: "").testGaps == [])
    }

    @Test func gapIsPlainText() {
      let body = "## Test plan\n\n- [ ] Check [the page](file:///etc/passwd) in `Safari`"

      #expect(MergeDetails.read(body: body, title: "").testGaps == ["Check the page in Safari"])
    }

    @Test func atMostFiveGaps() {
      let items = (1...8).map { "- [ ] Step \($0)" }.joined(separator: "\n")

      #expect(MergeDetails.read(body: "## Test plan\n\n\(items)", title: "").testGaps.count == 5)
    }

    @Test func keepsTheFirstFiveGapsInOrder() {
      let items = (1...8).map { "- [ ] Step \($0)" }.joined(separator: "\n")

      #expect(
        MergeDetails.read(body: "## Test plan\n\n\(items)", title: "").testGaps == [
          "Step 1", "Step 2", "Step 3", "Step 4", "Step 5",
        ])
    }

    @Test func eachGapFitsALine() {
      let long = String(repeating: "click ", count: 100)

      let gaps = MergeDetails.read(body: "## Test plan\n\n- [ ] \(long)", title: "").testGaps

      #expect(gaps.count == 1)
      #expect(gaps.allSatisfy { $0.count <= TriageCard.lineLength })
    }
  }
}

// MARK: - GitHub.parseMergeDetails

extension MergeDetailsTests {
  @Suite struct Parsing {
    @Test func readsTheHead() throws {
      let parsed = try #require(GitHub.parseMergeDetails(detailsNode()))

      #expect(parsed.head == head133856)
    }

    @Test func readsTheSize() throws {
      let details = try #require(GitHub.parseMergeDetails(detailsNode())).details

      #expect(details.additions == 315)
      #expect(details.deletions == 208)
      #expect(details.changedFiles == 4)
    }

    @Test func readsTheBodyIntoTheDescriptionGistAndGaps() throws {
      let body = try prBody("posthog-133856.md")

      let details = try #require(GitHub.parseMergeDetails(detailsNode(body: body))).details

      #expect(details.description == MergeDetails.read(body: body, title: title133856).description)
      #expect(details.gist?.contains("the result depends on child order") == true)
      #expect(details.testGaps == ["Not run: the database-backed suites."])
    }

    @Test func readsAnEmptyBody() throws {
      let details = try #require(GitHub.parseMergeDetails(detailsNode(body: ""))).details

      #expect(details.description == "")
      #expect(details.gist == nil)
      #expect(details.testGaps == [])
    }

    @Test(arguments: [
      // Every thread read.
      (0, [Bool?](), 0, 0, 0),
      (2, [true, true], 2, 2, 0),
      (2, [true, false], 2, 2, 1),
      (2, [false, false], 2, 2, 2),
      // GitHub returns at most 100 nodes.
      (150, [Bool?](repeating: true, count: 100), 150, 100, 0),
      (150, [Bool?](repeating: true, count: 97) + [false, false, false], 150, 100, 3),
      // A null node is not a thread that sbd read.
      (3, [true, nil, false], 3, 2, 1),
      (2, [nil, nil], 2, 0, 0),
    ])
    func countsTheThreads(
      _ totalCount: Int, _ threads: [Bool?], _ expectedThreads: Int, _ expectedRead: Int, _ expectedOpen: Int
    ) throws {
      let details = try #require(
        GitHub.parseMergeDetails(detailsNode(totalCount: totalCount, threads: threads))
      ).details

      #expect(details.threads == expectedThreads)
      #expect(details.threadsRead == expectedRead)
      #expect(details.openThreads == expectedOpen)
    }

    @Test(arguments: ["headRefOid", "additions", "deletions", "changedFiles", "reviewThreads"])
    func nodeWithoutAFieldItNeedsGivesNoDetails(_ key: String) {
      #expect(GitHub.parseMergeDetails(removing(key, from: detailsNode())) == nil, "\(key)")
    }

    @Test func nodeWithoutATotalCountGivesNoDetails() {
      let node: JSON = [
        "id": "PR_1", "headRefOid": "abc", "title": "t", "body": "", "additions": 1, "deletions": 0,
        "changedFiles": 1, "reviewThreads": ["nodes": [["isResolved": false]]],
      ]

      #expect(GitHub.parseMergeDetails(node) == nil)
    }

    @Test(arguments: [JSON.null, JSON.object([:])])
    func nodeThatIsNotAPRGivesNoDetails(_ node: JSON) {
      #expect(GitHub.parseMergeDetails(node) == nil)
    }

    @Test func nullHeadGivesNoDetails() {
      #expect(GitHub.parseMergeDetails(detailsNode(head: .null)) == nil)
    }

    @Test func queryReadsTheFieldsItParses() {
      let query = GitHub.mergeDetailsQuery

      for field in [
        "headRefOid", "title", "body", "additions", "deletions", "changedFiles", "reviewThreads(first: 100)",
        "totalCount", "isResolved",
      ] {
        #expect(query.contains(field), "\(field)")
      }
    }

    @Test func queryReadsTheReviewDetailFields() {
      let query = GitHub.mergeDetailsQuery

      for field in [
        "$ids: [ID!]!", "$threads: Boolean!", "rateLimit { cost }", "isOutdated", "path", "originalLine",
        "first: comments(first: 1) @include(if: $threads)", "last: comments(last: 1) @include(if: $threads)",
        "viewerDidAuthor", "url", "__typename", "latestOpinionatedReviews(first: 20)", "submittedAt",
        "commit { oid }", "comments(first: 5)", "commits(last: 100)",
      ] {
        #expect(query.contains(field), "\(field)")
      }
    }

    @Test func queryAsksForThreadCommentsOnlyUnderTheThreadsVariable() {
      #expect(GitHub.mergeDetailsQuery.components(separatedBy: "@include(if: $threads)").count - 1 == 2)
    }

    /// A read from before the review details, or one whose new fields are
    /// missing, gives the same details as before.
    @Test func nodeWithoutTheNewFieldsGivesTheDetailsItGaveBefore() throws {
      let node = detailsNode(totalCount: 3, threads: [true, false, nil])

      let details = try #require(GitHub.parseMergeDetails(node)).details

      #expect(
        details
          == MergeDetails(
            additions: 315, deletions: 208, changedFiles: 4, threads: 3, threadsRead: 2, openThreads: 1,
            description: "", gist: nil, testGaps: []))
    }

    @Test func nodeWithoutTheNewFieldsHasNoThreadOrReviewDetails() throws {
      let details = try #require(GitHub.parseMergeDetails(detailsNode(threads: [false]))).details

      #expect(details.threadDetails == nil)
      #expect(details.reviews == nil)
    }

    @Test func nodeWithReviewsButNoThreadCommentsStillParses() throws {
      let node = detailsNode(threadNodes: [threadNode(withComments: false)], reviews: [reviewNode()])

      let details = try #require(GitHub.parseMergeDetails(node)).details

      #expect(details.threadDetails == nil)
      #expect(details.reviews?.count == 1)
      #expect(details.openThreads == 1)
    }

    @Test func nodeWithThreadCommentsButNoReviewsStillParses() throws {
      let node = detailsNode(threadNodes: [threadNode()])

      let details = try #require(GitHub.parseMergeDetails(node)).details

      #expect(details.threadDetails?.count == 1)
      #expect(details.reviews == nil)
    }
  }
}

// MARK: - Thread details

extension MergeDetailsTests {
  @Suite struct ThreadDetails {
    func details(_ nodes: [JSON], totalCount: Int? = nil) throws -> MergeDetails {
      try #require(GitHub.parseMergeDetails(detailsNode(totalCount: totalCount, threadNodes: nodes))).details
    }

    func only(_ node: JSON) throws -> MergeDetails.ThreadDetail {
      try #require(try details([node]).threadDetails?.first)
    }

    @Test func keepsOnlyTheOpenThreadsInGitHubsOrder() throws {
      let nodes = [threadNode(path: "a.py"), threadNode(resolved: true, path: "b.py"), threadNode(path: "c.py")]

      let threads = try #require(try details(nodes).threadDetails)

      #expect(threads.map(\.path) == ["a.py", "c.py"])
    }

    @Test func threadsThatAreAllResolvedGiveNoDetails() throws {
      let nodes = [threadNode(resolved: true), threadNode(resolved: true)]

      #expect(try details(nodes).threadDetails?.isEmpty == true)
    }

    @Test func keepsAtMostTenOpenThreads() throws {
      let nodes = (0..<11).map { threadNode(path: "f\($0).py") }

      let threads = try #require(try details(nodes).threadDetails)

      #expect(MergeDetails.maxThreadDetails == 10)
      #expect(threads.map(\.path) == (0..<10).map { "f\($0).py" })
    }

    @Test func openThreadsCountsTheThreadsBeyondTheDetails() throws {
      let nodes = (0..<11).map { threadNode(path: "f\($0).py") }

      #expect(try details(nodes).openThreads == 11)
    }

    @Test func threadReadWithoutCommentsGivesNoDetailsAndKeepsTheCounts() throws {
      let nodes = [threadNode(withComments: false), threadNode(resolved: true, withComments: false)]

      let read = try details(nodes, totalCount: 5)

      #expect(read.threadDetails == nil)
      #expect(read.threads == 5)
      #expect(read.threadsRead == 2)
      #expect(read.openThreads == 1)
    }

    @Test(arguments: [
      // One comment is the thread's root, so nobody replied, even when the viewer opened it.
      (1, true, false),
      (1, false, false),
      (2, true, true),
      (5, true, true),
      // Someone else wrote the last comment.
      (2, false, false),
      (5, false, false),
    ])
    func repliedMeansTheViewerWroteALaterLastComment(_ comments: Int, _ viewerWroteLast: Bool, _ replied: Bool)
      throws
    {
      let thread = try only(threadNode(comments: comments, viewerWroteLast: viewerWroteLast))

      #expect(thread.replied == replied, "\(comments) comments, viewer wrote last: \(viewerWroteLast)")
    }

    @Test func botAuthorIsABot() throws {
      let thread = try only(threadNode(author: "greptile-apps", typename: "Bot"))

      #expect(thread.author == "greptile-apps")
      #expect(thread.bot == true)
    }

    @Test func userAuthorIsNotABot() throws {
      let thread = try only(threadNode(author: "dmarticus", typename: "User"))

      #expect(thread.author == "dmarticus")
      #expect(thread.bot != true)
    }

    @Test func currentThreadHasItsLine() throws {
      let thread = try only(threadNode(line: 42, originalLine: 40))

      #expect(thread.line == 42)
      #expect(thread.outdated == false)
    }

    @Test func outdatedThreadKeepsItsOriginalLine() throws {
      let thread = try only(threadNode(outdated: true, line: nil, originalLine: 40))

      #expect(thread.line == 40)
      #expect(thread.outdated == true)
    }

    @Test func keepsTheFirstCommentsURLAndPath() throws {
      let url = "\(pr133856)#discussion_r2512345678"

      let thread = try only(threadNode(path: "posthog/api/flags.py", url: url))

      #expect(thread.url == url)
      #expect(thread.path == "posthog/api/flags.py")
    }

    /// The draft side resolves `replyTo` with ReplyTarget.parse, so both
    /// sides of a match compare ids that one function produced.
    @Test(arguments: [
      ("\(pr133856)#discussion_r2512345678", Int64(2_512_345_678)),
      ("\(pr133856)#discussion_r3456789012", Int64(3_456_789_012)),
      ("\(pr133856)/files#discussion_r3456789012", Int64(3_456_789_012)),
      ("https://github.com/acme/widgets/pull/7#discussion_r1", Int64(1)),
    ])
    func rootIdIsTheIdThatReplyTargetParses(_ url: String, _ id: Int64) throws {
      let thread = try only(threadNode(url: url))

      #expect(thread.rootId == id, "\(url)")
      #expect(thread.rootId == (try? ReplyTarget.parse(url))?.id, "\(url)")
    }

    @Test(arguments: [
      "",
      "not a url",
      "http://github.com/PostHog/posthog/pull/133856#discussion_r2512345678",
      "https://example.com/PostHog/posthog/pull/133856#discussion_r2512345678",
      "https://github.com/PostHog/posthog/pull/133856",
      "https://github.com/PostHog/posthog/pull/133856#discussion_rabc",
      "https://github.com/PostHog/posthog/pull/133856?x=1#discussion_r2512345678",
      "https://github.com/PostHog/posthog/issues/133856#discussion_r2512345678",
    ])
    func rootIdIsNilForAURLThatDoesNotParse(_ url: String) throws {
      let thread = try only(threadNode(url: url))

      #expect(thread.rootId == nil, "\(url)")
    }

    /// A draft matches a thread only by a review comment id, so an id of
    /// another kind would let a conversation comment's draft land in a thread.
    @Test(arguments: [
      "\(pr133856)#issuecomment-2512345678",
      "\(pr133856)#pullrequestreview-2512345678",
    ])
    func rootIdIsNilForAURLThatNamesAnotherKindOfComment(_ url: String) throws {
      #expect(try only(threadNode(url: url)).rootId == nil, "\(url)")
    }

    /// The details cover every open thread, so a read without comments of a
    /// PR whose threads are all resolved has nothing missing.
    @Test func resolvedThreadsReadWithoutCommentsGiveNoMissingDetails() throws {
      let nodes = [threadNode(resolved: true, withComments: false)]

      #expect(try details(nodes).threadDetails == [])
    }

    @Test func openThreadWhoseFirstCommentIsGoneStillGivesADetail() throws {
      var node = try #require(threadNode(path: "gone.py").object)
      node["first"] = ["nodes": []]

      let thread = try only(.object(node))

      #expect(thread.path == "gone.py")
      #expect(thread.rootId == nil)
      #expect(thread.excerpt == "")
    }

    @Test func excerptIsTheFirstCommentOnOneLine() throws {
      let thread = try only(threadNode(body: "Should this handle\nthe empty group?\n\nI think so."))

      #expect(thread.excerpt == "Should this handle the empty group? I think so.")
    }

    @Test func excerptHasAtMost300Characters() throws {
      let body = String(repeating: "This changes the default.\n", count: 60)

      let thread = try only(threadNode(body: body))

      #expect(thread.excerpt.count <= 300)
      #expect(!thread.excerpt.contains("\n"))
    }
  }
}

// MARK: - Review details

extension MergeDetailsTests {
  @Suite struct ReviewDetails {
    static let commits = ["c1", "c2", "c3", head133856]

    func reviews(_ nodes: [JSON], commits: [String]? = ReviewDetails.commits) throws -> [MergeDetails.ReviewDetail] {
      let parsed = try #require(GitHub.parseMergeDetails(detailsNode(reviews: nodes, commits: commits)))
      return try #require(parsed.details.reviews)
    }

    func only(_ node: JSON, commits: [String]? = ReviewDetails.commits) throws -> MergeDetails.ReviewDetail {
      let all = try reviews([node], commits: commits)
      #expect(all.count == 1)
      return try #require(all.first)
    }

    @Test func readsTheAuthorStateBodyCommitAndURL() throws {
      let url = "\(pr133856)#pullrequestreview-3400000001"

      let review = try only(reviewNode(author: "stamphog", state: "APPROVED", body: "Looks good.", url: url))

      #expect(review.author == "stamphog")
      #expect(review.state == "APPROVED")
      #expect(review.body == "Looks good.")
      #expect(review.commit == head133856)
      #expect(review.url == url)
    }

    @Test func keepsGitHubsOrder() throws {
      let all = try reviews([reviewNode(author: "stamphog"), reviewNode(author: "dmarticus")])

      #expect(all.map(\.author) == ["stamphog", "dmarticus"])
    }

    @Test func botReviewerIsABot() throws {
      #expect(try only(reviewNode(author: "stamphog", typename: "Bot")).bot == true)
    }

    @Test func userReviewerIsNotABot() throws {
      #expect(try only(reviewNode(author: "dmarticus", typename: "User")).bot != true)
    }

    @Test(arguments: [
      (head133856, 0),
      ("c3", 1),
      ("c2", 2),
      ("c1", 3),
    ])
    func commitsSinceCountsTheCommitsAfterTheReviewsCommit(_ commit: String, _ since: Int) throws {
      #expect(try only(reviewNode(commit: commit)).commitsSince == since, "\(commit)")
    }

    /// A force-push, or a PR with more than 100 commits, leaves the review's
    /// commit out of the list.
    @Test func commitsSinceIsNilWhenTheCommitIsNotInTheList() throws {
      #expect(try only(reviewNode(commit: "gone")).commitsSince == nil)
    }

    @Test func commitsSinceIsNilWhenTheReviewHasNoCommit() throws {
      #expect(try only(reviewNode(commit: nil)).commitsSince == nil)
    }

    @Test func commitsSinceIsNilWithoutTheCommitList() throws {
      #expect(try only(reviewNode(commit: head133856), commits: nil).commitsSince == nil)
    }

    @Test func bodyHasAtMost600Characters() throws {
      let body = String(repeating: "This looks right to me. ", count: 60)

      #expect(try only(reviewNode(body: body)).body.count <= 600)
    }

    @Test func shortBodyIsKept() throws {
      #expect(try only(reviewNode(body: "Ship it.")).body == "Ship it.")
    }

    @Test func emptyBodyIsEmpty() throws {
      #expect(try only(reviewNode(body: "")).body == "")
    }

    @Test func readsEachInlineComment() throws {
      let note = noteNode(
        path: "posthog/api/flags.py", line: 12, body: "Nit:\nrename this.", url: "\(pr133856)#discussion_r2600000001")

      let read = try #require(try only(reviewNode(notes: [note])).notes.first)

      #expect(read.path == "posthog/api/flags.py")
      #expect(read.line == 12)
      #expect(read.excerpt == "Nit: rename this.")
      #expect(read.url == "\(pr133856)#discussion_r2600000001")
    }

    @Test func outdatedInlineCommentKeepsItsOriginalLine() throws {
      let read = try #require(try only(reviewNode(notes: [noteNode(line: nil, originalLine: 9)])).notes.first)

      #expect(read.line == 9)
    }

    @Test func keepsAtMostFiveInlineCommentsAndTheirCount() throws {
      let notes = (0..<7).map { noteNode(path: "f\($0).py") }

      let review = try only(reviewNode(notes: notes, noteCount: 9))

      #expect(review.notes.map(\.path) == (0..<5).map { "f\($0).py" })
      #expect(review.noteCount == 9)
    }

    @Test func inlineCommentExcerptHasAtMost300Characters() throws {
      let body = String(repeating: "Rename this.\n", count: 60)

      let read = try #require(try only(reviewNode(notes: [noteNode(body: body)])).notes.first)

      #expect(read.excerpt.count <= 300)
      #expect(!read.excerpt.contains("\n"))
    }
  }
}

// MARK: - Stored shape

extension MergeDetailsTests {
  @Suite struct StoredShape {
    /// The merge details of a `pr` event that an sbd before the review
    /// details wrote.
    static let oldDetails = """
      {"additions":315,"changedFiles":4,"deletions":208,"description":"The cache drops writes.",\
      "gist":"The cache drops writes.","openThreads":1,"testGaps":["Not run: the e2e suite."],"threads":2,\
      "threadsRead":2}
      """

    @Test func detailsWrittenBeforeTheReviewDetailsDecode() throws {
      let details = try JSONCoding.decode(MergeDetails.self, from: Self.oldDetails)

      #expect(
        details
          == MergeDetails(
            additions: 315, deletions: 208, changedFiles: 4, threads: 2, threadsRead: 2, openThreads: 1,
            description: "The cache drops writes.", gist: "The cache drops writes.",
            testGaps: ["Not run: the e2e suite."]))
      #expect(details.threadDetails == nil)
      #expect(details.reviews == nil)
    }

    @Test func pullRequestWrittenBeforeTheReviewDetailsDecodes() throws {
      var object = try #require(try JSON(encoding: samplePR()).object)
      let oldDetails: JSON = try #require(JSON.parse(Self.oldDetails))
      object["mergeDetails"] = oldDetails

      let pr = try JSONCoding.decode(PullRequest.self, from: JSON.object(object).text)

      #expect(pr.mergeDetails?.openThreads == 1)
      #expect(pr.mergeDetails?.threadDetails == nil)
      #expect(pr.mergeDetails?.reviews == nil)
    }

    @Test func parsedReviewDetailsSurviveARoundTrip() throws {
      let node = detailsNode(
        threadNodes: [threadNode(typename: "Bot"), threadNode(resolved: true)],
        reviews: [reviewNode(notes: [noteNode()]), reviewNode(author: "dmarticus", commit: nil)],
        commits: ["c1", head133856])
      let details = try #require(GitHub.parseMergeDetails(node)).details

      let decoded = try JSONCoding.decode(MergeDetails.self, from: try JSONCoding.encode(details))

      #expect(decoded == details)
      #expect(decoded.threadDetails?.isEmpty == false)
      #expect(decoded.reviews?.isEmpty == false)
    }
  }
}

// MARK: - Lead

extension MergeDetailsTests {
  /// `lead` is the gist's first sentence, which a Nudge all bullet shows.
  @Suite struct Lead {
    @Test func aOneSentenceGistIsItsOwnLead() {
      #expect(MergeDetails.lead("It caches flag reads per request.") == "It caches flag reads per request.")
    }

    @Test func aTwoSentenceGistLeadsWithItsFirstSentence() {
      let gist = "It caches flag reads per request. It also logs each miss."

      #expect(MergeDetails.lead(gist) == "It caches flag reads per request.")
    }

    @Test func aGistWithoutASentenceEndIsItsOwnLead() {
      #expect(MergeDetails.lead("It caches flag reads per request") == "It caches flag reads per request")
    }

    @Test func aDotInsideANameDoesNotEndTheLead() {
      let gist = "It reads README.md before the build. It also logs."

      #expect(MergeDetails.lead(gist) == "It reads README.md before the build.")
    }
  }
}
