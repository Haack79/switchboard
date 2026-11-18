import Foundation

/// What the merge card says about a PR beyond its status: its size, its
/// review threads, its reviews, and its description. The poller reads them
/// for a PR at a merge decision, once per head commit and again on each
/// status read. It reads them once per head commit for a PR that a review
/// nudge quotes.
public struct MergeDetails: Codable, Equatable, Sendable {
  public var additions: Int
  public var deletions: Int
  public var changedFiles: Int
  /// GitHub's count of the PR's review threads.
  public var threads: Int
  /// How many threads the read holds. GitHub answers at most
  /// `GitHub.maxThreads`, so this can be less than `threads`.
  public var threadsRead: Int
  /// The unresolved threads among those read.
  public var openThreads: Int
  /// The body without its templates, checklists, and boilerplate, as plain
  /// text, at most `maxDescription` characters.
  public var description: String
  /// The body's first sentences, which the card shows until a model writes
  /// its summary. nil when the body has none.
  public var gist: String?
  /// The test plan's unchecked items, and its sentences that say something
  /// was not tested or not run.
  public var testGaps: [String]
  /// The first `maxThreadDetails` unresolved threads among those read, in
  /// GitHub's order. nil when the read left out the comments of an open
  /// thread.
  public var threadDetails: [ThreadDetail]?
  /// The latest approval or change request of each reviewer, in GitHub's
  /// order. nil when the read lacks them.
  public var reviews: [ReviewDetail]?

  /// Whether the read found an open thread or left some threads unread.
  public var mayHaveOpenThreads: Bool { openThreads > 0 || threadsRead < threads }

  /// An unresolved review thread and its first comment.
  public struct ThreadDetail: Codable, Equatable, Sendable {
    /// The first comment's id, as `ReplyTarget.parse` reads it from `url`.
    /// nil when the URL doesn't name a review comment.
    public var rootId: Int64?
    /// The first comment's URL.
    public var url: String
    public var path: String
    /// The line on the head, or on the commit where the comment was made
    /// when the thread is outdated.
    public var line: Int?
    public var outdated: Bool
    /// The first comment's author. A GitHub App's login has no [bot] suffix.
    public var author: String
    /// true when a GitHub App wrote the first comment, and nil otherwise.
    public var bot: Bool?
    /// The first comment on one line, at most `maxExcerpt` characters.
    public var excerpt: String
    /// Whether the thread has more than one comment and the last one is by
    /// the user whose token sbd reads with. Sessions post with that token too.
    public var replied: Bool
  }

  /// A reviewer's latest approval or change request.
  public struct ReviewDetail: Codable, Equatable, Sendable {
    public var author: String
    /// true when a GitHub App wrote the review, and nil otherwise.
    public var bot: Bool?
    public var state: String
    /// The commit the review was made on.
    public var commit: String?
    /// How many of the PR's last 100 commits come after `commit`. nil when
    /// `commit` is not among them, as after a force-push.
    public var commitsSince: Int?
    /// At most `maxReviewBody` characters, with its line breaks.
    public var body: String
    public var url: String
    /// The first `maxNotes` inline comments.
    public var notes: [Note]
    /// GitHub's count of the inline comments.
    public var noteCount: Int

    /// An inline comment of a review.
    public struct Note: Codable, Equatable, Sendable {
      public var path: String
      public var line: Int?
      public var excerpt: String
      public var url: String

      /// Where the comment is: "a.swift:12", or "a.swift" without a line.
      public var place: String { line.map { "\(path):\($0)" } ?? path }
    }
  }

  public init(
    additions: Int = 0, deletions: Int = 0, changedFiles: Int = 0, threads: Int = 0, threadsRead: Int = 0,
    openThreads: Int = 0, description: String = "", gist: String? = nil, testGaps: [String] = [],
    threadDetails: [ThreadDetail]? = nil, reviews: [ReviewDetail]? = nil
  ) {
    self.additions = additions
    self.deletions = deletions
    self.changedFiles = changedFiles
    self.threads = threads
    self.threadsRead = threadsRead
    self.openThreads = openThreads
    self.description = description
    self.gist = gist
    self.testGaps = testGaps
    self.threadDetails = threadDetails
    self.reviews = reviews
  }

