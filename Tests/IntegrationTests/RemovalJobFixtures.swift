import Foundation
import SwitchboardCore
import Testing

/// The gate file that holds the removal worker. While it exists, the worker records `running` on the session it
/// takes next and waits before it stops that session's panes. The worker runs one session at a time, so every
/// session queued after that one stays `queued`.
let holdRemoval = "hold-removal"

/// The gate file that holds the removal worker on the trash path after git dropped the worktree's record and the
/// removal recorded `released`, before the branch deletes.
let holdReleased = "hold-removal-released"

/// The gate file that holds the removal worker on the trash path after the rename and before the trash check. The
/// folder is at the trash path, and git still has the worktree's record. A removal that deletes in place never
/// waits here.
let holdTrashCheck = "hold-removal-trash"

/// A recorded PR in PostHog/posthog and its head branch.
struct RemovalPR {
  let number: Int
  let branch: String

  static let breaker = RemovalPR(number: 122953, branch: "haacked/cdp-dlq-breaker-counts-lookups")
  static let groups = RemovalPR(number: 122179, branch: "posthog/groups-list-two-phase-dedup")
  static let cohort = RemovalPR(number: 121847, branch: "haacked/cohort-store-stamp-other-topic-marks")
}

/// An sbd whose poller asks a FakeGitHub, and a PostHog/posthog checkout whose origin is a bare repo in the home
/// that holds main.
struct MergedPRRepo {
  let github: FakeGitHub
  let sbd: Instance
  let repo: String
  let origin: String

  init() throws {
    github = try FakeGitHub()
    sbd = try Instance.withGitHub(github)
    repo = try Repos.create("\(sbd.home.path)/posthog", origin: Instance.posthogURL)
    origin = "\(sbd.home.path)/origin.git"
    try sbd.git(sbd.home.path, "init", "-q", "--bare", origin)
    try sbd.git(repo, "config", "url.\(origin).insteadOf", Instance.posthogURL)
    try sbd.git(repo, "push", "-q", "origin", "main")
  }

  /// A session in a worktree that sbd made on the PR's branch, after a commit. GitHub reports the PR in
  /// `state` with that commit as its head. The commit is on no remote unless `push` is true.
  func finished(_ pr: RemovalPR, state: String, push: Bool = false) throws -> SessionSummary {
    let s = try sbd.worktreeSession(repo, branch: pr.branch)
    try sbd.commit(s.cwd, "\(pr.number).txt")
    if push { try sbd.git(s.cwd, "push", "-q", "origin", pr.branch) }
    let tip = try sbd.git(s.cwd, "rev-parse", "HEAD")
    github.change(pr.number) {
      $0["state"] = .string(state)
      $0["headRefOid"] = .string(tip)
    }
    return s
  }

  /// `finished` with the PR merged.
  func merged(_ pr: RemovalPR, push: Bool = false) throws -> SessionSummary {
    try finished(pr, state: "MERGED", push: push)
  }

  /// Polls GitHub and waits until each session is Done.
  func pollUntilDone(_ sessions: SessionSummary...) throws {
    try sbd.poll(all: true)
    for s in sessions { try sbd.waitFor(s.id, "Done") { $0.state == .done } }
  }
}

/// The ids in an `rm-queue` result's `queued`.
func queued(_ result: JSON) -> [String] { result["queued"]?.array?.compactMap(\.string) ?? [] }

/// The lock reason that Supacode writes.
let supacodeLock = #"{"build":"1792934673","createdAt":1793889333,"owner":"supacode","version":"0.11.6"}"#

extension Instance {
  /// The `rm-queue` op. Nil `resolve` leaves the field out.
  func queueRemoval(
    _ targets: [String], scope: String = "done", worktree: Bool = true, remoteBranch: Bool = false,
    resolve: [String]? = nil
  ) throws -> JSON {
    var args: [String: JSON] = [
      "targets": .array(targets.map(JSON.string)), "scope": .string(scope), "worktree": .bool(worktree),
      "remote_branch": .bool(remoteBranch),
    ]
    if let resolve { args["resolve"] = .array(resolve.map(JSON.string)) }
    return try client.call("rm-queue", args)
  }

