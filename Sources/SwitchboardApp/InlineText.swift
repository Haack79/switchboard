import SwiftUI
import SwitchboardCore

/// Draws inline text that sbd or Claude wrote, with each session id that
/// resolves drawn as the session's name and each GitHub issue or pull request
/// reference drawn as a link. `links` is false where the text sits inside a
/// button's label, because a link there gets no click.
struct InlineText: View {
  @Environment(\.sessionNames) private var names
  @Environment(\.referenceRepo) private var repo
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
    let (attributed, help) = Self.attributed(text, names: names, repo: repo, links: links)
    if let help { Text(attributed).help(help) } else { Text(attributed) }
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
    var result = AttributedString()
    var lines: [String] = []
    var listed: Set<String> = []
    for piece in InlineMentions(names: names, repo: repo).pieces(text) {
      var part = MarkdownText.attributed(piece.run)
      switch piece.mention {
      case .session(let match)? where links:
        if !match.removed { part.link = SessionLink.url(for: match.id) }
        if listed.insert(match.id).inserted {
          lines.append("\(match.name): \(match.id)" + (match.removed ? ", removed" : ""))
        }
      case .reference? where !links: part.link = nil
      case .session?, .reference?, nil: break
      }
      result += part
    }
    return (result, lines.isEmpty ? nil : lines.joined(separator: "\n"))
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
}

extension View {
  /// Gives `InlineText` the model's session names, and opens a session link
  /// through `reveal`. Every other URL goes to the system.
  func sessionLinks(_ model: BoardModel) -> some View {
    environment(\.sessionNames, model.sessionNames)
      .environment(\.openURL, OpenURLAction { model.openSessionLink($0) ? .handled : .systemAction })
  }

  /// Makes a bare `#123` in this view's `InlineText` refer to `session`'s
  /// repository.
  func referenceRepo(_ session: SessionSummary) -> some View {
    environment(\.referenceRepo, InlineText.referenceRepo(for: session))
  }
}
