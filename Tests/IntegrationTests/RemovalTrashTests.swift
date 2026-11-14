import Foundation
import SwitchboardCore
import Testing

/// The gate file that holds the removal worker on the trash path after the recheck that follows the pane stop. The
/// worker has stored `removal.trash` and has not renamed the folder yet. A removal that deletes in place never
/// waits here.
private let holdRename = "hold-removal-rename"

/// The gate file that holds the removal worker on the trash path after the rename and before the trash check. The
/// folder is at the trash path, and git still has the worktree's record. A removal that deletes in place never
/// waits here.
private let holdTrashCheck = "hold-removal-trash"

/// The config key that makes sbd treat the trash folder as on another volume than every worktree, as a differing
/// `st_dev` does. sbd reads it only with `testClock`.
private let trashOnOtherVolume = "testTrashOtherVolume"

/// A change to the worktree that only a lossless check finds, made after the recheck and before the rename.
enum LateChange: String, CaseIterable, Sendable {
  case untrackedFile
  case modifiedTrackedFile
  case assumeUnchanged
  case skipWorktree
  case unpushedCommit

  /// The part of the lossless check's error that names this change.
  var reason: String {
    switch self {
    case .untrackedFile, .modifiedTrackedFile: "uncommitted"
    case .assumeUnchanged, .skipWorktree: "git status skips"
    case .unpushedCommit: "not on a pushed branch"
    }
  }

  /// Makes the change in `folder`, and returns a check that the change is still there.
  func make(_ sbd: Instance, in folder: String) throws -> () throws -> Bool {
    switch self {
    case .untrackedFile:
      try "late".write(toFile: "\(folder)/notes.txt", atomically: true, encoding: .utf8)
      return { try String(contentsOfFile: "\(folder)/notes.txt", encoding: .utf8) == "late" }
    case .modifiedTrackedFile:
      try "changed".write(toFile: "\(folder)/\(trackedFile)", atomically: true, encoding: .utf8)
      return { try String(contentsOfFile: "\(folder)/\(trackedFile)", encoding: .utf8) == "changed" }
    case .assumeUnchanged:
      try sbd.git(folder, "update-index", "--assume-unchanged", trackedFile)
      return { try sbd.git(folder, "ls-files", "-v", trackedFile).hasPrefix("h ") }
    case .skipWorktree:
      try sbd.git(folder, "update-index", "--skip-worktree", trackedFile)
      return { try sbd.git(folder, "ls-files", "-v", trackedFile).hasPrefix("S ") }
    case .unpushedCommit:
      try sbd.commit(folder, "late.txt")
      let tip = try sbd.git(folder, "rev-parse", "HEAD")
      return { try sbd.git(folder, "rev-parse", "HEAD") == tip }
    }
  }
}

/// A file that main tracks and origin holds.
private let trackedFile = "tracked.txt"

extension Instance {
  /// A repo whose origin is a bare repo in the home, with main pushed. Main tracks `trackedFile`.
  fileprivate func repoWithTrackedFile() throws -> String {
    let repo = try repoWithOrigin()
    try commit(repo, trackedFile)
    try git(repo, "push", "-q", "origin", "main")
    return repo
  }

  /// The folder that a removal moves the session's worktree to.
  fileprivate func trashFolder(_ id: String) -> String { "\(home.path)/trash/\(id)" }

