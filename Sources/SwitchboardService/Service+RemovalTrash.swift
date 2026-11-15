import Foundation
import SwitchboardCore

/// The removal job's fast release of a worktree. The job renames the
/// worktree's folder to `<sb home>/trash/<session id>`, runs the lossless
/// check on it there, and drops git's record of the worktree through the old
/// path. `trashQueue` deletes the folder's files later. The rename takes
/// git's own check away from `git worktree remove`, so the check in the trash
/// stands in for it.
extension Service {
  /// Releases the worktree through the trash when its folder is there or can
  /// move there with a rename, and returns the trash path. Returns nil when
  /// the worktree goes in place with `releaseWorktree`, and the folder is
  /// still at `cwd`. `inTrash` is what `folderInTrash` returned. A failed
  /// check in the trash moves the folder back to `cwd` and throws. It runs
  /// on `removalQueue`.
  func releaseThroughTrash(
    _ check: RemovalSubject, _ checked: ReleaseTargets, _ removal: Removal, inTrash: String?
  ) throws -> String? {
    let session = check.session
    guard let repo = checked.repo else { return nil }
    if let inTrash {
      if !removal.released {
        try checkTrash(check, checked, inTrash)
        try releaseFromTrash(session, repo: repo, inTrash)
      }
      return inTrash
    }
    // `trashFolder` gives a session on a host no trash, so `holdsSubmodules` runs git only on this Mac.
    guard !check.folderGone, !checked.supacode, let trash = trashFolder(for: session),
      try !holdsSubmodules(session.cwd), try moveToTrash(session, trash)
    else { return nil }
    try checkTrash(check, checked, trash)
    try releaseFromTrash(session, repo: repo, trash)
    return trash
  }

  /// The trash path that holds the session's worktree folder after an
  /// earlier run of its removal moved it there, or nil when the folder is
  /// not in the trash. It throws, and leaves the folder, when a folder is
  /// at `cwd` too, or when the removal has not recorded `released` and git
  /// no longer lists the worktree, because then nothing shows that the
  /// folder is safe to delete. A session on a host never has a folder in the
  /// trash, because `trashFolder` gives it none. It runs off the state queue.
  func folderInTrash(_ id: String, _ removal: Removal) throws -> String? {
    guard let trash = removal.trash, linkStatus(trash) != nil,
      let session = queue.sync(execute: { entries[id]?.session }), session.host == nil
    else { return nil }
    guard linkStatus(session.cwd) == nil else {
      throw APIError(
        "\(session.cwd) exists, and the trash holds a folder of \(id) at \(trash) too. Move one of them away, then retry the delete."
      )
    }
    if removal.released { return trash }
    let repo = try worktreeRepo(session, at: mac)
    guard try worktreeEntry(repo, holding: session.cwd, at: mac) != nil else {
      throw APIError(
        "git no longer lists \(session.cwd) as a worktree of \(repo), so sbd can't show that its folder in the trash is safe to delete. The folder stays at \(trash)."
      )
    }
    return trash
  }

  /// Whether the worktree at `cwd` holds a submodule that `git worktree remove` refuses to delete, as git decides
  /// it: the worktree's admin folder holds a `modules` folder, or a gitlink in its index names a populated folder.
  /// git skips that refusal for a worktree whose folder is gone and deletes the submodules' repos, so such a
  /// worktree goes in place. It runs on `removalQueue`.
  private func holdsSubmodules(_ cwd: String) throws -> Bool {
    let admin = try gitOutput(cwd, ["rev-parse", "--absolute-git-dir"], at: mac)
    if let modules = linkStatus("\(admin)/modules"), isFolder(modules) { return true }
    let index = try gitOutput(cwd, ["ls-files", "--stage", "-z"], at: mac)
    return index.split(separator: "\0").contains { entry in
      guard entry.hasPrefix("160000 "), let tab = entry.firstIndex(of: "\t") else { return false }
      return linkStatus("\(cwd)/\(entry[entry.index(after: tab)...])/.git") != nil
    }
  }

