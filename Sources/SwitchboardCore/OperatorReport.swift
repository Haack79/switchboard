import Foundation

/// A report that the operator recorded with `sb operator report` or the MCP `report` tool.
public struct OperatorReport: Codable, Equatable, Sendable {
  /// The kind of the event that records a report.
  public static let event = "report"

  /// The id of the report's event.
  public var id: Int64
  /// When the report was recorded, from its event.
  public var t: Int64
  public var text: String
  /// Whether the report asks the user, so that it stays in the Inbox until the user answers it.
  public var needsYou: Bool
  /// The id of the session that the report is about.
  public var about: String?

  public init?(_ event: Event) {
    guard event.kind == OperatorReport.event, let text = event.data["text"]?.string else { return nil }
    id = event.id
    t = event.t
    self.text = text
    needsYou = event.data["needsYou"]?.bool == true
    about = event.data["about"]?.string
  }

  /// The reason line of the open reports: the latest one's text, and how many others are open. `reports` is not empty.
  static func reason(_ reports: [OperatorReport]) -> String {
    let more = reports.count - 1
    let suffix = more > 0 ? " (and \(more) more)" : ""
    return oneLine(reports.last!.text, max: 70 - suffix.count) + suffix
  }
}

extension SessionFacts {
  /// Whether an `ack` now would close open reports. An ack doesn't close any reports while a prompt blocks the session.
  public var ackClosesReports: Bool {
    !openReports.isEmpty
      && !Triage.hasBlockingPrompt(cards: cards, openPrompt: openPermission != nil || openQuestion != nil)
  }

  /// Keeps the `needsYou` reports that are open. A message that the user wrote closes the reports recorded
  /// before it. Only a `sent` event whose `by` is `you` closes them. A message from sbd or from a Claude Code
  /// closes none. A `sent` that names no author closes none either. An `ack` closes them too, unless a
  /// prompt blocks the session: the Inbox then shows that prompt, so the user did not see the reports.
  /// The reports that an `ack` closes replace `acknowledgedReports`. An `unack` reopens them.
  mutating func applyReports(_ event: Event) {
    switch event.kind {
    case OperatorReport.event:
      guard let report = OperatorReport(event), report.needsYou else { return }
      openReports.append(report)
      acknowledgedReports = []
      // A report that repeats an acknowledged reason is a new item.
      acknowledgment = nil
    case "sent" where event.data["by"]?.string == MessageAuthor.you.rawValue:
      openReports = []
      acknowledgedReports = []
    case "ack" where ackClosesReports:
      acknowledgedReports = openReports
      openReports = []
    case "ack":
      acknowledgedReports = []
    case "unack":
      // An ack that closed no reports leaves the open ones, and its unack keeps them.
      openReports.insert(contentsOf: acknowledgedReports, at: 0)
      acknowledgedReports = []
    default:
      break
    }
  }
}

extension Attention {
  /// Needs you while `reports` has an open report, with the latest report's text as the reason.
  static func reportVerdict(_ reports: [OperatorReport]) -> Verdict? {
    guard !reports.isEmpty else { return nil }
    return Verdict(state: .needsYou, reason: OperatorReport.reason(reports), kind: .question)
  }

  /// The verdict that the app and `sb` show for a session of `kind`. It also marks the operator's verdict
  /// `acknowledged` while the operator has no item and an `unack` would reopen reports. The app then offers Undo
  /// Acknowledge, and `sb ack --undo` accepts it. This mark has no recheck time, because closed reports never
  /// come back on their own. It keeps the verdict's state, because the operator is not in the Inbox without an item.
  public static func shown(
    _ verdict: Verdict, _ facts: SessionFacts, now: Int64, acknowledgedMs: Int64, kind: SessionKind
  ) -> Verdict {
    var out = shown(verdict, facts, now: now, acknowledgedMs: acknowledgedMs)
    if kind == .operator, !facts.acknowledgedReports.isEmpty, Triage.operatorItem(facts, verdict) == nil {
      out.acknowledged = true
    }
    return out
  }
}

extension Triage {
  /// The operator's item: a blocking prompt's, then the open reports', then the wait rule's Needs you.
  static func operatorItem(_ facts: SessionFacts, _ verdict: Verdict) -> TriageItem? {
    if let item = promptItem(facts, verdict) { return item }
    guard AttentionState.inbox.contains(verdict.state) else { return nil }
    if !facts.openReports.isEmpty { return reportItem(facts.openReports) }
    guard verdict.byWaitRule else { return nil }
    var item = ruleItem(verdict)
    item.ref = Triage.ruleRef(item.title)
    return item
  }

  /// The item of the open reports. It lists the oldest ones up to `TriageCard.summaryLines` and counts the
  /// rest. Its ref names the latest report, so a click never answers a report that the user did not see.
  /// `reports` is not empty.
  static func reportItem(_ reports: [OperatorReport]) -> TriageItem {
    let listed = reports.prefix(TriageCard.summaryLines).map(\.text)
    let rest = reports.count - listed.count
    return TriageItem(
      title: title(OperatorReport.reason(reports)), kind: .question,
      summary: (listed + (rest > 0 ? ["and \(rest) more"] : [])).joined(separator: "\n"),
      options: [TriageOption(label: "Reply", action: .reply, placeholder: "Your answer to the operator")],
      source: .report, ref: "report:\(reports.last!.id)")
  }
}