  /// The names in the trash folder. A trash folder that doesn't exist holds nothing.
  fileprivate func trashEntries() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: "\(home.path)/trash")) ?? []
  }

  fileprivate func waitForEmptyTrash(timeout: Double = 60) throws {
    try waitFor("the trash purge", timeout: timeout) { trashEntries().isEmpty }
  }

  /// Waits until the session's removal names its trash path, and returns that path.
  @discardableResult
  fileprivate func waitForTrashPath(_ id: String, timeout: Double = 60) throws -> String {
    try waitFor(
      "\(id)'s removal to name its trash path", timeout: timeout, fetch: { try removal(id)?["trash"]?.string },
      until: { _ in true })
  }

  /// Waits until the session's worktree folder sits at its trash path and not at `cwd`.
  fileprivate func waitForFolderInTrash(_ s: SessionSummary, timeout: Double = 60) throws {
    try waitFor("\(s.id)'s folder to move to the trash", timeout: timeout) {
      let fm = FileManager.default
      return fm.fileExists(atPath: trashFolder(s.id)) && !fm.fileExists(atPath: s.cwd)
    }
  }

  /// Whether `git worktree list` in the repo lists the session's folder. git lists the path with the symlinks
  /// resolved, so this compares the part from the worktree root on.
  fileprivate func listsWorktree(_ repo: String, _ s: SessionSummary) throws -> Bool {
    let tail = "/worktrees/" + (s.cwd.components(separatedBy: "/worktrees/").last ?? s.cwd)
    return try git(repo, "worktree", "list", "--porcelain").split(separator: "\n").contains {
      $0.hasPrefix("worktree ") && $0.hasSuffix(tail)
    }
  }
}

/// Whether `path` names `<home>/trash/<id>`. The home is under /tmp, which is a symlink to /private/tmp, so this
/// compares the home with its symlinks resolved.
private func isTrashPath(_ path: String, of id: String, in sbd: Instance) -> Bool {
  let url = URL(fileURLWithPath: path)
  let trash = url.deletingLastPathComponent()
  return url.lastPathComponent == id && trash.lastPathComponent == "trash"
    && real(trash.deletingLastPathComponent().path) == real(sbd.home.path)
}