  public static let maxDescription = 4000
  static let maxGist = 300
  static let maxTestGaps = 5
  public static let maxThreadDetails = 10
  static let maxExcerpt = 300
  static let maxReviewBody = 600
  /// The query asks for this many inline comments of each review.
  static let maxNotes = 5

  /// The sections whose heading has a word that starts with one of these
  /// are boilerplate. A match inside a word, as in "Latest", does not count.
  static let boilerplate = try! NSRegularExpression(
    pattern: #"\b(?:test|release|docs|documentation|agent|checklist|screenshot|changelog)"#,
    options: [.caseInsensitive])
  static let testHeading = try! NSRegularExpression(pattern: #"\btest"#, options: [.caseInsensitive])

  static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  static let gap = try! NSRegularExpression(
    pattern:
      #"(?:\b(?:not|never)|n['’]t)\s+(?:been\s+)?(?:tested|run|verified)\b|\buntested\b|\b(?:did|could)(?:\s+not|n['’]t)\s+(?:test|run|verify)\b"#,
    options: [.caseInsensitive])
  static let urlOnly = try! NSRegularExpression(pattern: #"^\s*<?https?://\S+>?\s*$"#)

  /// One paragraph, list item, or table of the body, with the heading that
  /// it falls under.
  struct Unit {
    var text: String
    var section: Int
    /// A table is not prose, so the gist skips it.
    var prose: Bool
  }

  /// The gist's first sentence, or the whole gist when it has no sentence end.
  public static func lead(_ gist: String) -> String {
    Attention.sentences(gist, trimming: .whitespaces).first ?? gist
  }

  /// Reads the body into the description, the gist, and the test gaps.
  /// `title` is the PR's title, which the gist never repeats.
  public static func read(body: String, title: String) -> (description: String, gist: String?, testGaps: [String]) {
    let text = Issues.htmlComment.stringByReplacingMatches(
      in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
    var headings: [(level: Int, text: String)] = []
    var section = 0
    var inBoilerplate = false
    var inTests = false
    var units: [Unit] = []
    var lines: [String] = []
    var gaps: [String] = []
    for block in MarkdownBlock.parse(text) {
      if case .heading(let level, let heading) = block {
        headings.removeAll { $0.level >= level }
        headings.append((level, heading.plain.lowercased()))
        section += 1
        inBoilerplate = headings.contains { matches(boilerplate, $0.text) }
        inTests = headings.contains { matches(testHeading, $0.text) }
        if !inBoilerplate { lines.append(heading.plain) }
        continue
      }
      if inTests { gaps += testGaps(block) }
      guard !inBoilerplate else { continue }
      for unit in self.units(block, section: section) {
        units.append(unit)
        lines.append(unit.text)
      }
    }
    let description = String(lines.joined(separator: "\n").prefix(maxDescription))
    return (description, gist(units, title: title), Array(gaps.prefix(maxTestGaps)))
  }

  /// The block's text units. A task list, an image, a `<details>` block, a
  /// code block, a lone URL, and a lone closing keyword give none.
  static func units(_ block: MarkdownBlock, section: Int) -> [Unit] {
    switch block {
    case .paragraph(let text):
      let plain = collapsed(text.plain)
      return kept(plain) ? [Unit(text: plain, section: section, prose: true)] : []
    case .list(_, let items):
      return items.filter { $0.checked == nil }.compactMap { item in
        let plain = itemText(item)
        return kept(plain) ? Unit(text: plain, section: section, prose: true) : nil
      }
    case .quote(let blocks, _):
      return blocks.flatMap { units($0, section: section) }
    case .table(let header, _, let rows):
      let text = ([header] + rows).map { $0.map(\.plain).joined(separator: " | ") }.joined(separator: "\n")
      return [Unit(text: text, section: section, prose: false)]
    default:
      return []
    }
  }

  /// The unchecked task items and the sentences that say something was not
  /// tested, in a block of a test section.
  static func testGaps(_ block: MarkdownBlock) -> [String] {
    switch block {
    case .paragraph(let text):
      return gapSentences(collapsed(text.plain))
    case .list(_, let items):
      return items.flatMap { item -> [String] in
        let plain = itemText(item)
        if item.checked == false { return plain.isEmpty ? [] : [oneLine(plain, max: TriageCard.lineLength)] }
        return gapSentences(plain)
      }
    case .quote(let blocks, _):
      return blocks.flatMap(testGaps)
    default:
      return []
    }
  }

  /// The first sentence of each of the first two sections that have prose,
  /// or of the first two units when the body has one section.
  static func gist(_ units: [Unit], title: String) -> String? {
    let prose = units.filter(\.prose)
    var picked: [Unit] = []
    for unit in prose where !picked.contains(where: { $0.section == unit.section }) {
      picked.append(unit)
      if picked.count == 2 { break }
    }
    if picked.count < 2 { picked = Array(prose.prefix(2)) }
    var chosen: [String] = []
    for unit in picked {
      guard var first = Attention.sentences(unit.text, trimming: .whitespaces).first else { continue }
      if first.hasSuffix(":") { first = String(first.dropLast()) + "." }
      if !".!?".contains(first.last ?? ".") { first += "." }
      if !repeats(first, title) { chosen.append(first) }
    }
    guard !chosen.isEmpty else { return nil }
    var gist = chosen[0]
    for sentence in chosen.dropFirst() where gist.count + 1 + sentence.count <= maxGist {
      gist += " " + sentence
    }
    return oneLine(gist, max: maxGist)
  }

  /// The text's sentences that say something was not tested, each cut to one line.
  static func gapSentences(_ text: String) -> [String] {
    Attention.sentences(text, trimming: .whitespaces).filter { matches(gap, $0) }
      .map { oneLine($0, max: TriageCard.lineLength) }
  }

  /// Whether `text` says only what `title` says, ignoring case, spaces, and
  /// the closing punctuation.
  static func repeats(_ text: String, _ title: String) -> Bool {
    let bare = { (s: String) in s.trimmingCharacters(in: CharacterSet(charactersIn: ".!? ")).lowercased() }
    return bare(text) == bare(title)
  }

  static func itemText(_ item: MarkdownBlock.Item) -> String {
    collapsed(item.blocks.map(\.plainText).joined(separator: " "))
  }

  /// Whether a unit's text says something: it is not a lone URL or a lone
  /// closing keyword such as `Closes #12`.
  static func kept(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    if text.isEmpty || urlOnly.firstMatch(in: text, range: range) != nil { return false }
    let rest = Issues.closingRef.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    return !rest.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).allSatisfy { $0.lowercased() == "and" }
  }

  static func collapsed(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }
}

extension GitHub {
  /// GitHub answers at most this many review threads in one read.
  public static let maxThreads = 100

  /// What the merge card needs of each PR at a merge decision. The status
  /// query leaves it out, because a PR's review threads would slow every
  /// status read. `$threads` adds each thread's first and last comment.
  /// Measured on 2026-11-14 over chunks of 20 PRs, a chunk cost 1 point
  /// before the review details, 4 points with `$threads` false, and 45
  /// points with `$threads` true.
  public static let mergeDetailsQuery = """
    query MergeDetails($ids: [ID!]!, $threads: Boolean!) {
      rateLimit { cost }
      nodes(ids: $ids) {
        ... on PullRequest {
          id headRefOid title body additions deletions changedFiles
          reviewThreads(first: \(maxThreads)) {
            totalCount
            nodes {
              isResolved isOutdated path line originalLine
              first: comments(first: 1) @include(if: $threads) { nodes { url body author { __typename login } } }
              last: comments(last: 1) @include(if: $threads) { totalCount nodes { viewerDidAuthor } }
            }
          }
          latestOpinionatedReviews(first: 20) {
            nodes {
              author { __typename login } state body url submittedAt commit { oid }
              comments(first: \(MergeDetails.maxNotes)) { totalCount nodes { path line originalLine body url } }
            }
          }
          commits(last: 100) { nodes { commit { oid } } }
        }
      }
    }
    """

  /// The details of one node of a merge details response, and the head
  /// commit they belong to. nil when the node lacks a field.
  public static func parseMergeDetails(_ node: JSON) -> (head: String, details: MergeDetails)? {
    guard let head = node["headRefOid"]?.string, let additions = node["additions"]?.int,
      let deletions = node["deletions"]?.int, let files = node["changedFiles"]?.int,
      let total = node["reviewThreads"]?["totalCount"]?.int
    else { return nil }
    let threads = nodes(node["reviewThreads"])
    let open = threads.filter { $0["isResolved"]?.bool == false }
    // A read with `$threads` false lacks `first` on every thread, so it has no details when a thread is open.
    let threadDetails =
      open.allSatisfy { $0["first"] != nil } ? open.prefix(MergeDetails.maxThreadDetails).map(threadDetail) : nil
    let commits = node["commits"].map { nodes($0).map { $0["commit"]?["oid"]?.string } }
    let reviews = node["latestOpinionatedReviews"].map { nodes($0).map { reviewDetail($0, commits: commits) } }
    let read = MergeDetails.read(body: node["body"]?.string ?? "", title: node["title"]?.string ?? "")
    return (
      head,
      MergeDetails(
        additions: additions, deletions: deletions, changedFiles: files, threads: total, threadsRead: threads.count,
        openThreads: open.count, description: read.description, gist: read.gist, testGaps: read.testGaps,
        threadDetails: threadDetails, reviews: reviews)
    )
  }

  static func threadDetail(_ node: JSON) -> MergeDetails.ThreadDetail {
    let first = nodes(node["first"]).first
    let url = first?["url"]?.string ?? ""
    let target = try? ReplyTarget.parse(url)
    let last = node["last"]
    return MergeDetails.ThreadDetail(
      rootId: target?.kind == .reviewComment ? target?.id : nil, url: url, path: node["path"]?.string ?? "",
      line: node["line"]?.int ?? node["originalLine"]?.int, outdated: node["isOutdated"]?.bool ?? false,
      author: login(first?["author"]), bot: isBot(first?["author"]) ? true : nil,
      excerpt: oneLine(first?["body"]?.string ?? "", max: MergeDetails.maxExcerpt),
      replied: (last?["totalCount"]?.int ?? 0) > 1 && nodes(last).last?["viewerDidAuthor"]?.bool == true)
  }

  /// `commits` holds the oids of the PR's last commits, oldest first, and
  /// is nil when the read lacks them.
  static func reviewDetail(_ node: JSON, commits: [String?]?) -> MergeDetails.ReviewDetail {
    let commit = node["commit"]?["oid"]?.string
    let body = node["body"]?.string ?? ""
    var since: Int?
    if let commit, let commits, let i = commits.lastIndex(of: commit) { since = commits.count - 1 - i }
    return MergeDetails.ReviewDetail(
      author: login(node["author"]), bot: isBot(node["author"]) ? true : nil, state: node["state"]?.string ?? "",
      commit: commit, commitsSince: since,
      body: truncated(body, max: MergeDetails.maxReviewBody), url: node["url"]?.string ?? "",
      notes: nodes(node["comments"]).prefix(MergeDetails.maxNotes).map { note in
        MergeDetails.ReviewDetail.Note(
          path: note["path"]?.string ?? "", line: note["line"]?.int ?? note["originalLine"]?.int,
          excerpt: oneLine(note["body"]?.string ?? "", max: MergeDetails.maxExcerpt), url: note["url"]?.string ?? "")
      },
      noteCount: node["comments"]?["totalCount"]?.int ?? 0)
  }
}
