import Foundation
import Testing

@testable import SwitchboardCore

private let now: Int64 = 100 * 3_600_000

private func liveFacts() -> SessionFacts {
  var f = SessionFacts()
  f.live = true
  return f
}

private func withCard(_ open: AutoContinueGuardTests.OpenPrompt, _ f: SessionFacts = liveFacts()) -> SessionFacts {
  var f = f
  open.open(in: &f, since: now - 60_000)
  return f
}

/// The prompts that `PromptGuard.openCard` reports. The card from
/// `sb summary set` is left out.
private let guardedCards = AutoContinueGuardTests.OpenPrompt.allCases.filter { $0 != .sessionCard }

@Suite struct PromptGuardOpenCardTests {
  @Test func factsWithNoCardHaveNoOpenCard() {
    #expect(PromptGuard.openCard(liveFacts()) == nil)
  }

  @Test func emptyFactsHaveNoOpenCard() {
    #expect(PromptGuard.openCard(SessionFacts()) == nil)
  }

  @Test(arguments: guardedCards)
  func eachKindOfCardIsAnOpenCard(_ open: AutoContinueGuardTests.OpenPrompt) {
    #expect(PromptGuard.openCard(withCard(open)) == "an open card")
  }

  @Test(arguments: guardedCards)
  func aCardOnAStoppedSessionIsAnOpenCard(_ open: AutoContinueGuardTests.OpenPrompt) {
    #expect(PromptGuard.openCard(withCard(open, SessionFacts())) == "an open card")
  }

  @Test func aRunningTurnAloneIsNotAnOpenCard() {
    var f = liveFacts()
    f.turnRunning = true

    #expect(PromptGuard.openCard(f) == nil)
  }

  @Test func aSessionSummaryAloneIsNotAnOpenCard() {
    #expect(PromptGuard.openCard(withCard(.sessionCard)) == nil)
  }

  @Test(arguments: guardedCards)
  func aCardAndARunningTurnReportTheOpenCard(_ open: AutoContinueGuardTests.OpenPrompt) {
    var f = withCard(open)
    f.turnRunning = true

    #expect(PromptGuard.openCard(f) == "an open card")
  }
}

@Suite struct PromptGuardTurnTests {
  @Test func anIdleLiveClaudeHasNoTurnBlocker() {
    #expect(PromptGuard.turn(liveFacts(), process: .running, messageWaiting: false) == nil)
  }

  @Test func aStoppedClaudeHasNoTurnBlocker() {
    #expect(PromptGuard.turn(SessionFacts(), process: .stopped, messageWaiting: false) == nil)
  }

  @Test func aStoppedClaudeWhoseSessionStillReadsLiveHasNoTurnBlocker() {
    #expect(PromptGuard.turn(liveFacts(), process: .stopped, messageWaiting: false) == nil)
  }

  @Test func aRunningTurnBlocks() {
    var f = liveFacts()
    f.turnRunning = true

    #expect(PromptGuard.turn(f, process: .running, messageWaiting: false) == "a turn is running")
  }

  @Test func aWaitingMessageBlocks() {
    #expect(PromptGuard.turn(liveFacts(), process: .running, messageWaiting: true) == "a message is on its way")
  }

  @Test func aWaitingMessageBlocksAStoppedClaude() {
    #expect(PromptGuard.turn(SessionFacts(), process: .stopped, messageWaiting: true) == "a message is on its way")
  }

