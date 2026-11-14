import Foundation

/// The "Before you merge" panel of a Ready to merge item: the PR's
/// approvals, its review threads, the reviewers it still waits on, and the
/// gaps in its test plan. `amber` lists the rows that need a look. The merge
/// option stays the main option only when `amber` is empty.
public struct MergeReview: Codable, Equatable, Sendable {
  /// The panel's rows, in panel order.
  public enum Row: String, Codable, Sendable, CaseIterable {
    case approval, threads, reviewers, testPlan
  }

  /// A reviewer's approval, joined to the review that the merge details read
  /// holds for the same reviewer and commit.
  public struct Approval: Codable, Equatable, Sendable {
    public var author: String
    /// true when a GitHub App approved, and nil otherwise.
    public var bot: Bool?
    /// Whether the approval is on the PR's head. nil when GitHub gave no commit.
    public var atHead: Bool?
    /// How many commits came after the approval's commit. nil when the
    /// merge details read has no such review, or lost the commit.
    public var commitsSince: Int?
    public var body: String?
    public var url: String?
    public var notes: [MergeDetails.ReviewDetail.Note]
    public var noteCount: Int
  }

  /// An open review thread that the panel shows, with the numbers of the
  /// item's drafts that answer it.
  public struct Thread: Codable, Equatable, Sendable {
    public var rootId: Int64?
    public var url: String
    public var path: String
    public var line: Int?
    public var outdated: Bool
    public var author: String
    public var bot: Bool?
    public var excerpt: String
    public var replied: Bool
    public var drafts: [Int]

    init(_ detail: MergeDetails.ThreadDetail) {
      rootId = detail.rootId
      url = detail.url
      path = detail.path
      line = detail.line
      outdated = detail.outdated
      author = detail.author
      bot = detail.bot
      excerpt = detail.excerpt
      replied = detail.replied
      drafts = []
    }
  }

  /// The PR's review threads as the merge details read counted them.
  public struct Threads: Codable, Equatable, Sendable {
    public var total: Int
    /// Below `total` when the PR has more threads than one read covers.
    public var read: Int
    /// The unresolved threads among those read.
    public var open: Int
    /// The first open threads, when the read included their comments.
    public var shown: [Thread] = []
  }

  public enum CodeOwnerGap: Codable, Equatable, Sendable {
    /// The owners of each group that has no approval on the head, in
    /// `CodeOwnerStatus` order.
    case waiting([[String]])
    /// The code owners that GitHub still requests, when sbd can't tell which
    /// groups wait.
    case requested([String])

    private struct Key: CodingKey {
      var stringValue: String
      var intValue: Int? { nil }
      init(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { nil }
    }

