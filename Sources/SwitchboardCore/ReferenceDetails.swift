import Foundation

/// What the reference card shows about one GitHub issue or pull request, and where sbd read it.
public struct ReferenceDetails: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case issue
    case pr
  }

  public enum State: String, Codable, Sendable {
    case open
    case closed
    case merged
  }

  public enum Source: String, Codable, Sendable {
    /// A session's PR, as the poller last read it.
    case session
    /// The Issues cache.
    case issues
    /// sbd's own read of the item.
    case fetch
  }

  /// owner/name.
  public var repo: String
  public var number: Int
  public var kind: Kind
  public var title: String
  public var url: String
  public var state: State
  /// Always false for an issue.
  public var draft: Bool
  /// nil when the source has no author, as for a deleted account.
  public var author: String?
  public var labels: [String]
  /// ISO 8601 times, as GitHub sends them. nil when the source did not read them.
  public var createdAt: String?
  public var updatedAt: String?
  /// The rollup state of the head commit's checks. nil for an issue and for a commit with no checks.
  public var checks: String?
  public var reviewDecision: ReviewDecision?
  public var mergeable: Mergeable?
  public var source: Source
  /// When sbd read the item from GitHub, in milliseconds since the epoch. nil for the session source.
  public var read: Int64?

  public init(pr: PullRequest) {
    repo = pr.repo
    number = pr.number
    kind = .pr
    title = pr.title
    url = pr.url
    state = State(pr.state)
    draft = pr.draft
    author = pr.author
    labels = pr.labels
    createdAt = pr.createdAt
    checks = pr.checks
    reviewDecision = pr.reviewDecision
    mergeable = pr.mergeable
    source = .session
  }

  public init(issue: InboxIssue) {
    repo = issue.repo
    number = issue.number
    kind = .issue
    title = issue.title
    url = issue.url
    state = issue.state == .open ? .open : .closed
    draft = false
    author = issue.author
    labels = issue.labels
    // The issues parser stores an empty string for a time that GitHub did not send.
    createdAt = issue.createdAt.isEmpty ? nil : issue.createdAt
    updatedAt = issue.updatedAt.isEmpty ? nil : issue.updatedAt
    source = .issues
  }

  init(
    repo: String, number: Int, kind: Kind, title: String, url: String, state: State, draft: Bool, author: String?,
    labels: [String], createdAt: String?, updatedAt: String?, checks: String?, reviewDecision: ReviewDecision?,
    mergeable: Mergeable?
  ) {
    self.repo = repo
    self.number = number
    self.kind = kind
    self.title = title
    self.url = url
    self.state = state
    self.draft = draft
    self.author = author
    self.labels = labels
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.checks = checks
    self.reviewDecision = reviewDecision
    self.mergeable = mergeable
    source = .fetch
  }
}

extension ReferenceDetails.State {
  init(_ state: PRState) {
    switch state {
    case .open: self = .open
    case .closed: self = .closed
    case .merged: self = .merged
    }
  }
}

extension GitHub {
  /// One issue or pull request by owner, name, and number. GitHub numbers both together, so one field reads either.
  public static let referenceQuery = """
    query($o: String!, $n: String!, $num: Int!) {
      rateLimit { cost }
      repository(owner: $o, name: $n) {
        issueOrPullRequest(number: $num) {
          __typename
          ... on Issue {
            number title url state createdAt updatedAt author { login } labels(first: 10) { nodes { name } }
          }
          ... on PullRequest {
            number title url state isDraft createdAt updatedAt author { login } labels(first: 10) { nodes { name } }
            reviewDecision mergeable commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
        }
      }
    }
    """

  /// The item of a reference query's `data`. nil when the repository or the item is null, which GitHub answers for
  /// one that is missing or that the token can't see. The repository comes from the item's URL, in GitHub's case.
  public static func parseReference(_ data: JSON) -> ReferenceDetails? {
    guard let node = data["repository"]?["issueOrPullRequest"], let number = node["number"]?.int,
      let url = node["url"]?.string, let repo = GitHubRef(url: url)?.repo
    else { return nil }
    let kind: ReferenceDetails.Kind
    switch node["__typename"]?.string {
    case "Issue": kind = .issue
    case "PullRequest": kind = .pr
    default: return nil
    }
    let pull = kind == .pr
    return ReferenceDetails(
      repo: repo, number: number, kind: kind, title: node["title"]?.string ?? "", url: url,
      state: ReferenceDetails.State(rawValue: (node["state"]?.string ?? "").lowercased()) ?? .open,
      draft: pull && node["isDraft"]?.bool == true, author: node["author"]?["login"]?.string,
      labels: nodes(node["labels"]).compactMap { $0["name"]?.string },
      createdAt: node["createdAt"]?.string, updatedAt: node["updatedAt"]?.string,
      checks: pull ? nodes(node["commits"]).first?["commit"]?["statusCheckRollup"]?["state"]?.string : nil,
      reviewDecision: pull ? node["reviewDecision"]?.string.flatMap(ReviewDecision.init(rawValue:)) : nil,
      mergeable: pull ? node["mergeable"]?.string.flatMap(Mergeable.init(rawValue:)) : nil)
  }
}

/// sbd's answers from GitHub for references, by the lowercase `owner/name#N`. Each answer is fresh for a time that
/// depends on what it says: 60 s for an open item, 10 min for a merged or closed item, 10 min for "not found", and
/// 30 s for any other error. A store drops the entries stored more than an hour ago, then the oldest past 500.
public struct ReferenceCache: Sendable {
  public enum Answer: Equatable, Sendable {
    case found(ReferenceDetails)
    case notFound
    /// The read failed with this message, such as a network error or a rate-limit pause.
    case failed(String)
  }

  static let maxEntries = 500
  static let maxAgeMs: Int64 = 60 * 60 * 1000

  private var entries: [String: (answer: Answer, stored: Int64)] = [:]

  public init() {}

  public var count: Int { entries.count }

  /// The answer for `key` while it is younger than its TTL, else nil.
  public func fresh(_ key: String, now: Int64) -> Answer? {
    guard let entry = entries[key], now - entry.stored < Self.ttl(entry.answer) else { return nil }
    return entry.answer
  }

  public mutating func store(_ answer: Answer, for key: String, now: Int64) {
    entries[key] = (answer, now)
    entries = entries.filter { now - $0.value.stored <= Self.maxAgeMs }
    if entries.count > Self.maxEntries,
      let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.stored < $1.value.stored })?.key
    {
      entries[oldest] = nil
    }
  }

  static func ttl(_ answer: Answer) -> Int64 {
    switch answer {
    case .found(let details): details.state == .open ? 60_000 : 600_000
    case .notFound: 600_000
    case .failed: 30_000
    }
  }
}

extension ReferenceDetails {
  /// The end of sbd's `ref-details` refusal when GitHub has no such item or the token can't see it. The app reads
  /// a refusal that ends with it as "not found".
  public static let notFoundText = "not found, or your GitHub token can't see it"
}
