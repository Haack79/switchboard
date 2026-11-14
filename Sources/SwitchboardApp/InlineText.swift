import AppKit
import SwiftUI
import SwitchboardCore
import os

/// Draws inline text that sbd or Claude wrote, with each session id that
/// resolves drawn as the session's name and each GitHub issue or pull request
/// reference drawn as a link. `links` is false where the text sits inside a
/// button's label, because a link there gets no click.
struct InlineText: View {
  @Environment(\.sessionNames) private var names
  @Environment(\.referenceRepo) private var repo
  @Environment(\.referenceCard) private var card
  @Environment(\.referenceRects) private var rects
  let text: MarkdownText
  let links: Bool

  init(_ text: MarkdownText, links: Bool = true) {
    self.text = text
    self.links = links
  }

  /// A plain string, drawn as one unstyled run. No Markdown in it is parsed.
  init(plain: String, links: Bool = true) {
    self.init(MarkdownText(stringLiteral: plain), links: links)
  }

  var body: some View {
    let (segments, help) = Self.segments(text, names: names, repo: repo, links: links)
    if let help { content(segments).help(help) } else { content(segments) }
  }

  /// Only a text that can open a card, or that a test reads the rects of,
  /// records where its references sit.
  @ViewBuilder private func content(_ segments: [Segment]) -> some View {
    if #available(macOS 15, *), card != nil || rects != nil, segments.contains(where: { $0.reference != nil }) {
      ReferenceText(segments: segments, card: card, injected: rects)
    } else {
      Text(Self.joined(segments))
    }
  }

  /// A stretch of the drawn text. `reference` is set only on a reference
  /// that links, and its `part` is the reference's index among the text's
  /// pieces.
  struct Segment {
    var text: AttributedString
    var reference: ReferenceAttribute?
  }

  static func joined(_ segments: [Segment]) -> AttributedString {
    segments.reduce(into: AttributedString()) { $0 += $1.text }
  }

  /// The text with each matched id swapped for the session's name. With
  /// `links`, a live session's name links to the session, and `help` lists
  /// each swapped session as `name: id`, once each, in the order the text
  /// names them. A removed session's name never links. With `links`, a
  /// reference links to its issue or pull request, and a bare `#123` refers
  /// to `repo`. Without `links`, a reference has no link, even one that its
  /// Markdown gave it.
  static func attributed(_ text: MarkdownText, names: SessionNames, repo: String?, links: Bool) -> (
    AttributedString, help: String?
  ) {
    let (segments, help) = segments(text, names: names, repo: repo, links: links)
    return (joined(segments), help)
  }

  /// `attributed`'s text, split so that each reference that links is a
  /// segment of its own. Text between references joins into one segment.
  static func segments(_ text: MarkdownText, names: SessionNames, repo: String?, links: Bool) -> (
    [Segment], help: String?
  ) {
    var segments: [Segment] = []
    var lines: [String] = []
    var listed: Set<String> = []
    for (index, piece) in InlineMentions(names: names, repo: repo).pieces(text).enumerated() {
      var part = MarkdownText.attributed(piece.run)
      var reference: ReferenceAttribute?
      switch piece.mention {
      case .session(let match)? where links:
        if !match.removed { part.link = SessionLink.url(for: match.id) }
        if listed.insert(match.id).inserted {
          lines.append("\(match.name): \(match.id)" + (match.removed ? ", removed" : ""))
        }
      case .reference(let ref)? where links: reference = ReferenceAttribute(ref: ref, part: index)
      case .reference?: part.link = nil
      case .session?, nil: break
      }
      if reference == nil, let last = segments.last, last.reference == nil {
        segments[segments.count - 1].text += part
      } else {
        segments.append(Segment(text: part, reference: reference))
      }
    }
    return (segments, lines.isEmpty ? nil : lines.joined(separator: "\n"))
  }

  /// The repository that a bare `#123` in text about `session` refers to. The
  /// PR's repository wins over the checkout's, because a fork checkout's
  /// origin names the fork, while the numbers in the work refer to the PR's
  /// base repository.
  static func referenceRepo(for session: SessionSummary) -> String? { session.pr?.repo ?? session.repository }
}

extension MarkdownText {
  /// The text with its styles as presentation intents, and its links. `Text`
  /// draws presentation intents in the font around it.
  var attributed: AttributedString { runs.reduce(into: AttributedString()) { $0 += Self.attributed($1) } }

