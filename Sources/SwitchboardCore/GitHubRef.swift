import Foundation

/// A GitHub issue or pull request named by `owner/name#123` or by its URL.
public struct GitHubRef: Equatable, Hashable, Sendable {
  /// Where the reference came from. GitHub numbers issues and pull requests
  /// together and sends `/issues/N` on to the pull request, so only a
  /// `/pull/` URL tells the kind.
  public enum Form: Equatable, Hashable, Sendable {
    case pullURL
    case issueURL
    case shorthand
  }

  /// `owner/name` as written. It passes `Issues.validRepo`.
  public let repo: String
  public let number: Int
  public let form: Form

  private init(repo: String, number: Int, form: Form) {
    self.repo = repo
    self.number = number
    self.form = form
  }

  /// `repo#number` when `repo` passes `Issues.validRepo` and `number` has 1 to 9 digits and is not 0.
  public init?(repo: String, number: Int) {
    guard Issues.validRepo(repo), Issues.number(String(number)) != nil else { return nil }
    self.init(repo: repo, number: number, form: .shorthand)
  }

  /// Reads `owner/name#123`, or a URL that `init(url:)` reads. Spaces and tabs around the text are dropped.
  public init?(parsing text: String) {
    self.init(trimmed: text.trimmingCharacters(in: .whitespaces))
  }

  /// `init(parsing:)` without the trim, for a caller that trimmed the text before it dropped a prefix. A second
  /// trim after `pr:` would accept `pr: owner/name#1`.
  init?(trimmed text: String) {
    if text.contains("://") {
      self.init(url: text)
      return
    }
    guard let hash = text.firstIndex(of: "#") else { return nil }
    let repo = String(text[..<hash])
    guard Issues.validRepo(repo), let number = Issues.number(String(text[text.index(after: hash)...])) else {
      return nil
    }
    self.init(repo: repo, number: number, form: .shorthand)
  }

  /// Reads `http` or `https` `github.com/owner/name/issues/123` or `/pull/123`,
  /// in any case, which may end in a further path, a query, or a fragment.
  public init?(url text: String) {
    guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased()),
      url.host?.lowercased() == "github.com"
    else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    guard parts.count >= 4 else { return nil }
    let form: Form
    switch parts[2] {
    case "issues": form = .issueURL
    case "pull": form = .pullURL
    default: return nil
    }
    let repo = "\(parts[0])/\(parts[1])"
    guard Issues.validRepo(repo), let number = Issues.number(parts[3]) else { return nil }
    self.init(repo: repo, number: number, form: form)
  }

  public var isPull: Bool { form == .pullURL }

  /// The lowercased `owner/name#123`. GitHub compares repository names without case.
  public var key: String { InboxIssue.id(repo, number) }

  /// The item's page. An issue URL reaches a pull request too, because GitHub redirects it.
  public var url: URL {
    // `repo` holds only ASCII letters, digits, `_`, `.`, and `-`, so the string always parses.
    URL(string: "https://github.com/\(repo)/\(isPull ? "pull" : "issues")/\(number)")!
  }
}

// MARK: - References in text

extension GitHubRef {
  /// Whether a reference in text may name `repo`: it passes `Issues.validRepo`,
  /// and its owner and name each hold an ASCII letter, so `1/2#3` names nothing.
  static func isLinkableRepo(_ repo: String) -> Bool {
    Issues.validRepo(repo) && repo.split(separator: "/").allSatisfy { $0.contains { $0.isASCII && $0.isLetter } }
  }

  /// Reads a URL that `init(url:)` reads, and only when the page it opens is
  /// the item's: `github.com` follows the scheme with no user or port, and the
  /// path before any query or fragment holds no `%` or `\`, no empty segment
  /// before the number, and no `.` or `..` segment. The number has no leading
  /// zero, and the owner and name pass `isLinkableRepo`.
  public init?(linkableURL text: String) {
    guard let scheme = text.range(of: "://"), ["http", "https"].contains(text[..<scheme.lowerBound].lowercased()),
      URL(string: text) != nil
    else { return nil }
    let host = text[scheme.upperBound...]
    guard host.prefix(11).lowercased() == "github.com/" else { return nil }
    let path = host.dropFirst(10).prefix { $0 != "?" && $0 != "#" }
    let segments = Array(path.split(separator: "/", omittingEmptySubsequences: false).dropFirst())
    guard segments.count >= 4, segments.prefix(4).allSatisfy({ !$0.isEmpty }),
      !segments.contains(where: { $0 == "." || $0 == ".." }), !path.contains("%"), !path.contains("\\"),
      segments[3].first != "0"
    else { return nil }
    let form: Form
    switch segments[2] {
    case "issues": form = .issueURL
    case "pull": form = .pullURL
    default: return nil
    }
    let repo = "\(segments[0])/\(segments[1])"
    guard Self.isLinkableRepo(repo), let number = Issues.number(String(segments[3])) else { return nil }
    self.init(repo: repo, number: number, form: form)
  }

  /// The link for this reference written as `text`: the text itself when it
  /// is an https URL, so that an anchor such as `#issuecomment-1` survives,
  /// else `url`.
  func link(writtenAs text: String) -> String {
    text.hasPrefix("https://") && URL(string: text) != nil ? text : url.absoluteString
  }

