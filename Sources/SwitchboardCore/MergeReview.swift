import Foundation

/// What a PR that is otherwise ready to merge still leaves open: its review
/// threads, the gaps in its test plan, and the code owners whose review is
/// missing.
public struct MergeReview: Codable, Equatable, Sendable {
  /// The PR's review threads as the merge details read counted them.
  public struct Threads: Codable, Equatable, Sendable {
    public var total: Int
    /// Below `total` when the PR has more threads than one read covers.
    public var read: Int
    /// The unresolved threads among those read.
    public var open: Int
  }

  public enum CodeOwnerGap: Codable, Equatable, Sendable {
    /// The owners of each group that has no approval on the head, in
    /// `CodeOwnerStatus` order.
    case waiting([[String]])
    /// The code owners that GitHub still requests, when sbd can't tell which
    /// groups wait.
    case requested([String])
  }

  /// nil until sbd reads the PR's merge details.
  public var threads: Threads?
  public var testGaps: [String]
  public var codeOwnerGap: CodeOwnerGap?

  public init(_ pr: PullRequest) {
    let details = pr.mergeDetails
    threads = details.map { Threads(total: $0.threads, read: $0.threadsRead, open: $0.openThreads) }
    testGaps = details?.testGaps ?? []
    if let status = CodeOwnerStatus(pr), !status.satisfied {
      codeOwnerGap = .waiting(status.groups.filter { !$0.approved }.map(\.owners))
    } else if let requests = pr.codeOwnerRequests, !requests.isEmpty {
      codeOwnerGap = .requested(requests)
    } else {
      codeOwnerGap = nil
    }
  }
}
