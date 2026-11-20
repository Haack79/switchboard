import Foundation
import Testing

@testable import SwitchboardApp
@testable import SwitchboardCore

private let shortReply = "The flaky test is unrelated. Do you want me to rerun CI?"
private let longReply = String(repeating: "a", count: Triage.wholeReplyCharacters + 1)
private let decision = PendingDecision(
  number: 1, header: "Name", question: "Hub or Switchboard?",
  options: [PendingDecision.Option(label: "Hub"), PendingDecision.Option(label: "Switchboard", recommended: true)])

/// The callout that sbd's `addReplyAsk` puts first on a rule item whose reply asks something.
private let askCallout = Callout(kind: .decision, title: Triage.replyAskPrefix + "Do you want me to rerun CI?")

private func item(
  _ source: TriageSource, summary: String = "What the model said", callouts: [Callout] = [],
  decisions: [PendingDecision] = []
) -> TriageItem {
  TriageItem(
    title: "Fix Depot CI on #136843", kind: .info, summary: summary, callouts: callouts, decisions: decisions,
    source: source)
}

private func session(lastReply: String?) -> SessionSummary {
  var s = needsItem("s1")
  s.lastReply = lastReply
  return s
}

/// What the Summary shows: `text` with `presentation`.
private func shown(_ presentation: ReplyPresentation, _ text: String) -> DecisionCard.SummaryReply {
  DecisionCard.SummaryReply(presentation: presentation, text: text)
}

/// What the Summary shows of the reply when the transcript read gave `reply`, or nothing was read.
private func summaryReply(
  _ item: TriageItem, lastReply: String?, reply: String? = nil, listOpen: Bool = false
) -> DecisionCard.SummaryReply {
  DecisionCard.summaryReply(
    item: item, session: session(lastReply: lastReply), reply: reply ?? lastReply, listOpen: listOpen)
}

// MARK: Each ReplyPresentation

@Suite struct DecisionCardSummaryReply {
  @Test(arguments: [TriageSource.summary, .fallback])
  func aShortReplyReplacesTheModelsSummary(_ source: TriageSource) {
    #expect(summaryReply(item(source), lastReply: shortReply) == shown(.replacesSummary, shortReply))
  }

  @Test func aShortReplyThatARuleItemAsksAboutShowsUnderTheRulesSummary() {
    let rule = item(.rule, callouts: [askCallout])

    #expect(summaryReply(rule, lastReply: shortReply) == shown(.expanded, shortReply))
  }

  @Test(arguments: [TriageSource.summary, .fallback])
  func aLongReplyShowsBehindAButton(_ source: TriageSource) {
    #expect(summaryReply(item(source), lastReply: longReply) == shown(.collapsed, longReply))
  }

  @Test func aLongReplyThatARuleItemAsksAboutShowsBehindAButton() {
    let rule = item(.rule, callouts: [askCallout])

    #expect(summaryReply(rule, lastReply: longReply) == shown(.collapsed, longReply))
  }

  /// The session wrote its card on purpose, so a short reply never replaces it.
  @Test func aCardThatTheSessionWroteKeepsItsSummaryAndOffersTheReply() {
    #expect(summaryReply(item(.session), lastReply: shortReply) == shown(.collapsed, shortReply))
  }

  @Test func anItemWithDecisionsOffersTheReplyBehindAButton() {
    let decided = item(.summary, decisions: [decision])

    #expect(summaryReply(decided, lastReply: shortReply) == shown(.collapsed, shortReply))
  }

  @Test func anOpenDecisionListOffersTheReplyBehindAButton() {
    #expect(summaryReply(item(.summary), lastReply: shortReply, listOpen: true) == shown(.collapsed, shortReply))
  }

  @Test(arguments: [TriageSource.card, .report])
  func aCardOrAReportShowsNoReply(_ source: TriageSource) {
    #expect(summaryReply(item(source), lastReply: shortReply).presentation == .none)
  }

  /// The reply stays in Details.
  @Test func aRuleItemWhoseReplyAsksNothingShowsNoReply() {
    #expect(summaryReply(item(.rule), lastReply: shortReply).presentation == .none)
  }

  @Test(arguments: [nil, "", "  \n\t "] as [String?])
  func anEmptyOrMissingReplyShowsNothing(_ lastReply: String?) {
    #expect(summaryReply(item(.summary), lastReply: lastReply).presentation == .none)
  }
}

// MARK: The Summary and Details read one reply

