import AppKit
import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let prRepo = "base-owner/base"
private let originRepo = "fork-owner/base"

/// A session in `repository` whose PR, when it has one, is in `prRepo`.
private func session(pr prRepo: String?, repository: String?, read: Bool? = true) -> SessionSummary {
  var s = needsItem("reference-repo-session")
  s.repository = repository
  s.repositoryRead = read
  s.pr = prRepo.map { PRSummary(PullRequest(id: "PR_7", number: 7, url: "https://github.com/\($0)/pull/7", repo: $0)) }
  return s
}

/// In a view about session S, bare `#N` resolves against `S.pr?.repo ?? S.repository`.
@Suite struct ReferenceRepoTests {
  /// A view whose host never sets `referenceRepo` draws bare `#N` as plain text.
  @Test func theEnvironmentValueStartsNil() {
    #expect(EnvironmentValues().referenceRepo == nil)
  }

  /// A fork checkout's origin names the fork. Numbers in the work refer to the PR's base repository.
  @Test func aSessionWithAPRInAnotherRepositoryUsesThePRsRepository() {
    #expect(InlineText.referenceRepo(for: session(pr: prRepo, repository: originRepo)) == prRepo)
  }

  @Test func aSessionWithoutAPRUsesItsRepository() {
    #expect(InlineText.referenceRepo(for: session(pr: nil, repository: originRepo)) == originRepo)
  }

  @Test func aSessionWithNeitherHasNoRepository() {
    #expect(InlineText.referenceRepo(for: session(pr: nil, repository: nil)) == nil)
  }

  @Test func aSessionNotYetReadWithoutAPRHasNoRepository() {
    #expect(InlineText.referenceRepo(for: session(pr: nil, repository: nil, read: nil)) == nil)
  }

  @Test func aSessionNotYetReadWithAPRUsesThePRsRepository() {
    #expect(InlineText.referenceRepo(for: session(pr: prRepo, repository: nil, read: nil)) == prRepo)
  }
}

/// SwiftUI exposes each link inside a `Text` as an `AXLink` labeled with the link's text. Pressing one
/// crashes the test process, because its element does not implement `accessibilityPerformAction:`.
/// These tests count and read the links. `InlineTextTests.References` checks each link's URL.
@MainActor
@Suite struct HostedReferenceLink {
  @Test func aPlainTextWithNoLinkExposesNoLink() {
    let hosted = HostedView(InlineText(plain: "Nothing to see"))

    #expect(links(hosted).isEmpty)
  }

  private func links(_ hosted: HostedView) -> [HostedElement] { hosted.elements.filter { $0.role == "AXLink" } }

  /// The control: a Markdown link inside `InlineText` is one `AXLink`. When it fails, the harness is wrong.
  @Test func aMarkdownLinkInInlineTextExposesOneLink() {
    let text = MarkdownText([MarkdownText.Run("See "), MarkdownText.Run("docs", link: "https://example.com/docs")])

    let hosted = HostedView(InlineText(text))

    #expect(links(hosted).count == 1)
  }

  @Test func aBareNumberWithAContextExposesOneLink() {
    let hosted = HostedView(InlineText(plain: "Fix #1 first.").environment(\.referenceRepo, "o/r"))

    #expect(links(hosted).count == 1)
  }

  @Test func aBareNumberWithoutAContextExposesNoLink() {
    let hosted = HostedView(InlineText(plain: "Fix #1 first."))

    #expect(links(hosted).isEmpty)
  }

  @Test func theLinkReadsAsTheReferenceAsWritten() {
    let hosted = HostedView(InlineText(plain: "Fix #1 first.").environment(\.referenceRepo, "o/r"))

    #expect(links(hosted).map(\.label) == ["#1"])
  }

  @Test func anOwnerNameReferenceWithoutAContextExposesOneLink() {
    let hosted = HostedView(InlineText(plain: "See o/r#1."))

    #expect(links(hosted).map(\.label) == ["o/r#1"])
  }

  /// `ReferenceRepoTests` checks which repository wins when the session has both.
  @Test func theSessionModifierGivesABareNumberALinkFromThePRAlone() {
    let hosted = HostedView(InlineText(plain: "Fix #1 first.").referenceRepo(session(pr: prRepo, repository: nil)))

    #expect(links(hosted).count == 1)
  }

  @Test func theSessionModifierGivesABareNumberALinkFromTheRepositoryAlone() {
    let hosted = HostedView(InlineText(plain: "Fix #1 first.").referenceRepo(session(pr: nil, repository: originRepo)))

    #expect(links(hosted).count == 1)
  }

  @Test func theSessionModifierWithNoRepositoryExposesNoLink() {
    let hosted = HostedView(InlineText(plain: "Fix #1 first.").referenceRepo(session(pr: nil, repository: nil)))

    #expect(links(hosted).isEmpty)
  }

  /// `inlineLinks` turns a false `openSessionLink` into `.systemAction`. `OpenURLAction.Result`
  /// is not comparable, so the test checks `openSessionLink` on each link that a reference draws.
  @Test(arguments: [
    "Fix #1 first.",
    "See o/r#1.",
    "See https://github.com/o/r/pull/1/files.",
    "See https://github.com/o/r/issues/1#issuecomment-1 now",
  ])
  func theWindowLeavesAReferenceLinkToTheSystem(_ s: String) throws {
    let model = offlineModel()
    let (text, _) = InlineText.attributed(
      MarkdownText(stringLiteral: s), names: SessionNames(live: [:], removed: [:]), repo: "o/r", links: true)
    let drawn = text.runs.compactMap(\.link)
    try #require(drawn.count == 1)

    let handled = model.openSessionLink(try #require(drawn.first))

    #expect(!handled)
  }
}