  /// Marks the session Done and waits until its state is Done.
  @discardableResult
  func markSessionDone(_ id: String) throws -> SessionSummary {
    try sb("done", id)
    return try waitFor(id, "Done") { $0.state == .done }
  }

  /// The sessions as `ls` lists them, as raw JSON, so the test reads fields that `SessionSummary` may lack.
  func listedSessions() throws -> [JSON] {
    let result = try client.call("ls")
    return try #require(result.array, Comment(rawValue: "ls returned \(result.text)"))
  }

  func listedIds() throws -> Set<String> { Set(try listedSessions().compactMap { $0["id"]?.string }) }

  /// The session's `removal` in `ls`, or nil when the session has none or `ls` no longer lists it.
  func removal(_ id: String) throws -> JSON? {
    guard let removal = try listedSessions().first(where: { $0["id"]?.string == id })?["removal"], removal != .null
    else { return nil }
    return removal
  }

  func removalState(_ id: String) throws -> String? { try removal(id)?["state"]?.string }

  @discardableResult
  func waitForRemoval(_ id: String, _ state: String, timeout: Double = 60) throws -> JSON {
    try waitFor("\(id)'s removal to be \(state)", timeout: timeout, fetch: { try removal(id) }) {
      $0["state"]?.string == state
    }
  }

  /// Waits until `ls` lists none of the sessions. The worker removes one session at a time.
  func waitUntilGone(_ ids: String..., timeout: Double = 60) throws {
    try waitFor("the removal of \(ids.joined(separator: ", "))", timeout: timeout) {
      try listedIds().isDisjoint(with: ids)
    }
  }

  /// The `removal-notices` op's list, oldest first.
  func removalNotices() throws -> [RemovalNotice] { try client.call("removal-notices", as: [RemovalNotice].self) }

  /// The notice about the session, or nil when none names it.
  func removalNotice(for id: String) throws -> RemovalNotice? { try removalNotices().first { $0.session == id } }

  func localBranch(_ repo: String, _ name: String) throws -> Bool {
    try runCommand("/usr/bin/git", ["-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/\(name)"]).status == 0
  }

  /// Points sbd's `supacode` at a stub, and returns the file where the stub records each call. The stub that
  /// works removes the worktree and force-deletes its branch with git, as Supacode does with its default
  /// settings. The stub that fails prints a message and exits 1.
  func useSupacodeStub(failing: Bool = false, removes: Bool = true) throws -> String {
    let calls = "\(home.path)/supacode-calls.log"
    let stub = "\(home.path)/supacode-stub"
    let body =
      failing
      ? #"echo "Supacode is not running" >&2; exit 1"#
      : !removes
        ? "exit 0"
        : #"""
        path=$(printf '%b' "${4//%/\\x}")
        path=${path%/}
        main=$(/usr/bin/git -C "$path" worktree list --porcelain | head -1 | cut -d' ' -f2-)
        branch=$(/usr/bin/git -C "$path" branch --show-current)
        /usr/bin/git -C "$main" worktree unlock "$path" && /usr/bin/git -C "$main" worktree remove "$path" || exit 1
        [ -z "$branch" ] || /usr/bin/git -C "$main" branch -q -D "$branch"
        """#
    try "#!/bin/bash\necho \"$@\" >> \(calls)\n\(body)\n".write(toFile: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
    try restart(setting: "supacode", to: .string(stub))
    return calls
  }

  /// The folder that a removal moves the session's worktree to.
  func trashFolder(_ id: String) -> String { "\(home.path)/trash/\(id)" }

  /// Waits until the session's worktree folder sits at its trash path and not at `cwd`.
  func waitForFolderInTrash(_ s: SessionSummary, timeout: Double = 60) throws {
    try waitFor("\(s.id)'s folder to move to the trash", timeout: timeout) {
      let fm = FileManager.default
      return fm.fileExists(atPath: trashFolder(s.id)) && !fm.fileExists(atPath: s.cwd)
    }
  }

  func lockForSupacode(_ repo: String, _ cwd: String) throws {
    try git(repo, "worktree", "lock", "--reason", supacodeLock, cwd)
  }
}