  /// The references and URLs in `s[range]`, the scalars of one run whose text
  /// may link. A bare `#123` refers to `repo` and gives nothing when `repo`
  /// is nil. Every URL gives a span that no other span may overlap, with no
  /// mention when it names no issue or pull request.
  static func spans(in range: Range<Int>, _ s: [Unicode.Scalar], repo: String?) -> [InlineMentions.Span] {
    var spans: [InlineMentions.Span] = []
    var i = range.lowerBound
    while i < range.upperBound {
      if let (end, cut) = urlEnd(at: i, before: range.upperBound, s) {
        // A URL counts even when a word touches its scheme, but only one that stands alone is a reference.
        let ref =
          !cut && (i == 0 || TokenBoundary.allowedBefore(s[i - 1]))
          ? GitHubRef(linkableURL: String(String.UnicodeScalarView(s[i..<end]))) : nil
        spans.append(.reference(i..<end, ref, isURL: true))
        i = end
      } else if s[i] == "#", let (covered, ref) = shorthand(at: i, in: range, s, repo: repo) {
        spans.append(.reference(covered, ref))
        i = covered.upperBound
      } else {
        i += 1
      }
    }
    return spans
  }

  /// The `#123` or `owner/name#123` whose `#` sits at `hash`, when it is a
  /// whole token: the number has 1 to 9 ASCII digits and no leading zero, and
  /// `TokenBoundary` allows the scalars on each side.
  private static func shorthand(at hash: Int, in range: Range<Int>, _ s: [Unicode.Scalar], repo: String?)
    -> (Range<Int>, GitHubRef)?
  {
    var end = hash + 1
    while end < range.upperBound, ("0"..."9").contains(s[end]) { end += 1 }
    let digits = String(String.UnicodeScalarView(s[hash + 1..<end]))
    guard digits.first != "0", let number = Issues.number(digits), TokenBoundary.allowedAfter(end, s) else {
      return nil
    }
    // The token extends back over every scalar that `Issues.validRepo` allows, so `a/b/c#1` reads as one token and fails.
    var start = hash
    while start > range.lowerBound, isRepoScalar(s[start - 1]) { start -= 1 }
    guard start == 0 || TokenBoundary.allowedBefore(s[start - 1]) else { return nil }
    if start == hash {
      guard let repo else { return nil }
      return (hash..<end, GitHubRef(repo: repo, number: number, form: .shorthand))
    }
    let written = String(String.UnicodeScalarView(s[start..<hash]))
    guard isLinkableRepo(written) else { return nil }
    return (start..<end, GitHubRef(repo: written, number: number, form: .shorthand))
  }

  private static func isRepoScalar(_ c: Unicode.Scalar) -> Bool {
    c.isASCII && (c.properties.isAlphabetic || ("0"..."9").contains(c) || "_.-/".unicodeScalars.contains(c))
  }

  /// Where the URL whose `http://` or `https://` scheme starts at `i` ends,
  /// read as cmark-gfm ends an autolink: at ASCII whitespace, `<`, or the end
  /// of the run, and then without trailing `?!.,:*_~'"`, without a trailing
  /// `)` while the URL holds more `)` than `(`, and without a trailing `;` or
  /// `&entity;`. `cut` is true when the URL runs on into the next run, so
  /// that its text in this run is not all of it. nil when no scheme starts at `i`.
  private static func urlEnd(at i: Int, before limit: Int, _ s: [Unicode.Scalar]) -> (end: Int, cut: Bool)? {
    guard var http = spells("http", at: i, before: limit, s) else { return nil }
    if http < limit, s[http] == "s" || s[http] == "S" { http += 1 }
    guard let schemeEnd = spells("://", at: http, before: limit, s) else { return nil }
    var end = schemeEnd
    var opening = 0
    var closing = 0
    while end < limit, !isASCIISpace(s[end]), s[end] != "<" {
      if s[end] == "(" { opening += 1 } else if s[end] == ")" { closing += 1 }
      end += 1
    }
    let cut = end == limit && limit < s.count && !isASCIISpace(s[limit]) && s[limit] != "<"
    trimming: while end > schemeEnd {
      switch s[end - 1] {
      case ")":
        guard closing > opening else { break trimming }
        closing -= 1
        end -= 1
      case "?", "!", ".", ",", ":", "*", "_", "~", "'", "\"":
        end -= 1
      case ";":
        var entity = end - 2
        while entity > schemeEnd, s[entity].isASCII, s[entity].properties.isAlphabetic { entity -= 1 }
        end = entity < end - 2 && s[entity] == "&" ? entity : end - 1
      default:
        break trimming
      }
    }
    return (end, cut)
  }

  /// The index after `word` when `s` spells it at `i`, ignoring ASCII case.
  private static func spells(_ word: String, at i: Int, before limit: Int, _ s: [Unicode.Scalar]) -> Int? {
    var j = i
    for c in word.unicodeScalars {
      guard j < limit, s[j] == c || (s[j].value ^ 0x20 == c.value && s[j].properties.isAlphabetic) else {
        return nil
      }
      j += 1
    }
    return j
  }

  private static func isASCIISpace(_ c: Unicode.Scalar) -> Bool {
    c == " " || c == "\t" || c == "\n" || c == "\u{0B}" || c == "\u{0C}" || c == "\r"
  }
}