@Suite(.blocking(timeLimit: .seconds(180))) struct RemovalTrashTests {
  // MARK: The trash path

  /// The merged session's commit is on no remote, so the trash check must count local branches for a merged PR as
  /// the first check does. The worker stops at the trash gate, which only the trash path passes.
  @Test func aRemovalThroughTheTrashDropsTheFolderAndTheRecordAndFollowsRmsBranchRules() throws {
    let s = try MergedPRRepo()
    let merged = try s.merged(.breaker)
    let unmerged = try s.sbd.worktreeSession(s.repo, branch: "haacked/unmerged")
    try s.pollUntilDone(merged)
    s.sbd.hold(holdTrashCheck)
    #expect(queued(try s.sbd.queueRemoval([merged.id, unmerged.id], scope: "work")) == [merged.id, unmerged.id])
    try s.sbd.waitForFolderInTrash(merged)

    try s.sbd.release(holdTrashCheck)

    try s.sbd.waitUntilGone(merged.id, unmerged.id)
    for session in [merged, unmerged] {
      #expect(!FileManager.default.fileExists(atPath: session.cwd), "\(session.cwd) is still there")
      #expect(try !s.sbd.listsWorktree(s.repo, session), "git still lists \(session.cwd)")
    }
    #expect(try !s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
    #expect(try s.sbd.localBranch(s.repo, "haacked/unmerged"))
    try s.sbd.waitForEmptyTrash()
  }

  /// A restart after the rename must find the folder, so the path is in the store before the folder moves.
  @Test func theRemovalStoresTheTrashPathBeforeTheFolderMoves() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdRename)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])

    let trash = try sbd.waitForTrashPath(a.id)

    #expect(isTrashPath(trash, of: a.id, in: sbd), Comment(rawValue: trash))
    #expect(FileManager.default.fileExists(atPath: a.cwd))
    #expect(!FileManager.default.fileExists(atPath: trash))
    try sbd.release(holdRename)
    try sbd.waitUntilGone(a.id)
    try sbd.waitForEmptyTrash()
  }

  @Test func lsShowsTheTrashPathWhileTheFolderSitsThere() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdTrashCheck)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForFolderInTrash(a)

    let listed = try #require(JSON.parse(try sbd.sb("ls", "--json"))?.array)

    let removal = try #require(
      listed.first { $0["id"]?.string == a.id }?["removal"], Comment(rawValue: listed.description))
    let trash = try #require(removal["trash"]?.string, Comment(rawValue: removal.text))
    #expect(removal["state"]?.string == "running", Comment(rawValue: removal.text))
    #expect(isTrashPath(trash, of: a.id, in: sbd), Comment(rawValue: trash))
    #expect(FileManager.default.fileExists(atPath: "\(trash)/.git"), "no worktree at \(trash)")
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    try sbd.release(holdTrashCheck)
    try sbd.waitUntilGone(a.id)
    try sbd.waitForEmptyTrash()
  }

  // MARK: The trash check

  /// The change lands after the recheck that follows the pane stop, so only the check on the trash path can find
  /// it. `git worktree remove` on the old path would drop the record without looking at the moved folder.
  @Test(arguments: LateChange.allCases)
  func aChangeMadeBetweenTheRecheckAndTheRenameFailsTheTrashCheck(_ change: LateChange) throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithTrackedFile()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    try #require(FileManager.default.fileExists(atPath: "\(a.cwd)/\(trackedFile)"))
    sbd.hold(holdRename)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForTrashPath(a.id)
    let stillThere = try change.make(sbd, in: a.cwd)

    try sbd.release(holdRename)

    let failed = try sbd.waitForRemoval(a.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.contains(change.reason), Comment(rawValue: error))
    #expect(try sbd.intact(a))
    #expect(try stillThere(), "the \(change) change is gone from \(a.cwd)")
    #expect(try sbd.listsWorktree(repo, a), "git no longer lists \(a.cwd)")
    #expect(!FileManager.default.fileExists(atPath: sbd.trashFolder(a.id)))
    #expect(try sbd.localBranch(repo, "haacked/a"))
  }

  // MARK: Restarts

  /// sbd dies after the rename and before the trash check. The restarted sbd finds the folder at the trash path,
  /// checks it there, and finishes the removal.
  @Test func killingSbdAfterTheRenameFinishesTheRemovalAfterTheRestart() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdTrashCheck)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForFolderInTrash(a)

    sbd.killSbd()
    try sbd.release(holdTrashCheck)
    try sbd.startSbd()

    try sbd.waitUntilGone(a.id)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(try !sbd.listsWorktree(repo, a), "git still lists \(a.cwd)")
    try sbd.waitForEmptyTrash()
  }

  /// The file lands in the trash folder while sbd is down, so only the check that the restart runs on the trash
  /// path can find it.
  @Test func aChangeMadeInTheTrashWhileSbdIsDownFailsTheResumedRemoval() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdTrashCheck)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForFolderInTrash(a)
    sbd.killSbd()
    try sbd.release(holdTrashCheck)
    try "late".write(toFile: "\(sbd.trashFolder(a.id))/notes.txt", atomically: true, encoding: .utf8)

    try sbd.startSbd()

    let failed = try sbd.waitForRemoval(a.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.contains("uncommitted"), Comment(rawValue: error))
    #expect(try sbd.intact(a))
    #expect(try String(contentsOfFile: "\(a.cwd)/notes.txt", encoding: .utf8) == "late")
    #expect(try sbd.listsWorktree(repo, a), "git no longer lists \(a.cwd)")
    #expect(!FileManager.default.fileExists(atPath: sbd.trashFolder(a.id)))
  }

  /// sbd dies after it stored the trash path and before the rename, so the folder is still at `cwd`. The restarted
  /// sbd starts the removal over from the checks.
  @Test func killingSbdBeforeTheRenameStartsTheRemovalOver() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdRename)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForTrashPath(a.id)
    try #require(FileManager.default.fileExists(atPath: a.cwd))

    sbd.killSbd()
    try sbd.release(holdRename)
    try sbd.startSbd()

    try sbd.waitUntilGone(a.id)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(try !sbd.listsWorktree(repo, a), "git still lists \(a.cwd)")
    try sbd.waitForEmptyTrash()
  }

  /// sbd dies after git dropped the record. The check in the trash can't run without the record, so the restarted sbd
  /// continues from `released` with the branch deletes, which read the branch from the repo.
  @Test func killingSbdAfterTheRecordIsDroppedFinishesTheRemovalAfterTheRestart() throws {
    let s = try MergedPRRepo()
    let merged = try s.merged(.breaker)
    try s.pollUntilDone(merged)
    s.sbd.hold(holdReleased)
    #expect(queued(try s.sbd.queueRemoval([merged.id], scope: "work")) == [merged.id])
    _ = try s.sbd.waitFor(
      "\(merged.id)'s removal to record released", timeout: 60, fetch: { try s.sbd.removal(merged.id) }
    ) {
      $0["released"]?.bool == true
    }
    #expect(try !s.sbd.listsWorktree(s.repo, merged), "git still lists \(merged.cwd)")
    #expect(try s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))

    s.sbd.killSbd()
    try s.sbd.release(holdReleased)
    try s.sbd.startSbd()

    try s.sbd.waitUntilGone(merged.id)
    #expect(try !s.sbd.localBranch(s.repo, RemovalPR.breaker.branch))
    #expect(!FileManager.default.fileExists(atPath: merged.cwd))
    try s.sbd.waitForEmptyTrash()
  }

  /// git dropped the record while sbd was down, as `git worktree prune` does, before the removal recorded `released`.
  /// Nothing shows that the folder in the trash is safe to delete, so the removal fails and the folder stays, through
  /// another restart's purge too.
  @Test func aFolderInTheTrashWhoseRecordIsGoneFailsTheRemovalAndStays() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdTrashCheck)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForFolderInTrash(a)
    sbd.killSbd()
    try sbd.release(holdTrashCheck)
    try sbd.git(repo, "worktree", "prune")
    try #require(try !sbd.listsWorktree(repo, a))

    try sbd.startSbd()

    let failed = try sbd.waitForRemoval(a.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.contains(sbd.trashFolder(a.id)), Comment(rawValue: error))
    #expect(failed["released"] == false, Comment(rawValue: failed.text))
    sbd.stopSbd()
    let stray = sbd.trashFolder("stray")
    try FileManager.default.createDirectory(atPath: stray, withIntermediateDirectories: true)
    try sbd.startSbd()
    try sbd.waitFor("the purge of \(stray)", timeout: 60) { !FileManager.default.fileExists(atPath: stray) }
    #expect(FileManager.default.fileExists(atPath: "\(sbd.trashFolder(a.id))/.git"), "the purge took a's folder")
    #expect(try sbd.localBranch(repo, "haacked/a"))
    #expect(try sbd.removalState(a.id) == "failed")
  }

  /// A folder at `cwd` and one in the trash leave sbd unable to tell which is the worktree, so the resumed removal
  /// fails and touches neither.
  @Test func aFolderAtCwdAndOneInTheTrashFailTheResumedRemoval() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdTrashCheck)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForFolderInTrash(a)
    sbd.killSbd()
    try sbd.release(holdTrashCheck)
    try FileManager.default.createDirectory(atPath: a.cwd, withIntermediateDirectories: false)
    try "new".write(toFile: "\(a.cwd)/new.txt", atomically: true, encoding: .utf8)

    try sbd.startSbd()

    let failed = try sbd.waitForRemoval(a.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.contains(sbd.trashFolder(a.id)), Comment(rawValue: error))
    #expect(try String(contentsOfFile: "\(a.cwd)/new.txt", encoding: .utf8) == "new")
    #expect(FileManager.default.fileExists(atPath: "\(sbd.trashFolder(a.id))/.git"))
    #expect(try sbd.listsWorktree(repo, a), "git no longer lists \(a.cwd)")
  }

  /// The trash folder was swapped for a clean clone while sbd was down. Its lossless check passes, but it is not the
  /// worktree that git lists at `cwd`, so dropping that record would act on a folder that no check saw.
  @Test func aTrashFolderThatIsNotTheWorktreeFailsTheResumedRemoval() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdTrashCheck)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForFolderInTrash(a)
    sbd.killSbd()
    try sbd.release(holdTrashCheck)
    let moved = "\(sbd.home.path)/moved-worktree"
    try FileManager.default.moveItem(atPath: sbd.trashFolder(a.id), toPath: moved)
    try sbd.git(sbd.home.path, "clone", "-q", "\(sbd.home.path)/origin.git", sbd.trashFolder(a.id))

    try sbd.startSbd()

    let failed = try sbd.waitForRemoval(a.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.contains("is not the worktree"), Comment(rawValue: error))
    #expect(try sbd.listsWorktree(repo, a), "git no longer lists \(a.cwd)")
    #expect(FileManager.default.fileExists(atPath: "\(moved)/.git"))
  }

  /// A folder that appears at `cwd` after the rename would be what `git worktree remove <cwd>` deletes, so the
  /// removal fails before it, and git keeps the record.
  @Test func aFolderThatAppearsAtCwdAfterTheRenameKeepsTheRecord() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdTrashCheck)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForFolderInTrash(a)
    try FileManager.default.createDirectory(atPath: a.cwd, withIntermediateDirectories: false)
    try "new".write(toFile: "\(a.cwd)/new.txt", atomically: true, encoding: .utf8)

    try sbd.release(holdTrashCheck)

    let failed = try sbd.waitForRemoval(a.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.contains("appeared"), Comment(rawValue: error))
    #expect(try String(contentsOfFile: "\(a.cwd)/new.txt", encoding: .utf8) == "new")
    #expect(FileManager.default.fileExists(atPath: "\(sbd.trashFolder(a.id))/.git"))
    #expect(try sbd.listsWorktree(repo, a), "git no longer lists \(a.cwd)")
  }

  /// Supacode expects its worktree's folder at `cwd`, so a lock that appears after the recheck fails the trash check
  /// and the folder moves back.
  @Test func aSupacodeLockThatAppearsAfterTheRecheckFailsTheTrashCheck() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let log = try sbd.useSupacodeStub()
    sbd.hold(holdRename)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForTrashPath(a.id)
    try sbd.lockForSupacode(repo, a.cwd)

    try sbd.release(holdRename)

    let failed = try sbd.waitForRemoval(a.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.contains("Supacode locked"), Comment(rawValue: error))
    #expect(try sbd.intact(a))
    #expect(try sbd.listsWorktree(repo, a), "git no longer lists \(a.cwd)")
    #expect(!FileManager.default.fileExists(atPath: log))
  }

  /// A folder already at the trash path is not the worktree's, so the removal fails without recording that path, and
  /// Keep leaves that folder alone.
  @Test func aFolderAlreadyAtTheTrashPathFailsTheRemovalWithoutNamingIt() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    try FileManager.default.createDirectory(atPath: sbd.trashFolder(a.id), withIntermediateDirectories: true)

    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])

    let failed = try sbd.waitForRemoval(a.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.contains("exists"), Comment(rawValue: error))
    #expect(failed["trash"] == nil || failed["trash"] == .null, Comment(rawValue: failed.text))
    _ = try sbd.client.call("rm-keep", ["session": .string(a.id)])
    #expect(try sbd.intact(a))
    #expect(try sbd.listsWorktree(repo, a), "git no longer lists \(a.cwd)")
  }

  // MARK: Keep

  /// The trash check fails, and the move back finds a folder at `cwd`, so the worktree's folder stays in the trash.
  /// rm would forget the session and leave the folder to the purge, so it refuses. Keep refuses while `cwd` is taken,
  /// and moves the folder back once it is free.
  @Test func keepMovesTheFolderBackFromTheTrash() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdTrashCheck)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForFolderInTrash(a)
    let trash = sbd.trashFolder(a.id)
    try "late".write(toFile: "\(trash)/notes.txt", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: a.cwd, withIntermediateDirectories: false)
    try sbd.release(holdTrashCheck)

    let failed = try sbd.waitForRemoval(a.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.contains("uncommitted") && error.contains(trash), Comment(rawValue: error))
    #expect(FileManager.default.fileExists(atPath: "\(trash)/notes.txt"))
    let rm = failure(sbd, "rm", ["session": .string(a.id)])
    #expect(rm.contains("in the trash"), Comment(rawValue: rm))
    let refused = failure(sbd, "rm-keep", ["session": .string(a.id)])
    #expect(refused.contains("exists"), Comment(rawValue: refused))
    #expect(try sbd.removalState(a.id) == "failed")
    try FileManager.default.removeItem(atPath: a.cwd)

    _ = try sbd.client.call("rm-keep", ["session": .string(a.id)])

    #expect(try sbd.removal(a.id) == nil)
    #expect(try sbd.intact(a))
    #expect(try String(contentsOfFile: "\(a.cwd)/notes.txt", encoding: .utf8) == "late")
    #expect(!FileManager.default.fileExists(atPath: trash))
    #expect(try sbd.listsWorktree(repo, a), "git no longer lists \(a.cwd)")
    #expect(try sbd.git(a.cwd, "status", "--porcelain").contains("notes.txt"))
  }

  /// A to-do that arrives after git dropped the worktree's record fails the removal with `released` set. The folder's
  /// .git file names an admin folder that git deleted, so Keep refuses to move it back, and Retry finishes the delete.
  @Test func keepRefusesAFolderWhoseRecordGitDroppedAndRetryFinishesTheDelete() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdReleased)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    _ = try sbd.waitFor("\(a.id)'s removal to record released", timeout: 60, fetch: { try sbd.removal(a.id) }) {
      $0["released"]?.bool == true
    }
    let late = try sbd.addTodo(a.id, "close the incident")
    try sbd.release(holdReleased)
    let failed = try sbd.waitForRemoval(a.id, "failed")
    #expect(failed["released"] == true, Comment(rawValue: failed.text))
    let trash = sbd.trashFolder(a.id)

    let refused = failure(sbd, "rm-keep", ["session": .string(a.id)])

    #expect(refused.contains("Retry the delete"), Comment(rawValue: refused))
    #expect(try sbd.removalState(a.id) == "failed")
    #expect(FileManager.default.fileExists(atPath: "\(trash)/.git"), "Keep took the folder out of the trash")
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    try sbd.resolveTodo(a.id, late.id)
    _ = try sbd.client.call("rm-retry", ["session": .string(a.id)])
    try sbd.waitUntilGone(a.id)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    try sbd.waitForEmptyTrash()
  }

  // MARK: Cancel

  /// A retried removal is queued with its folder still in the trash. Clearing it would leave no removal that names the
  /// folder, and the purge on the next load would delete files that no check passed, so rm-cancel refuses it. The
  /// worker waits on b, so a stays queued.
  @Test func rmCancelRefusesARetriedRemovalWhoseFolderIsInTheTrash() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let b = try sbd.worktreeSession(repo, branch: "haacked/b")
    sbd.hold(holdTrashCheck)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForFolderInTrash(a)
    let trash = sbd.trashFolder(a.id)
    try "late".write(toFile: "\(trash)/notes.txt", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: a.cwd, withIntermediateDirectories: false)
    try sbd.release(holdTrashCheck)
    try sbd.waitForRemoval(a.id, "failed")
    sbd.hold(holdRemoval)
    defer { try? sbd.release(holdRemoval) }
    #expect(queued(try sbd.queueRemoval([b.id], scope: "work")) == [b.id])
    try sbd.waitForRemoval(b.id, "running")
    _ = try sbd.client.call("rm-retry", ["session": .string(a.id)])
    #expect(try sbd.removalState(a.id) == "queued")

    let result = try sbd.client.call("rm-cancel", ["sessions": [.string(a.id)]])

    #expect(result["cancelled"]?.array?.isEmpty == true, Comment(rawValue: result.text))
    let reason = try #require(result["refused"]?.array?.first?["reason"]?.string, Comment(rawValue: result.text))
    #expect(reason.contains(trash), Comment(rawValue: reason))
    #expect(try sbd.removalState(a.id) == "queued")
    sbd.killSbd()
    let stray = sbd.trashFolder("stray")
    try FileManager.default.createDirectory(atPath: stray, withIntermediateDirectories: true)
    try sbd.startSbd()
    try sbd.waitFor("the purge of \(stray)", timeout: 60) { !FileManager.default.fileExists(atPath: stray) }
    #expect(try String(contentsOfFile: "\(trash)/notes.txt", encoding: .utf8) == "late")
  }

  // MARK: The purge on load

  @Test func aTrashFolderThatNoRemovalNamesIsPurgedOnLoad() throws {
    let sbd = try Instance()
    let stray = sbd.trashFolder("stray")
    sbd.stopSbd()
    try FileManager.default.createDirectory(atPath: "\(stray)/build/out", withIntermediateDirectories: true)
    try "x".write(toFile: "\(stray)/build/out/a.o", atomically: true, encoding: .utf8)

    try sbd.startSbd()

    try sbd.waitFor("the purge of \(stray)", timeout: 60) { !FileManager.default.fileExists(atPath: stray) }
  }

  /// The resumed removal waits at `hold-removal`, so it can't finish and empty its trash folder itself. The stray
  /// folder shows that the purge ran.
  @Test func aTrashFolderThatAHeldRemovalNamesIsNotPurgedOnLoad() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdTrashCheck)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForFolderInTrash(a)
    sbd.killSbd()
    try sbd.release(holdTrashCheck)
    sbd.hold(holdRemoval)
    let stray = sbd.trashFolder("stray")
    try FileManager.default.createDirectory(atPath: stray, withIntermediateDirectories: true)

    try sbd.startSbd()

    try sbd.waitFor("the purge of \(stray)", timeout: 60) { !FileManager.default.fileExists(atPath: stray) }
    #expect(FileManager.default.fileExists(atPath: "\(sbd.trashFolder(a.id))/.git"), "the purge took a's folder")
    #expect(try sbd.removal(a.id)?["state"]?.string != "failed")
    try sbd.release(holdRemoval)
    try sbd.waitUntilGone(a.id)
    try sbd.waitForEmptyTrash()
  }

  @Test func thePurgeDeletesSymlinksAndNotWhatTheyName() throws {
    let sbd = try Instance()
    let outside = "\(sbd.home.path)/outside"
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    try "kept".write(toFile: "\(outside)/kept.txt", atomically: true, encoding: .utf8)
    sbd.stopSbd()
    let folder = sbd.trashFolder("folder")
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: "\(folder)/inner", withDestinationPath: outside)
    try FileManager.default.createSymbolicLink(atPath: sbd.trashFolder("link"), withDestinationPath: outside)

    try sbd.startSbd()

    try sbd.waitForEmptyTrash()
    #expect(try String(contentsOfFile: "\(outside)/kept.txt", encoding: .utf8) == "kept")
  }

  /// A trash that is a symlink is neither listed for the purge nor used for a rename, so the removal deletes in place.
  @Test func aTrashThatIsASymlinkIsNotPurgedAndTheRemovalDeletesInPlace() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let outside = "\(sbd.home.path)/outside"
    try FileManager.default.createDirectory(atPath: "\(outside)/stray", withIntermediateDirectories: true)
    sbd.stopSbd()
    try FileManager.default.createSymbolicLink(atPath: "\(sbd.home.path)/trash", withDestinationPath: outside)
    try sbd.startSbd()
    sbd.hold(holdRename)
    sbd.hold(holdTrashCheck)

    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])

    try sbd.waitUntilGone(a.id)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(try !sbd.listsWorktree(repo, a), "git still lists \(a.cwd)")
    #expect(FileManager.default.fileExists(atPath: "\(outside)/stray"))
  }

  // MARK: Deleting in place

  /// A rename of a `cwd` that is a symlink would move only the link, so the removal never takes the trash path. Both
  /// trash gates are held, so a removal that took it could not end.
  @Test func aCwdThatIsASymlinkNeverMovesToTheTrash() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdRemoval)
    sbd.hold(holdRename)
    sbd.hold(holdTrashCheck)
    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])
    try sbd.waitForRemoval(a.id, "running")
    try FileManager.default.moveItem(atPath: a.cwd, toPath: "\(a.cwd)-real")
    try FileManager.default.createSymbolicLink(atPath: a.cwd, withDestinationPath: "\(a.cwd)-real")

    try sbd.release(holdRemoval)

    try sbd.waitFor("the removal of \(a.id) to end", timeout: 60) {
      try !sbd.listedIds().contains(a.id) || sbd.removalState(a.id) == "failed"
    }
    #expect(!FileManager.default.fileExists(atPath: sbd.trashFolder(a.id)))
    #expect(try sbd.removal(a.id)?["trash"] == nil)
  }

  /// Both trash gates are held, so a removal that took the trash path could not finish.
  @Test func aTrashFolderOnAnotherVolumeMakesTheRemovalDeleteInPlace() throws {
    let sbd = try Instance(config: [trashOnOtherVolume: true])
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    sbd.hold(holdRename)
    sbd.hold(holdTrashCheck)

    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])

    try sbd.waitUntilGone(a.id)
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(try !sbd.listsWorktree(repo, a), "git still lists \(a.cwd)")
    #expect(!FileManager.default.fileExists(atPath: sbd.trashFolder(a.id)))
  }

  /// Supacode expects the folder at its path, so the worker deletes it through Supacode. Both trash gates are held,
  /// so a removal that took the trash path could not finish.
  @Test func aWorktreeThatSupacodeLockedIsDeletedInPlaceThroughSupacode() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    let log = try sbd.useSupacodeStub()
    try sbd.lockForSupacode(repo, a.cwd)
    sbd.hold(holdRename)
    sbd.hold(holdTrashCheck)

    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])

    try sbd.waitUntilGone(a.id)
    let calls = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n")
    #expect(calls.count == 1, Comment(rawValue: calls.joined(separator: "\n")))
    #expect(calls.first?.hasPrefix("worktree delete --worktree ") == true, Comment(rawValue: calls.joined()))
    #expect(!FileManager.default.fileExists(atPath: a.cwd))
    #expect(try !sbd.listsWorktree(repo, a), "git still lists \(a.cwd)")
    #expect(!FileManager.default.fileExists(atPath: sbd.trashFolder(a.id)))
  }

  /// `git worktree remove` on a path that is gone skips git's refusal of a worktree with a submodule and deletes the
  /// submodule's repo, so the worker deletes such a worktree in place, where git refuses it. Both trash gates are held,
  /// so a removal that took the trash path could not end.
  @Test func aWorktreeWithASubmoduleIsDeletedInPlaceWhereGitRefusesIt() throws {
    let sbd = try Instance()
    let repo = try sbd.repoWithOrigin()
    let sub = "\(sbd.home.path)/sub"
    try sbd.git(sbd.home.path, "init", "-q", sub)
    try sbd.commit(sub, "sub.txt")
    try sbd.git(repo, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "sub")
    try sbd.git(
      repo, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "sub")
    try sbd.git(repo, "push", "-q", "origin", "main")
    let a = try sbd.worktreeSession(repo, branch: "haacked/a")
    try sbd.git(a.cwd, "-c", "protocol.file.allow=always", "submodule", "update", "-q", "--init")
    try #require(FileManager.default.fileExists(atPath: "\(a.cwd)/sub/sub.txt"))
    sbd.hold(holdRename)
    sbd.hold(holdTrashCheck)

    #expect(queued(try sbd.queueRemoval([a.id], scope: "work")) == [a.id])

    let failed = try sbd.waitForRemoval(a.id, "failed")
    let error = try #require(failed["error"]?.string, Comment(rawValue: failed.text))
    #expect(error.contains("submodules"), Comment(rawValue: error))
    #expect(try sbd.intact(a))
    #expect(FileManager.default.fileExists(atPath: "\(a.cwd)/sub/sub.txt"))
    #expect(try sbd.listsWorktree(repo, a), "git no longer lists \(a.cwd)")
    #expect(!FileManager.default.fileExists(atPath: sbd.trashFolder(a.id)))
  }
}