    /// The JSON is `{"waiting": [[…]]}` or `{"requested": […]}`, and nothing else.
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Key.self)
      guard c.allKeys.count == 1, let key = c.allKeys.first else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: c.codingPath, debugDescription: "a code owner gap has one key, waiting or requested"))
      }
      switch key.stringValue {
      case "waiting": self = .waiting(try c.decode([[String]].self, forKey: key))
      case "requested": self = .requested(try c.decode([String].self, forKey: key))
      default:
        throw DecodingError.dataCorruptedError(
          forKey: key, in: c, debugDescription: "unknown code owner gap \(key.stringValue)")
      }
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: Key.self)
      switch self {
      case .waiting(let groups): try c.encode(groups, forKey: Key(stringValue: "waiting"))
      case .requested(let logins): try c.encode(logins, forKey: Key(stringValue: "requested"))
      }
    }
  }

  /// A row as `sb triage` prints it: a title, and the lines under it.
  public struct Line: Equatable, Sendable {
    public var row: Row
    public var amber: Bool
    public var title: String
    public var details: [String]
  }

  /// Newest first.
  public var approvals: [Approval]
  /// The PR has no approval, and its base branch requires none.
  public var noReviewRequired: Bool
  /// Whether sbd read the PR's merge details.
  public var detailsRead: Bool
  /// nil until sbd reads the PR's merge details.
  public var threads: Threads?
  public var testGaps: [String]
  public var codeOwnerGap: CodeOwnerGap?
  /// The open review requests, as logins and team slugs.
  public var pendingReviewers: [String]
  public var changesRequestedBy: [String]
  /// The rows that need a look, in panel order.
  public var amber: [Row]

  public init(_ pr: PullRequest) {
    let details = pr.mergeDetails
    detailsRead = details != nil
    let reviews = details?.reviews ?? []
    approvals = pr.verdicts.filter(\.isApproval)
      .sorted { ($0.submittedAt ?? "") > ($1.submittedAt ?? "") }
      .map { verdict in
        let detail = reviews.first {
          $0.author.lowercased() == verdict.author.lowercased() && $0.commit == verdict.commit
        }
        return Approval(
          author: verdict.author, bot: verdict.bot ?? detail?.bot, atHead: verdict.commit.map { $0 == pr.headSha },
          commitsSince: detail?.commitsSince, body: detail.flatMap { $0.body.isEmpty ? nil : $0.body },
          url: detail?.url, notes: detail?.notes ?? [], noteCount: detail?.noteCount ?? 0)
      }
    noReviewRequired = approvals.isEmpty && pr.reviewDecision == nil && pr.reviewDecisionRead == true
    threads = details.map {
      Threads(
        total: $0.threads, read: $0.threadsRead, open: $0.openThreads,
        shown: ($0.threadDetails ?? []).map(Thread.init))
    }
    testGaps = details?.testGaps ?? []
    if let status = CodeOwnerStatus(pr), !status.satisfied {
      codeOwnerGap = .waiting(status.groups.filter { !$0.approved }.map(\.owners))
    } else if let requests = pr.codeOwnerRequests, !requests.isEmpty {
      codeOwnerGap = .requested(requests)
    } else {
      codeOwnerGap = nil
    }
    pendingReviewers = pr.reviewRequests ?? []
    changesRequestedBy = pr.changesRequestedBy
    amber = []
    amber = Row.allCases.filter { isAmber($0) }
  }

  /// Unknown counts as amber: a row is green only when sbd read that it is.
  private func isAmber(_ row: Row) -> Bool {
    switch row {
    case .approval:
      guard detailsRead, !approvals.contains(where: { $0.atHead == nil }) else { return true }
      return approvals.isEmpty ? !noReviewRequired : !approvals.contains { $0.atHead == true }
    case .threads:
      guard let t = threads else { return true }
      return t.open > 0 || t.read < t.total
    case .reviewers:
      return !pendingReviewers.isEmpty || codeOwnerGap != nil || !changesRequestedBy.isEmpty
    case .testPlan:
      return !testGaps.isEmpty
    }
  }

  /// The numbers of the drafts that a shown thread holds. The Drafts section
  /// leaves them out, so each draft shows once.
  public var draftNumbers: [Int] { threads?.shown.flatMap(\.drafts) ?? [] }

  /// Sets each shown thread's drafts: those whose resolved target is a reply
  /// in that thread on the PR `repo`#`number`.
  mutating func attach(drafts: [InboxDraft], repo: String, number: Int) {
    guard var t = threads else { return }
    for i in t.shown.indices {
      guard let root = t.shown[i].rootId else { continue }
      t.shown[i].drafts = drafts.filter { draft in
        guard let target = draft.post.target else { return false }
        return target.target.kind == .reviewComment && Dependencies.sameRepo(target.target.repo, repo)
          && target.target.pr == number && target.root == root
      }.map(\.number)
    }
    threads = t
  }

  static let notRead = "sbd hasn't read the review details yet."

  /// The rows that the panel shows, in panel order. The approval and threads
  /// rows always show. The other rows show only when amber. The text is
  /// plain, not Markdown.
  public var lines: [Line] {
    var lines = [line(.approval, approvalTitle, approvalDetails), line(.threads, threadsTitle, threadsDetails)]
    if amber.contains(.reviewers) { lines.append(line(.reviewers, reviewersTitle, reviewersDetails)) }
    if amber.contains(.testPlan) { lines.append(line(.testPlan, "The test plan has gaps", testGaps)) }
    return lines
  }

  private func line(_ row: Row, _ title: String, _ details: [String]) -> Line {
    Line(row: row, amber: amber.contains(row), title: title, details: details)
  }

  private var approvalTitle: String {
    if approvals.isEmpty { return noReviewRequired ? "No review required" : "No approval" }
    if approvals.contains(where: { $0.atHead == nil }) { return "An approval's commit is unknown" }
    return approvals.contains { $0.atHead == true } ? "Approved on the head" : "Not approved on the head"
  }

  private var approvalDetails: [String] {
    let lines = approvals.map { a in
      let place: String
      switch (a.atHead, a.commitsSince) {
      case (true?, _): place = "on the head"
      case (false?, let n?): place = "\(n) \(n == 1 ? "commit" : "commits") earlier"
      case (false?, nil): place = "on an earlier commit"
      case (nil, _): place = "on an unknown commit"
      }
      let notes = a.noteCount == 0 ? "" : ", \(a.noteCount) inline \(a.noteCount == 1 ? "comment" : "comments")"
      let body = a.body.map { ": " + oneLine($0, max: 200) } ?? ""
      return "\(a.author)\(a.bot == true ? " (bot)" : ""), \(place)\(notes)\(body)"
    }
    return (detailsRead ? [] : [Self.notRead]) + lines
  }

  private var threadsTitle: String {
    guard let t = threads else { return "Review threads not read yet" }
    let open = "\(t.open) open review \(t.open == 1 ? "thread" : "threads")"
    if t.read < t.total { return t.open == 0 ? "Not every review thread was read" : "At least \(open)" }
    return t.open == 0 ? "No open review threads" : open
  }

  private var threadsDetails: [String] {
    guard let t = threads else { return [Self.notRead] }
    let unread = t.read < t.total ? ["The PR has \(t.total) review threads, and sbd read \(t.read)."] : []
    return unread
      + t.shown.map { thread in
        let place: String
        if thread.outdated {
          place = "outdated"
        } else if thread.path.isEmpty {
          place = "PR conversation"
        } else {
          place = thread.line.map { "\(thread.path):\($0)" } ?? thread.path
        }
        let author = thread.author + (thread.bot == true ? " (bot)" : "")
        return "\(place), \(author), \(thread.replied ? "you replied" : "no reply"): \(thread.excerpt)"
      }
  }

  /// Each reason the row is amber, as a headline and the names it waits on.
  private var reviewerFacts: [(headline: String, names: String)] {
    var facts: [(String, String)] = []
    switch codeOwnerGap {
    case .waiting(let groups):
      facts.append(
        ("Code owner review still required", groups.map { $0.joined(separator: " or ") }.joined(separator: "; ")))
    case .requested(let requests):
      facts.append(("Code owners still requested", requests.joined(separator: ", ")))
    case nil: break
    }
    if !pendingReviewers.isEmpty { facts.append(("Reviews still requested", pendingReviewers.joined(separator: ", "))) }
    if !changesRequestedBy.isEmpty { facts.append(("Changes requested", changesRequestedBy.joined(separator: ", "))) }
    return facts
  }

  private var reviewersTitle: String { reviewerFacts.first?.headline ?? "Other reviewers" }

  private var reviewersDetails: [String] {
    let facts = reviewerFacts
    guard let first = facts.first else { return [] }
    return [first.names] + facts.dropFirst().map { "\($0.headline): \($0.names)" }
  }
}
