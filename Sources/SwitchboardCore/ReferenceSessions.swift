/// The sessions that work on a GitHub issue or pull request.
public enum ReferenceSessions {
  /// The sessions whose pull request or one of whose issues is `ref`, in the
  /// order given. GitHub numbers issues and pull requests together, so `ref`'s
  /// form is ignored. An issue whose repository sbd does not know never matches.
  public static func matching(_ ref: GitHubRef, in sessions: [SessionSummary]) -> [SessionSummary] {
    func names(_ repo: String?, _ number: Int) -> Bool {
      number == ref.number && repo.map { Dependencies.sameRepo($0, ref.repo) } == true
    }
    return sessions.filter { session in
      session.pr.map { names($0.repo, $0.number) } == true
        || session.issues?.contains { names($0.repo, $0.number) } == true
    }
  }
}
