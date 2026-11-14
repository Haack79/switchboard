import AppKit
import SwiftUI
import SwitchboardCore

/// What a reference's hover card says. Before the first answer it has the
/// header from the reference and a loading line. After a failure it has the
/// header and the error.
struct ReferenceCardContent: Equatable {
  enum Tone: Equatable {
    case green, purple, red, gray
  }

  struct Chip: Equatable {
    var text: String
    var tone: Tone
  }

  struct Row: Equatable, Identifiable {
    var id: String
    var name: String
    var state: AttentionState
  }

  static let maxLabels = 6
  static let notFound = "Not found, or your GitHub token can't see it."

  var repo: String
  var number: Int
  var title: String?
  var chip: Chip?
  /// The author and the times, as `by <author> · opened <ago> ago · updated <ago> ago`.
  var meta: String?
  /// The first `maxLabels` labels.
  var labels: [String] = []
  /// How many labels `labels` leaves out.
  var extraLabels = 0
  /// A PR's checks, review, and mergeability, only while it is open.
  var prLines: [String] = []
  /// The sessions that work on the item, as `ReferenceSessions` finds them.
  var sessions: [Row]
  var loading = false
  var message: String?

  init(_ ref: GitHubRef, load: ReferenceLoad?, sessions: [SessionSummary], now: Int64) {
    repo = ref.repo
    number = ref.number
    self.sessions = ReferenceSessions.matching(ref, in: sessions).map { Row(id: $0.id, name: $0.name, state: $0.state) }
    switch load {
    case nil, .loading?: loading = true
    case .failed(let error)?: message = error.hasSuffix(ReferenceDetails.notFoundText) ? Self.notFound : error
    case .loaded(let d)?:
      repo = d.repo
      number = d.number
      title = d.title
      chip = Self.chip(d)
      let meta = [
        d.author.map { "by \($0)" },
        Self.ago("opened", d.createdAt, now: now),
        Self.ago("updated", d.updatedAt, now: now),
      ].compactMap { $0 }
      self.meta = meta.isEmpty ? nil : meta.joined(separator: " · ")
      labels = Array(d.labels.prefix(Self.maxLabels))
      extraLabels = d.labels.count - labels.count
      if d.kind == .pr, d.state == .open { prLines = Self.prLines(d) }
    }
  }

  private static func chip(_ d: ReferenceDetails) -> Chip {
    switch (d.kind, d.state) {
    case (.issue, .open): Chip(text: "Open issue", tone: .green)
    case (.issue, _): Chip(text: "Closed issue", tone: .purple)
    case (.pr, .open):
      d.draft ? Chip(text: "Draft pull request", tone: .gray) : Chip(text: "Open pull request", tone: .green)
    case (.pr, .merged): Chip(text: "Merged pull request", tone: .purple)
    case (.pr, .closed): Chip(text: "Closed pull request", tone: .red)
    }
  }

  private static func ago(_ verb: String, _ time: String?, now: Int64) -> String? {
    time.flatMap(Transcript.milliseconds).map { "\(verb) \(SwitchboardCore.ago($0, now: now)) ago" }
  }

  private static func prLines(_ d: ReferenceDetails) -> [String] {
    let checks: String? =
      switch d.checks {
      case "SUCCESS"?: "Checks passing"
      case "FAILURE"?, "ERROR"?: "Checks failing"
      case "PENDING"?, "EXPECTED"?: "Checks running"
      default: nil
      }
    let review: String? =
      switch d.reviewDecision {
      case .approved?: "Approved"
      case .changesRequested?: "Changes requested"
      case .reviewRequired?: "Review required"
      case nil: nil
      }
    let mergeable: String? =
      switch d.mergeable {
      case .mergeable?: "No conflicts"
      case .conflicting?: "Conflicts"
      case .unknown?: "Checking mergeability"
      case nil: nil
      }
    return [checks, review, mergeable].compactMap { $0 }
  }
}

/// A reference's hover card. It asks sbd for the details each time it opens,
/// and shows the last answer until the new one comes.
struct ReferenceCardView: View {
  @ObservedObject var model: BoardModel
  let ref: GitHubRef

  var body: some View {
    let c = ReferenceCardContent(
      ref, load: model.referenceDetails[ref.key], sessions: model.allSessions, now: nowMs())
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(header(c)).font(.caption).foregroundStyle(.secondary)
        // The title is plain, so no card opens inside the card.
        if let title = c.title { Text(verbatim: title).font(.headline).lineLimit(2) }
        if let meta = c.meta { Text(verbatim: meta).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
      }
      if let chip = c.chip {
        Text(verbatim: chip.text)
          .font(.caption.weight(.medium))
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Capsule().fill(chip.tone.color.opacity(0.14)))
          .foregroundStyle(chip.tone.color)
      }
      if !c.labels.isEmpty {
        WrappingRow(spacing: 4) {
          ForEach(c.labels, id: \.self) { label in
            Text(verbatim: label).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
              .background(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
          }
          if c.extraLabels > 0 { Text(verbatim: "+\(c.extraLabels)").font(.caption2).foregroundStyle(.secondary) }
        }
      }
      if !c.prLines.isEmpty {
        Text(verbatim: c.prLines.joined(separator: " · ")).font(.caption)
      }
      if c.loading {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Loading…").font(.caption).foregroundStyle(.secondary)
        }
      }
      if let message = c.message {
        Text(verbatim: message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if !c.sessions.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(c.sessions) { row in
            HStack(spacing: 6) {
              StateBadge(state: row.state)
              Text(link(row.name, to: SessionLink.url(for: row.id))).lineLimit(1)
            }
          }
        }
      }
    }
    .hoverCardFrame()
    .task(id: ref.key) { model.loadReference(ref) }
  }

  /// `owner/name #N`, linked to the item on GitHub.
  private func header(_ c: ReferenceCardContent) -> AttributedString {
    link("\(c.repo) #\(c.number)", to: ref.url)
  }

  private func link(_ text: String, to url: URL) -> AttributedString {
    var part = AttributedString(text)
    part.link = url
    return part
  }
}

extension ReferenceCardContent.Tone {
  var color: Color {
    switch self {
    case .green: .green
    case .purple: .purple
    case .red: .red
    case .gray: .secondary
    }
  }
}

extension HoverCard {
  /// The reference card for the app. Its panel takes clicks, so a link in the
  /// card fires before the card would close.
  static func referencePanel(for model: BoardModel) -> HoverCard {
    let panel = HoverCardPanel { [weak model] id in
      guard let model, let ref = GitHubRef(parsing: id) else { return AnyView(EmptyView()) }
      return AnyView(ReferenceCardView(model: model, ref: ref).inlineLinks(model))
    }
    let card = HoverCard(presenter: panel)
    panel.onPointer = { [weak card] inside in if inside { card?.enteredCard() } else { card?.exitedCard() } }
    panel.onPanel = { [weak card] window in card?.clickableWindow = window }
    return card
  }
}

extension GitHubRef {
  /// The reference card's id: `owner/name#N` in the case the text wrote it,
  /// so the card's header shows the repository as written before the details
  /// come. `GitHubRef(parsing:)` reads it back.
  var cardID: String { "\(repo)#\(number)" }
}