  /// The path that the session's worktree folder can move to with a rename,
  /// or nil when the job deletes the worktree in place. That is when the
  /// session runs on a remote host, `cwd` is not an absolute path to a
  /// folder (a symlink's rename would move only the link), the id can't name
  /// a folder, or the trash is on another volume, where a move copies the
  /// files. It creates the trash folder.
  func trashFolder(for session: Session) -> String? {
    let id = session.id
    guard session.host == nil, session.cwd.hasPrefix("/"), !id.isEmpty, !id.contains("/"),
      id != ".", id != "..", let folder = linkStatus(session.cwd), isFolder(folder)
    else { return nil }
    try? FileManager.default.createDirectory(
      atPath: home.trash, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard let trash = linkStatus(home.trash), isFolder(trash), trash.st_dev == folder.st_dev,
      !(config.testClock && config.testTrashOtherVolume)
    else { return nil }
    return "\(home.trash)/\(id)"
  }

  /// Records `trash` in the session's removal, then renames `cwd` to it, so a
  /// restart after the rename finds the folder. Returns false, with the
  /// folder at `cwd`, when the rename finds the trash on another volume. Any
  /// other failure throws, with the folder at `cwd`. A failed rename clears
  /// `trash`, so that Keep and the purge don't take what is at that path for
  /// the worktree's folder.
  private func moveToTrash(_ session: Session, _ trash: String) throws -> Bool {
    guard linkStatus(trash) == nil else {
      throw APIError("sbd couldn't move \(session.cwd) to the trash, because \(trash) exists.")
    }
    try queue.sync { try update(session.id) { $0.removal?.trash = trash } }
    waitAtGate("hold-removal-rename")
    let failure = rename(session.cwd, to: trash)
    guard failure != 0 else { return true }
    queue.sync {
      do {
        try update(session.id) { $0.removal?.trash = nil }
      } catch {
        logLine("can't clear the trash path of \(session.id)'s removal: \(error)")
      }
    }
    if failure == EXDEV { return false }
    throw APIError("sbd couldn't move \(session.cwd) to the trash at \(trash): \(UnixSocket.errnoText(failure)).")
  }

  /// Runs the lossless check that `checkWorktreeIsLossless` makes on the
  /// folder in the trash, after it checks that the folder is the worktree
  /// that git lists at `cwd`. A failure moves the folder back to `cwd` and
  /// throws. When the move back fails too, the folder stays in the trash and
  /// the error says so.
  private func checkTrash(_ check: RemovalSubject, _ checked: ReleaseTargets, _ trash: String) throws {
    let session = check.session
    waitAtGate("hold-removal-trash")
    do {
      try requireTrashHoldsWorktree(session, trash)
      let (_, supacode) = try checkWorktreeIsLossless(
        session, mergedPR: checked.pr?.state == .merged, sharedWith: check.sharedWith, onlyBuildOutputIgnored: false,
        in: trash, at: mac)
      if supacode { throw APIError("Supacode locked \(session.cwd) while it was being removed.") }
    } catch {
      let failure = rename(trash, to: session.cwd)
      guard failure == 0 else {
        throw APIError(
          "\(error) sbd couldn't move the folder back to \(session.cwd) (\(UnixSocket.errnoText(failure))), so it stays in the trash at \(trash)."
        )
      }
      throw error
    }
  }

  /// Throws unless `trash` is a folder whose git admin folder names
  /// `cwd/.git` as its worktree, so the check and the record removal act on
  /// the same worktree.
  private func requireTrashHoldsWorktree(_ session: Session, _ trash: String) throws {
    guard let status = linkStatus(trash), isFolder(status) else { throw APIError("\(trash) is not a folder.") }
    let admin = try gitOutput(trash, ["rev-parse", "--absolute-git-dir"], at: mac)
    // `worktree.useRelativePaths` writes the path relative to the admin folder.
    guard let gitdir = mac.machine.text("\(admin)/gitdir")?.trimmingCharacters(in: .whitespacesAndNewlines),
      try mac.samePath(
        URL(fileURLWithPath: gitdir, relativeTo: URL(fileURLWithPath: admin, isDirectory: true)).path,
        "\(session.cwd)/.git")
    else {
      throw APIError("\(trash) is not the worktree that git lists at \(session.cwd).")
    }
  }

  /// Drops git's record of the worktree whose folder is in the trash, then
  /// records `released`. It refuses when a folder appeared at `cwd`, because
  /// `git worktree remove` would delete that folder.
  private func releaseFromTrash(_ session: Session, repo: String, _ trash: String) throws {
    guard linkStatus(session.cwd) == nil else {
      throw APIError(
        "\(session.cwd) appeared while the worktree's folder was in the trash at \(trash). Move one of them away, then retry the delete."
      )
    }
    try releaseWorktree(session, repo: repo, folderGone: true, at: mac)
    try queue.sync { try update(session.id) { $0.removal?.released = true } }
    waitAtGate("hold-removal-released")
  }

  /// The trash path of the removal of `id` while its folder is still there, or nil. It runs on the state queue.
  func trashedFolder(_ id: String) -> String? {
    guard let trash = entries[id]?.session.removal?.trash, linkStatus(trash) != nil else { return nil }
    return trash
  }

  /// Moves the folder of a failed removal back from the trash to `cwd`, and
  /// does nothing when the trash holds no folder for the session. It throws,
  /// and the folder stays, when git already dropped the worktree's record,
  /// when something is at `cwd`, or when the rename fails. It runs on the
  /// state queue.
  func restoreFromTrash(_ id: String) throws {
    guard let session = entries[id]?.session, let trash = trashedFolder(id) else { return }
    // A folder put back after `git worktree remove` has a .git file that names a deleted admin folder.
    guard session.removal?.released != true else {
      throw APIError(
        "git no longer lists \(session.cwd) as a worktree, so sbd can't move its folder back from the trash at \(trash). Retry the delete to finish it."
      )
    }
    guard linkStatus(session.cwd) == nil else {
      throw APIError(
        "\(session.cwd) exists, so sbd can't move the folder back from the trash at \(trash). Move \(session.cwd) away, then keep the session again."
      )
    }
    let failure = rename(trash, to: session.cwd)
    guard failure == 0 else {
      throw APIError("sbd couldn't move \(trash) back to \(session.cwd): \(UnixSocket.errnoText(failure)).")
    }
  }

  /// The refusal for a request that would forget a session whose worktree
  /// folder is in the trash and has not passed the check there, or nil. The
  /// purge deletes a trash folder that no session's removal names. It runs
  /// on the state queue.
  func trashRefusal(_ id: String) -> APIError? {
    guard let trash = trashedFolder(id), entries[id]?.session.removal?.released != true else { return nil }
    return APIError(
      "The worktree of \(id) is in the trash at \(trash), and sbd hasn't shown that it is safe to delete. Retry the delete, or keep the session to move the folder back."
    )
  }

  /// Deletes every entry in the trash whose name no session's removal names.
  /// A failed removal names its folder too. It runs on the state queue, and
  /// the deletes run on `trashQueue`.
  func purgeUnnamedTrash() {
    guard let trash = linkStatus(home.trash), isFolder(trash) else { return }
    // A home path that changed form between runs would not match a stored path, so the names are compared.
    let named = Set(
      entries.values.compactMap { $0.session.removal?.trash }.map { URL(fileURLWithPath: $0).lastPathComponent })
    for name in (try? FileManager.default.contentsOfDirectory(atPath: home.trash)) ?? [] where !named.contains(name) {
      purge("\(home.trash)/\(name)")
    }
  }

  /// Deletes the file or folder at `path` on `trashQueue`. It deletes a
  /// symlink, not what the symlink names. It refuses a path that is not an
  /// entry directly inside the trash.
  func purge(_ path: String) {
    let entry = URL(fileURLWithPath: path).standardized
    guard entry.deletingLastPathComponent().path == URL(fileURLWithPath: home.trash).standardized.path,
      !["", ".", ".."].contains(entry.lastPathComponent)
    else {
      logLine("won't delete \(path): it is not in the trash at \(home.trash)")
      return
    }
    trashQueue.async {
      do {
        try FileManager.default.removeItem(atPath: path)
      } catch {
        logLine("can't delete \(path) from the trash: \(error)")
      }
    }
  }
}

/// The file's status without following a final symlink, or nil when nothing is at the path.
private func linkStatus(_ path: String) -> stat? {
  var status = stat()
  return lstat(path, &status) == 0 ? status : nil
}

private func isFolder(_ status: stat) -> Bool { status.st_mode & S_IFMT == S_IFDIR }

/// Renames `from` to `to`, and refuses when `to` exists. Returns 0, or the errno of the failure.
private func rename(_ from: String, to: String) -> Int32 {
  renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
}
