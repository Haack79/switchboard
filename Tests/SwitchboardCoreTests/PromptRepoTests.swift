import Foundation
import Testing

@testable import SwitchboardCore

/// `PromptRepo.named(in:repos:)` finds the known repository that a prompt names, for the New Session sheet that
/// "Spawn a session with this" opens. A token names a repository when it is the repository's `owner/name`, in any
/// case and stripped of surrounding backticks, quotes, and `,.:;()`, or when it is a path that starts with `/` or `~`
/// and equals or sits inside the repository's path.
@Suite struct PromptRepoTests {
  static let switchboard = KnownRepo(path: "/Users/me/dev/haacked/switchboard", name: "haacked/switchboard")
  static let posthog = KnownRepo(path: "/Users/me/dev/posthog/posthog", name: "PostHog/posthog")
  static let repos = [switchboard, posthog]

  @Test func anOwnerNameAtTheStartOfASentenceNamesTheRepo() {
    let repo = PromptRepo.named(in: "/go In haacked/switchboard, fix the cache bug.", repos: Self.repos)

    #expect(repo == Self.switchboard)
  }

  @Test(arguments: [
    "/go Fix `haacked/switchboard`.", "/go Fix \"haacked/switchboard\" now", "/go Fix 'haacked/switchboard' now",
    "/go (haacked/switchboard) fix it",
  ])
  func aQuotedOwnerNameNamesTheRepo(_ prompt: String) {
    #expect(PromptRepo.named(in: prompt, repos: Self.repos) == Self.switchboard)
  }

  @Test(arguments: [
    "/go Fix haacked/switchboard.", "/go Fix haacked/switchboard,", "/go Fix haacked/switchboard:",
    "/go Fix haacked/switchboard;", "/go Fix haacked/switchboard).",
  ])
  func trailingPunctuationIsNotPartOfTheName(_ prompt: String) {
    #expect(PromptRepo.named(in: prompt, repos: Self.repos) == Self.switchboard)
  }

  @Test func theOwnerNameMatchesInAnyCase() {
    let repo = PromptRepo.named(in: "/go Fix the flag cache in posthog/PostHog.", repos: Self.repos)

    #expect(repo == Self.posthog)
  }

  @Test func theOwnerNameMatchesOnAnyLineOfThePrompt() {
    let repo = PromptRepo.named(in: "/go Fix the cache bug.\nThe repo is haacked/switchboard.", repos: Self.repos)

    #expect(repo == Self.switchboard)
  }

  // MARK: Paths

  @Test func aTildePathInsideAKnownRepoNamesIt() {
    let x = KnownRepo(path: "~/dev/x".expandingTilde, name: "acme/x")

    let repo = PromptRepo.named(in: "/go Fix the bug in ~/dev/x/docs/bug.md", repos: [Self.switchboard, x])

    #expect(repo == x)
  }

  @Test func anAbsolutePathInsideAKnownRepoNamesIt() {
    let repo = PromptRepo.named(
      in: "/go Read /Users/me/dev/haacked/switchboard/docs/bug.md and fix it.", repos: Self.repos)

    #expect(repo == Self.switchboard)
  }

  @Test(arguments: ["/Users/me/dev/haacked/switchboard", "/Users/me/dev/haacked/switchboard/"])
  func theRepoPathItselfNamesIt(_ path: String) {
    #expect(PromptRepo.named(in: "/go Fix the bug in \(path)", repos: Self.repos) == Self.switchboard)
  }

  @Test func aBacktickedPathNamesTheRepo() {
    let repo = PromptRepo.named(in: "/go Fix `/Users/me/dev/haacked/switchboard/Sources/x.swift`.", repos: Self.repos)

    #expect(repo == Self.switchboard)
  }

  /// A path is inside a repository only at a folder boundary, so a sibling folder whose name starts with the
  /// repository's name is not inside it.
  @Test(arguments: [
    "/Users/me/dev/haacked/switchboard-old/docs/bug.md", "/Users/me/dev/haacked/switchboardx",
    "~/dev/haacked/switchboard/docs/bug.md", "/Users/me/dev/haacked",
  ])
  func aPathOutsideEveryKnownRepoNamesNone(_ path: String) {
    #expect(PromptRepo.named(in: "/go Fix the bug in \(path)", repos: Self.repos) == nil)
  }

  @Test func aRelativePathNamesNone() {
    let repo = PromptRepo.named(in: "/go Fix dev/haacked/switchboard/docs/bug.md", repos: Self.repos)

    #expect(repo == nil)
  }

  // MARK: No match

  @Test func anUnknownOwnerNameNamesNone() {
    #expect(PromptRepo.named(in: "/go Fix acme/widgets.", repos: Self.repos) == nil)
  }

  @Test func aPromptWithoutARepoNamesNone() {
    #expect(PromptRepo.named(in: "/go Fix the cache bug.", repos: Self.repos) == nil)
  }

  @Test func noKnownReposNamesNone() {
    #expect(PromptRepo.named(in: "/go In haacked/switchboard, fix it.", repos: []) == nil)
  }

  @Test func anOwnerNameInsideALongerWordNamesNone() {
    #expect(PromptRepo.named(in: "/go Fix xhaacked/switchboardx.", repos: Self.repos) == nil)
  }

  /// A repository without a GitHub remote has its folder's name as its name, and a bare word is not an
  /// `owner/name` token.
  @Test func aBareFolderNameNamesNone() {
    let local = KnownRepo(path: "/Users/me/dev/scratch", name: "scratch")

    #expect(PromptRepo.named(in: "/go Fix scratch now.", repos: [local]) == nil)
  }

  // MARK: Order

  /// The repository that the prompt names first wins, whatever the order of the known list.
  @Test func theFirstOfTwoNamedReposWins() {
    let prompt = "/go Port the fix in haacked/switchboard to PostHog/posthog."

    #expect(PromptRepo.named(in: prompt, repos: [Self.posthog, Self.switchboard]) == Self.switchboard)
    #expect(PromptRepo.named(in: prompt, repos: [Self.switchboard, Self.posthog]) == Self.switchboard)
  }

  @Test func aPathBeforeAnOwnerNameWins() {
    let prompt = "/go Copy /Users/me/dev/posthog/posthog/x.py into haacked/switchboard."

    #expect(PromptRepo.named(in: prompt, repos: Self.repos) == Self.posthog)
  }
}
