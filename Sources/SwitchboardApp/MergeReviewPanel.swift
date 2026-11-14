import SwiftUI
import SwitchboardCore

/// The "Before you merge" section of a Ready to merge card: one line per
/// review row with a green or amber icon, and a disclosure where the row has
/// more to show. Rows start closed. The threads row opens when a thread holds
/// one of the session's drafts, and again when a thread takes a new draft
/// from the Drafts section, so the draft stays in view. Anyone who can comment on the PR wrote
/// the bodies and excerpts, so they draw as plain text, and their links open
/// only over https.
struct MergeReviewPanel: View {
  let session: SessionSummary
  let item: TriageItem
  let review: MergeReview
  @State private var open: Set<MergeReview.Row>

  init(session: SessionSummary, item: TriageItem, review: MergeReview) {
    self.session = session
    self.item = item
    self.review = review
    _open = State(initialValue: Self.heldDrafts(in: item).isEmpty ? [] : [.threads])
  }

  /// The rows the panel shows, in panel order.
  static func rows(_ review: MergeReview) -> [MergeReview.Line] { review.lines }

  /// A green checkmark, or the warning callout's icon and color.
  static func icon(amber: Bool) -> (name: String, color: Color) {
    guard amber else { return ("checkmark.circle.fill", .green) }
    let style = CalloutView.style(.warning)
    return (style.icon, style.color)
  }

  static func botTag(_ bot: Bool?) -> String? { bot == true ? "bot" : nil }

  /// The URL to open, or nil unless it is https.
  static func link(_ url: String?) -> URL? { url.flatMap(URL.init(httpsOnly:)) }

  /// The drafts that `thread` holds, in the item's order. Only a reply draft
  /// moves into a thread. The Drafts section keeps every other draft.
  static func drafts(_ thread: MergeReview.Thread, in item: TriageItem) -> [InboxDraft] {
    item.drafts.filter { thread.drafts.contains($0.number) && DraftsSection.usesReplyView($0, in: item) }
  }

  /// The numbers of the drafts that the item's shown threads hold.
  static func heldDrafts(in item: TriageItem) -> Set<Int> {
    Set((item.review?.threads?.shown ?? []).flatMap { drafts($0, in: item) }.map(\.number))
  }

  /// VoiceOver can't see the icon's color, so the label says whether the row needs a look.
  static func accessibilityLabel(_ line: MergeReview.Line) -> String {
    "\(line.amber ? "Needs a look" : "OK"): \(line.title)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionTitle(text: "Before you merge")
      ForEach(Self.rows(review), id: \.row) { row($0) }
    }
    .onChange(of: Self.heldDrafts(in: item)) { old, new in
      if !new.isSubset(of: old) { open.insert(.threads) }
    }
  }

  @ViewBuilder
  private func row(_ line: MergeReview.Line) -> some View {
    if line.details.isEmpty {
      header(line)
    } else {
      DisclosureGroup(isExpanded: expanded(line.row)) {
        content(line).padding(.top, 6)
      } label: {
        header(line)
      }
    }
  }

  private func expanded(_ row: MergeReview.Row) -> Binding<Bool> {
    Binding(
      get: { open.contains(row) },
      set: { if $0 { open.insert(row) } else { open.remove(row) } })
  }

  private func header(_ line: MergeReview.Line) -> some View {
    let icon = Self.icon(amber: line.amber)
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: icon.name).foregroundStyle(icon.color)
      Text(verbatim: line.title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.accessibilityLabel(line))
  }

  private func content(_ line: MergeReview.Line) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      switch line.row {
      case .approval:
        if !review.detailsRead { note(MergeReview.notRead) }
        ForEach(Array(review.approvals.enumerated()), id: \.offset) { ApprovalRow(approval: $1) }
      case .threads:
        if let text = review.threadsNote { note(text) }
        ForEach(Array((review.threads?.shown ?? []).enumerated()), id: \.offset) { _, thread in
          ThreadRow(session: session, item: item, thread: thread, drafts: Self.drafts(thread, in: item))
        }
      case .reviewers, .testPlan:
        ForEach(Array(line.details.enumerated()), id: \.offset) { note($1) }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func note(_ text: String) -> some View {
    InlineText(plain: text, links: false).font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
  }
}

/// An approval: who, on which commit, its body, and its first inline comments.
private struct ApprovalRow: View {
  let approval: MergeReview.Approval

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      WrappingRow(spacing: 6) {
        InlineText(plain: approval.author, links: false).fontWeight(.semibold)
        if let tag = MergeReviewPanel.botTag(approval.bot) { BotTag(text: tag) }
        Text(verbatim: approval.place).foregroundStyle(.secondary)
      }
      .font(.callout)
      if let body = approval.body {
        InlineText(plain: body, links: false).font(.callout)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      ForEach(Array(approval.notes.enumerated()), id: \.offset) { _, note in
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: note.line.map { "\(note.path):\($0)" } ?? note.path)
            .font(.caption.monospaced()).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
          InlineText(plain: note.excerpt, links: false).font(.callout).lineLimit(2).textSelection(.enabled)
          if let url = MergeReviewPanel.link(note.url) {
            Link("Open on GitHub", destination: url).font(.caption)
              .accessibilityLabel("Open \(approval.author)'s comment on GitHub")
          }
        }
        .padding(.leading, 10)
      }
      let more = approval.noteCount - approval.notes.count
      if more > 0 {
        Text("\(more) more inline \(more == 1 ? "comment" : "comments") on GitHub")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let url = MergeReviewPanel.link(approval.url) {
        Link("Open the review on GitHub", destination: url).font(.caption)
          .accessibilityLabel("Open \(approval.author)'s review on GitHub")
      }
    }
    .accessibilityElement(children: .contain)
  }
}

/// An open review thread: where, who, whether you replied, its first comment
/// cut to two lines, and the session's drafts that answer it.
private struct ThreadRow: View {
  let session: SessionSummary
  let item: TriageItem
  let thread: MergeReview.Thread
  let drafts: [InboxDraft]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: thread.place).font(.callout.monospaced())
        .lineLimit(1).truncationMode(.middle)
      WrappingRow(spacing: 6) {
        InlineText(plain: thread.author, links: false)
        if let tag = MergeReviewPanel.botTag(thread.bot) { BotTag(text: tag) }
        Text(verbatim: thread.replyLabel).foregroundStyle(.secondary)
      }
      .font(.callout)
      InlineText(plain: thread.excerpt, links: false).font(.callout).foregroundStyle(.secondary)
        .lineLimit(2)
        .textSelection(.enabled)
      if let url = MergeReviewPanel.link(thread.url) {
        Link("Open on GitHub", destination: url).font(.caption)
          .accessibilityLabel("Open \(thread.author)'s thread on GitHub")
      }
      ForEach(drafts, id: \.number) { DraftEntry(session: session, item: item, draft: $0) }
    }
    .accessibilityElement(children: .contain)
  }
}

private struct BotTag: View {
  let text: String

  var body: some View {
    Text(verbatim: text)
      .font(.caption2.bold())
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(Capsule().fill(Color.secondary.opacity(0.15)))
      .foregroundStyle(.secondary)
  }
}