  @Test func claudeStartingBlocks() {
    #expect(
      PromptGuard.turn(liveFacts(), process: .starting, messageWaiting: false) == "claude is starting or stopping")
  }

  @Test func claudeStartingWithNoLiveSessionBlocks() {
    #expect(
      PromptGuard.turn(SessionFacts(), process: .starting, messageWaiting: false) == "claude is starting or stopping")
  }

  @Test func claudeRunningAfterItsSessionEndedBlocks() {
    #expect(
      PromptGuard.turn(SessionFacts(), process: .running, messageWaiting: false) == "claude is starting or stopping")
  }

  @Test func aRunningTurnComesBeforeAWaitingMessageAndClaudeStarting() {
    var f = SessionFacts()
    f.turnRunning = true

    #expect(PromptGuard.turn(f, process: .starting, messageWaiting: true) == "a turn is running")
  }

  @Test func aWaitingMessageComesBeforeClaudeStarting() {
    #expect(PromptGuard.turn(liveFacts(), process: .starting, messageWaiting: true) == "a message is on its way")
  }

  @Test func aWaitingMessageComesBeforeClaudeExiting() {
    #expect(PromptGuard.turn(SessionFacts(), process: .running, messageWaiting: true) == "a message is on its way")
  }

  @Test(arguments: AutoContinueGuardTests.OpenPrompt.allCases)
  func aCardAloneIsNotATurnBlocker(_ open: AutoContinueGuardTests.OpenPrompt) {
    #expect(PromptGuard.turn(withCard(open), process: .running, messageWaiting: false) == nil)
  }

  @Test(arguments: AutoContinueGuardTests.OpenPrompt.allCases)
  func aCardARunningTurnAndAWaitingMessageReportTheRunningTurn(_ open: AutoContinueGuardTests.OpenPrompt) {
    var f = withCard(open)
    f.turnRunning = true

    #expect(PromptGuard.turn(f, process: .running, messageWaiting: true) == "a turn is running")
  }
}

/// One combination of the facts that `PromptGuard` and the guards around it
/// in `AutoContinue.blocker` both read.
struct PromptGuardCase: Sendable, CustomTestStringConvertible {
  var card: AutoContinueGuardTests.OpenPrompt?
  var process: PromptGuard.Process
  var live: Bool
  var turnRunning: Bool
  var messageWaiting: Bool

  var facts: SessionFacts {
    var f = SessionFacts()
    f.live = live
    f.turnRunning = turnRunning
    if let card { card.open(in: &f, since: now - 60_000) }
    return f
  }

  var testDescription: String {
    "card: \(card.map { "\($0)" } ?? "none"), \(process), live: \(live), turn: \(turnRunning), message: \(messageWaiting)"
  }

  static let all: [PromptGuardCase] = {
    let cards: [AutoContinueGuardTests.OpenPrompt?] = [nil] + AutoContinueGuardTests.OpenPrompt.allCases
    let processes: [PromptGuard.Process] = [.running, .starting, .stopped]
    return cards.flatMap { card in
      processes.flatMap { process in
        [false, true].flatMap { live in
          [false, true].flatMap { turnRunning in
            [false, true].map { messageWaiting in
              PromptGuardCase(
                card: card, process: process, live: live, turnRunning: turnRunning, messageWaiting: messageWaiting)
            }
          }
        }
      }
    }
  }()
}

/// An auto-continue input whose only blockers come from `PromptGuard`'s facts.
private func autoContinueInput(_ c: PromptGuardCase) -> AutoContinueInput {
  var input = AutoContinueInput(
    session: session(), facts: c.facts,
    verdict: Verdict(state: .canContinue, reason: "offered: Want me to run the tests?"), now: now)
  input.process = c.process
  input.busy = c.messageWaiting
  return input
}

@Suite struct PromptGuardParityTests {
  @Test func theBaselineAutoContinueInputPassesEveryGuard() {
    let idle = PromptGuardCase(card: nil, process: .running, live: true, turnRunning: false, messageWaiting: false)

    #expect(AutoContinue.blocker(autoContinueInput(idle)) == nil)
  }

  @Test(arguments: PromptGuardCase.all)
  func autoContinueReportsWhatThePromptGuardReports(_ c: PromptGuardCase) {
    let f = c.facts

    let summaryCard = f.sessionSummary != nil ? "an open card" : nil
    let guarded =
      PromptGuard.openCard(f) ?? summaryCard
      ?? PromptGuard.turn(f, process: c.process, messageWaiting: c.messageWaiting)

    #expect(AutoContinue.blocker(autoContinueInput(c)) == guarded)
  }
}
