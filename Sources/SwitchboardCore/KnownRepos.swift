import Foundation

/// A repository that the New Session sheet offers.
public struct KnownRepo: Codable, Equatable, Sendable, Identifiable {
  /// The real path of the repository's main checkout.
  public var path: String
  /// The `owner/name` of its GitHub remote, or the folder's name without one.
  public var name: String
  /// When a session last started in it or the user added it, in milliseconds. It is nil for a repository
  /// that only config.json names.
  public var used: Int64?

  public var id: String { path }

  public init(path: String, name: String, used: Int64? = nil) {
    self.path = path
    self.name = name
    self.used = used
  }
}

public enum KnownRepos {
  /// One entry per path, with its latest use. The most recently used comes first. Entries without a use
  /// follow, by name without case and then by path.
  public static func merge(_ entries: [KnownRepo]) -> [KnownRepo] {
    let byPath = Dictionary(entries.map { ($0.path, $0) }) { kept, entry in
      (entry.used ?? .min) > (kept.used ?? .min) ? entry : kept
    }
    return byPath.values.sorted { a, b in
      if a.used != b.used { return (a.used ?? .min) > (b.used ?? .min) }
      let (an, bn) = (a.name.lowercased(), b.name.lowercased())
      return an != bn ? an < bn : a.path < b.path
    }
  }

  /// The repository that the New Session sheet selects for `group`: the one whose path is the checkout of the
  /// most work sessions in the group. A tie goes to the one that comes first in `known`. When no session in the
  /// group has a checkout in `known`, or `group` is nil, it is the first of `known`.
  public static func preferred(_ known: [KnownRepo], group: String?, sessions: [SessionSummary]) -> KnownRepo? {
    guard let group else { return known.first }
    var counts: [String: Int] = [:]
    for s in sessions where s.group == group && s.kind == .work {
      if let checkout = s.checkout { counts[checkout, default: 0] += 1 }
    }
    var best: (repo: KnownRepo, count: Int)?
    for repo in known {
      let count = counts[repo.path, default: 0]
      if count > (best?.count ?? 0) { best = (repo, count) }
    }
    return best?.repo ?? known.first
  }

  /// The group that Start from an issue in `repository` (owner/name) selects: the one that holds the most work
  /// sessions in that repository, the converse of `preferred`. A tie goes to the group whose id sorts first. It is
  /// nil when no session in a group works in the repository.
  public static func preferredGroup(repository: String, sessions: [SessionSummary]) -> String? {
    var counts: [String: Int] = [:]
    for s in sessions where s.kind == .work && s.repository?.lowercased() == repository.lowercased() {
      if let group = s.group { counts[group, default: 0] += 1 }
    }
    return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
  }
}

/// The known repository that a prompt names, for the New Session sheet that a Manager's work-skill offer opens.
public enum PromptRepo {
  /// The repository that the first naming token of the prompt names, on any line. A token names a repository when,
  /// stripped of surrounding backticks, quotes, and `,.:;()`, it is the repository's `owner/name` in any case, or a
  /// path that starts with `/` or `~` and equals or sits inside the repository's path. A word without a `/` never
  /// names one, because a repository without a GitHub remote has its folder's name as its name.
  public static func named(in prompt: String, repos: [KnownRepo]) -> KnownRepo? {
    for word in prompt.split(whereSeparator: \.isWhitespace) {
      let token = word.trimmingCharacters(in: wrapping)
      if token.hasPrefix("/") || token.hasPrefix("~") {
        let path = trimmingSlashes(token.expandingTilde)
        if let repo = repos.first(where: { inside(path, trimmingSlashes($0.path)) }) { return repo }
      } else if token.wholeMatch(of: #/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/#) != nil,
        let repo = repos.first(where: { Dependencies.sameRepo($0.name, token) })
      {
        return repo
      }
    }
    return nil
  }

  private static let wrapping = CharacterSet(charactersIn: "`\"'(),.:;")

  private static func inside(_ path: String, _ repo: String) -> Bool {
    !repo.isEmpty && (path == repo || path.hasPrefix(repo + "/"))
  }

  private static func trimmingSlashes(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}