@MainActor
@Suite struct DecisionCardReplyParity {
  /// sbd's callout and the app's choice both read the hook's text, so the transcript's length never changes it.
  @Test func theHookTextDecidesShortEvenWhenTheTranscriptTextIsLong() {
    let hook = String(repeating: "h", count: Triage.wholeReplyCharacters)
    let transcript = String(repeating: "t", count: Triage.wholeReplyCharacters + 1)

    #expect(summaryReply(item(.summary), lastReply: hook, reply: transcript) == shown(.replacesSummary, transcript))
  }

  @Test func theHookTextDecidesLongEvenWhenTheTranscriptTextIsShort() {
    let hook = String(repeating: "h", count: Triage.wholeReplyCharacters + 1)
    let transcript = String(repeating: "t", count: Triage.wholeReplyCharacters)

    #expect(summaryReply(item(.summary), lastReply: hook, reply: transcript) == shown(.collapsed, transcript))
  }

  @Test(arguments: [(Triage.wholeReplyLines, true), (Triage.wholeReplyLines + 1, false)])
  func theHookTextsLineCountDecidesShort(_ lines: Int, _ short: Bool) {
    let hook = (1...lines).map { "line \($0)" }.joined(separator: "\n")
    let transcript = (1...(short ? lines + 5 : 2)).map { "step \($0)" }.joined(separator: "\n")

    let expected = shown(short ? .replacesSummary : .collapsed, transcript)
    #expect(summaryReply(item(.summary), lastReply: hook, reply: transcript) == expected)
  }

  @Test func anEmptyHookTextShowsNoReplyEvenWithTranscriptText() {
    #expect(summaryReply(item(.summary), lastReply: "  \n", reply: shortReply).presentation == .none)
  }

  @Test func withoutATranscriptReadTheSummaryShowsTheHookText() {
    let summary = DecisionCard.summaryReply(
      item: item(.summary), session: session(lastReply: shortReply), reply: nil, listOpen: false)

    #expect(summary == shown(.replacesSummary, shortReply))
  }

  /// A read for an earlier reply must not put old text in the Summary or in Details.
  @Test func theSummaryAndDetailsShowTheNewReplyWhenTheReadIsForAnEarlierOne() {
    let model = offlineModel()
    model.replies["s1"] = (hook: "Ship it?", text: "Done. Ship it?")
    let current = session(lastReply: "Fix it?!")

    let reply = model.reply(for: current)
    let summary = DecisionCard.summaryReply(item: item(.summary), session: current, reply: reply, listOpen: false)

    #expect(summary == shown(.replacesSummary, "Fix it?!"))
    #expect(CardDetails.lastReply(context: nil, reply: reply) == "Fix it?!")
  }

  @Test func theSummaryAndDetailsShowTheTranscriptTextOfTheCurrentReply() {
    let model = offlineModel()
    model.replies["s1"] = (hook: "Ship it?", text: "Done. Ship it?")
    let current = session(lastReply: "Ship it?")

    let reply = model.reply(for: current)
    let summary = DecisionCard.summaryReply(item: item(.summary), session: current, reply: reply, listOpen: false)

    #expect(summary == shown(.replacesSummary, "Done. Ship it?"))
    #expect(CardDetails.lastReply(context: nil, reply: reply) == "Done. Ship it?")
  }
}

// MARK: The Summary's text

@Suite struct DecisionCardSummaryText {
  @Test func aReplyThatReplacesTheSummaryIsTheSummarysText() {
    #expect(DecisionCard.summaryText(item(.summary), reply: shown(.replacesSummary, shortReply)) == shortReply)
  }

  @Test(arguments: [ReplyPresentation.none, .expanded, .collapsed])
  func anyOtherReplyLeavesTheItemsSummary(_ presentation: ReplyPresentation) {
    #expect(DecisionCard.summaryText(item(.summary), reply: shown(presentation, shortReply)) == "What the model said")
  }
}

// MARK: "No summary yet" under a reply that replaces the summary

@Suite struct DecisionCardMissingSummaryReply {
  private let empty = TriageItem(title: "Read its last reply", kind: .info, summary: "", source: .fallback)

  /// The Summary shows the reply, so the Action must not say that there is no summary.
  @Test func aReplyThatReplacesTheSummaryHidesTheMissingSummaryLine() {
    #expect(!DecisionCard.showsMissingSummary(empty, reply: .replacesSummary))
  }

  @Test(arguments: [ReplyPresentation.none, .expanded, .collapsed])
  func aReplyThatDoesNotReplaceTheSummaryKeepsTheLine(_ reply: ReplyPresentation) {
    #expect(DecisionCard.showsMissingSummary(empty, reply: reply))
  }
}