  static func attributed(_ run: Run) -> AttributedString {
    var part = AttributedString(run.text.isEmpty ? run.image ?? "" : run.text)
    var intent: InlinePresentationIntent = []
    if run.style.contains(.emphasis) { intent.insert(.emphasized) }
    if run.style.contains(.strong) { intent.insert(.stronglyEmphasized) }
    if run.style.contains(.code) { intent.insert(.code) }
    if run.style.contains(.strikethrough) { intent.insert(.strikethrough) }
    if !intent.isEmpty { part.inlinePresentationIntent = intent }
    if run.style.contains(.footnote) {
      part.baselineOffset = 6
      part.font = .caption2
    }
    if let link = (run.link ?? run.image).flatMap(URL.init(string:)) { part.link = link }
    return part
  }
}

/// The URL of a link to a session. Only the app's own views see the scheme,
/// because it is not registered with Launch Services.
enum SessionLink {
  private static let prefix = "switchboard-session:"

  /// `id` is a session id, so the string always parses as a URL.
  static func url(for id: String) -> URL { URL(string: prefix + id)! }

  /// The session id of a link that `url(for:)` made, else nil.
  static func id(from url: URL) -> String? {
    let string = url.absoluteString
    guard string.hasPrefix(prefix) else { return nil }
    let id = String(string.dropFirst(prefix.count))
    return SessionNames.isSessionID(id) ? id : nil
  }
}

private struct SessionNamesKey: EnvironmentKey {
  static let defaultValue = SessionNames.empty
}

private struct ReferenceRepoKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

private struct ReferenceRectsKey: EnvironmentKey {
  static let defaultValue: ReferenceRects? = nil
}

private struct ReferenceCardKey: EnvironmentKey {
  static let defaultValue: HoverCard? = nil
}

extension EnvironmentValues {
  /// The directory that `InlineText` resolves session ids with. A host that
  /// never sets it draws the ids as written.
  var sessionNames: SessionNames {
    get { self[SessionNamesKey.self] }
    set { self[SessionNamesKey.self] = newValue }
  }

  /// The `owner/name` that a bare `#123` in `InlineText` refers to. Only a
  /// view about one session sets it. Without it, or with a name that is not
  /// a valid repository, a bare `#123` draws as plain text.
  var referenceRepo: String? {
    get { self[ReferenceRepoKey.self] }
    set { self[ReferenceRepoKey.self] = newValue }
  }

  /// Where `InlineText` records the rects of its references. Tests set it to
  /// read them. Without it, each text keeps its own.
  var referenceRects: ReferenceRects? {
    get { self[ReferenceRectsKey.self] }
    set { self[ReferenceRectsKey.self] = newValue }
  }

  /// The card that opens while the pointer rests on a reference in `InlineText`.
  var referenceCard: HoverCard? {
    get { self[ReferenceCardKey.self] }
    set { self[ReferenceCardKey.self] = newValue }
  }
}

extension View {
  /// Gives `InlineText` the model's session names and reference card, and
  /// opens a session link through `reveal`. Every other URL goes to the system.
  func inlineLinks(_ model: BoardModel) -> some View {
    environment(\.sessionNames, model.sessionNames)
      .environment(\.referenceCard, model.referenceCard)
      .environment(\.openURL, OpenURLAction { model.openSessionLink($0) ? .handled : .systemAction })
  }

  /// Makes a bare `#123` in this view's `InlineText` refer to `session`'s
  /// repository.
  func referenceRepo(_ session: SessionSummary) -> some View {
    environment(\.referenceRepo, InlineText.referenceRepo(for: session))
  }
}

/// Tags a reference's segment, so the renderer can find its runs.
struct ReferenceAttribute: Hashable {
  let ref: GitHubRef
  /// The reference's index among the text's pieces. The same reference
  /// written twice has two parts.
  let part: Int
}

@available(macOS 15, *)
extension ReferenceAttribute: TextAttribute {}

/// The rects of the references that a text drew last, in the text's own
/// coordinates, with y growing down. The renderer writes them while it draws,
/// so a lock guards them. SwiftUI does not observe this box, so a write starts
/// no update.
final class ReferenceRects: Sendable {
  struct Entry: Equatable, Sendable {
    var ref: GitHubRef
    var part: Int
    var rect: CGRect

    var key: String { ref.key }
  }

  private let state = OSAllocatedUnfairLock(initialState: [Entry]())

  var entries: [Entry] { state.withLock { $0 } }

  func record(_ entries: [Entry]) { state.withLock { $0 = entries } }
}

