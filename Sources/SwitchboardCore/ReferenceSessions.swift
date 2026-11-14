/// The sessions that work on a GitHub issue or pull request.
public enum ReferenceSessions {
  /// The sessions whose pull request or one of whose issues is `ref`, in the
  /// order given. GitHub numbers issues and pull requests together, so `ref`'s
  /// form is ignored. A session's issues are read as the Issues list reads
  /// them, so an issue with no repository is in the session's repository.
  public static func matching(_ ref: GitHubRef, in sessions: [SessionSummary]) -> [SessionSummary] {
    sessions.filter { session in
      session.pr.map { $0.number == ref.number && Dependencies.sameRepo($0.repo, ref.repo) } == true
        || IssueInbox.ids(of: session).contains(ref.key)
    }
  }
}