/// The text, with a twin behind it that records where each reference sits.
/// SwiftUI does not run a `TextRenderer` on selectable text, and `MarkdownView`
/// makes its text selectable. The twin is not selectable, draws nothing, and
/// gets the text's size as its proposal, so its lines break where the text's
/// lines break.
///
/// The pointer resting on a reference's rect opens the reference card below
/// that rect.
@available(macOS 15, *)
private struct ReferenceText: View {
  @State private var own = ReferenceRects()
  @State private var hover = ReferenceHover()
  let segments: [InlineText.Segment]
  let card: HoverCard?
  let injected: ReferenceRects?

  var body: some View {
    let rects = injected ?? own
    text
      .background {
        text.textRenderer(ReferenceRenderer(rects: rects))
          .textSelection(.disabled)
          .accessibilityHidden(true)
          .allowsHitTesting(false)
      }
      .background(ReferenceAnchor(hover: hover, rects: rects, card: card))
      .onContinuousHover(coordinateSpace: .local) { phase in
        switch phase {
        case .active(let point): hover.moved(to: point, in: rects.entries, card: card)
        case .ended: hover.moved(to: nil, in: [], card: card)
        }
      }
  }

  /// One `Text` per segment, joined by interpolation, because the SDK
  /// deprecates `Text` concatenation. One flat interpolation keeps a long
  /// text from nesting deeply.
  private var text: Text {
    var joined = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: segments.count)
    for segment in segments {
      let part = Text(segment.text)
      joined.appendInterpolation(segment.reference.map { part.customAttribute($0) } ?? part)
    }
    return Text(LocalizedStringKey(stringInterpolation: joined))
  }
}

/// Draws nothing, and records the bounds of each run that carries a
/// `ReferenceAttribute`. Runs of one part on one line join into one rect.
@available(macOS 15, *)
private struct ReferenceRenderer: TextRenderer {
  let rects: ReferenceRects

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    var entries: [ReferenceRects.Entry] = []
    for line in layout {
      let lineStart = entries.count
      for run in line {
        guard let tag = run[ReferenceAttribute.self] else { continue }
        let rect = run.typographicBounds.rect
        if entries.count > lineStart, entries[entries.count - 1].part == tag.part {
          entries[entries.count - 1].rect = entries[entries.count - 1].rect.union(rect)
        } else {
          entries.append(ReferenceRects.Entry(ref: tag.ref, part: tag.part, rect: rect))
        }
      }
    }
    rects.record(entries)
  }
}

/// Turns the pointer's moves over a text into enters and exits of the
/// reference card, one per reference.
@MainActor
final class ReferenceHover {
  weak var view: ReferenceAnchorView?
  private var current: (id: String, anchor: HoverAnchor)?

  /// Reports a reference only when the pointer reaches another one, or when
  /// the one under it moved, because each enter restarts the card's delay.
  func moved(to point: CGPoint?, in entries: [ReferenceRects.Entry], card: HoverCard?) {
    guard let card, let view else { return }
    let next = point.flatMap { point in entries.first { $0.rect.contains(point) } }
      .map { (id: $0.ref.cardID, anchor: HoverAnchor(view: view, part: $0.part, rect: $0.rect)) }
    if next?.anchor == current?.anchor, next?.anchor.rect == current?.anchor.rect { return }
    let previous = current
    current = next
    // The card expects the next reference's enter before the last one's exit.
    if let next { card.entered(next.id, anchor: next.anchor) }
    if let previous, previous.anchor != next?.anchor { card.exited(previous.id, anchor: previous.anchor) }
  }

  /// Forgets the reference under the pointer, after the text left its window.
  func reset() { current = nil }
}

/// The view that a reference's card sits below. It covers the text, so a
/// recorded rect is already in its coordinates.
private struct ReferenceAnchor: NSViewRepresentable {
  let hover: ReferenceHover
  let rects: ReferenceRects
  let card: HoverCard?

  func makeNSView(context: Context) -> ReferenceAnchorView {
    let view = ReferenceAnchorView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: ReferenceAnchorView, context: Context) {
    view.card = card
    view.rects = rects
    view.hover = hover
    hover.view = view
  }
}

final class ReferenceAnchorView: NSView {
  weak var card: HoverCard?
  weak var hover: ReferenceHover?
  var rects: ReferenceRects?

  /// SwiftUI records rects with y growing down.
  override var isFlipped: Bool { true }

  /// The text gets every click and every selection drag.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      hover?.reset()
      card?.disappeared(anchor: HoverAnchor(view: self))
      return
    }
    guard let key = Snapshot.hoverReference else { return }
    // The text records its rects when it first draws.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, self.window != nil, let card = self.card, card.shown == nil,
        let entry = self.rects?.entries.first(where: { $0.key == key })
      else { return }
      card.pin(entry.ref.cardID, below: HoverAnchor(view: self, part: entry.part, rect: entry.rect))
    }
  }
}
