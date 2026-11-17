import Foundation
import SwitchboardCore

/// Which Claude account each session runs under. A session records its
/// account when sbd creates or imports it, and keeps it, because the
/// conversation's transcript lives in the account's folder.
extension Service {
  /// The account that a new session without a parent uses: the one that
  /// `sb account use` chose, else CLAUDE_CONFIG_DIR from config.env or from
  /// sbd's environment, else Claude's default account.
  var activeAccount: ClaudeAccount {
    let configured = config.env["CLAUDE_CONFIG_DIR"] ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    return chosenAccount ?? ClaudeAccount(folder: configured ?? ClaudeAccount.defaultFolder)
  }

  /// Reads the account that `sb account use` chose. A folder that no longer
  /// holds an account is ignored, so a removed account doesn't stop sessions
  /// from starting.
  func loadChosenAccount() {
    guard let text = try? String(contentsOfFile: home.activeAccount, encoding: .utf8) else { return }
    let folder = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let account = ClaudeAccount(folder: folder)
    if account.holdsAccount {
      chosenAccount = account
    } else {
      logLine("ignoring the chosen account \(folder): it holds no Claude account")
    }
  }

  func resolveAccount(_ ref: String) throws -> Account {
    .claude(try ClaudeAccount.resolve(ref, among: accounts.compactMap(\.claude)))
  }

  /// The account that `ref` names, for a request that only a Claude account can serve, such as `account use` or
  /// `account move`.
  func resolveClaudeAccount(_ ref: String) throws -> ClaudeAccount {
    switch try resolveAccount(ref) {
    case .claude(let account): account
    }
  }

  /// The account of a new session: its group's account, else the one named,
  /// else its parent's when the parent runs on this Mac, or nil when none of
  /// them applies. A parent on a host has the host's account, which no session
  /// on this Mac can use. It refuses a named
  /// account that differs from the group's, because the session's next launch
  /// would move it to the group's account.
  func accountForNew(named ref: String?, parent: String?, for session: Session) throws -> String? {
    let named = try ref.flatMap { $0.isEmpty ? nil : try resolveAccount($0).folder }
    if let group = accountGroupForNew(session), let bound = group.account {
      if let named, named != bound {
        throw APIError(
          "the group \(group.name) runs its sessions under the account \(ClaudeAccount(folder: bound).name). Leave out the account, or pick another group"
        )
      }
      return bound
    }
    if let named { return named }
    if let parent, let entry = entries[parent], entry.session.host == nil { return claudeAccount(of: parent).key }
    return nil
  }

  /// The session's account group, while the group's folder still holds a
  /// Claude account. A new session in a group whose account folder went away
  /// uses the account it would use without the group.
  func accountGroupForNew(_ session: Session) -> SessionGroup? {
    accountGroup(of: session).flatMap { ClaudeAccount(folder: $0.account!).holdsAccount ? $0 : nil }
  }

  /// The group whose account the session runs under, or nil when that group
  /// names no account. A chat's group is the one it manages.
  func accountGroup(of session: Session) -> SessionGroup? {
    (session.chat ?? session.group).flatMap { groups[$0] }.flatMap { $0.account == nil ? nil : $0 }
  }

  /// The accounts that `sb account` lists: `accounts`, with the active account inserted first when `accounts`
  /// doesn't include it.
  func listedAccounts() -> [Account] {
    let active = Account.claude(activeAccount)
    var all = accounts
    if !all.contains(active) { all.insert(active, at: 0) }
    return all
  }

  func accountList() -> [AccountInfo] {
    let active = Account.claude(activeAccount)
    let counts = Dictionary(grouping: entries.keys.filter { entries[$0]!.session.runsClaude }) {
      claudeAccount(of: $0).key
    }
    return listedAccounts().map {
      AccountInfo(name: $0.name, folder: $0.folder, active: $0 == active, sessions: counts[$0.folder]?.count ?? 0)
    }
  }

  func accountRequest(_ op: String, _ args: JSON) throws -> JSON {
    if op == "account-move" { return try JSON(encoding: moveSessions(args)) }
    if op == "account-use" {
      guard let ref = args["account"]?.string, !ref.isEmpty else { throw APIError("name an account") }
      let account = try resolveClaudeAccount(ref)
      try account.folder.write(toFile: home.activeAccount, atomically: true, encoding: .utf8)
      chosenAccount = account
      logLine("new sessions use the account \(account.folder)")
    }
    return try JSON(encoding: accountList())
  }

  /// Throws when the target of `account-use` or `account-move` has no login,
  /// because claude would ask a session there for /login. A target whose last
  /// reading found no login is read again first, so an account that signed in
  /// since then is accepted. A reading that failed for another reason, such
  /// as a locked keychain, lets the account through. So does an account that
  /// sbd has not read. It must run off the state queue, because a read waits
  /// on the keychain and the network.
  func requireSignedIn(_ args: JSON) throws {
    guard let reader = usageReader, let ref = args["account"]?.string,
      let account = try? queue.sync(execute: { try resolveClaudeAccount(ref) }),
      Self.signedOutRefusal(reader.latest(account.folder)) != nil
    else { return }
    if let refusal = Self.signedOutRefusal(reader.read(account)) { throw APIError(refusal) }
  }

  /// The account's name followed by the reading's `SignedOut` error. That
  /// error names the login command.
  static func signedOutRefusal(_ reading: AccountUsage?) -> String? {
    guard let reading, reading.signedOut == true else { return nil }
    return "\(reading.name) is \(reading.error ?? "not signed in")"
  }
}

// MARK: Moving sessions

extension Service {
  /// Moves every session that is not on the account to it, or with `dryRun`
  /// lists the ones that would move. Only a session whose claude is stopped
  /// moves: a claude that runs, or a message on its way, keeps writing the
  /// old account's transcript, and a second claude that resumes the
  /// conversation forks it. `sessions`, a list of session refs, limits the
  /// move to those sessions. The result then lists each named session that
  /// stays in `blocked`, including one already on the account. `stop` needs
  /// `sessions`. Before a move with `stop` runs, sbd stops the claudes that
  /// `sessionsToStopForMove` picks. Only a dry run lists a running named
  /// session as one that would move.
  func moveSessions(_ args: JSON) throws -> AccountMove {
    let target = try moveTarget(args)
    let dryRun = args["dryRun"]?.bool ?? false
    let named = try namedForMove(args)
    let stopsClaude = dryRun && args["stop"]?.bool == true
    var result = AccountMove(account: target.folder)
    for id in named ?? entries.keys.sorted() {
      guard let session = entries[id]?.session else { continue }
      let block = { (reason: String) in result.blocked.append(.init(session: id, name: session.name, reason: reason)) }
      if let reason = notMovable(session, to: target) {
        if named != nil { block(reason) }
        continue
      }
      if let reason = moveRefusal(id, to: target, stopsClaude: stopsClaude) {
        block(reason)
        continue
      }
      do {
        if !dryRun { try move(id, to: target) }
        result.moved.append(id)
      } catch {
        block("\(error)")
      }
    }
    if !dryRun && !result.moved.isEmpty {
      logLine("moved \(result.moved.count) sessions to the account \(target.folder)")
    }
    return result
  }

  /// The sessions whose claude an `account-move` with `stop` stops: the named
  /// sessions that a dry run of the move lists and whose claude runs. A
  /// session that the move refuses for another reason keeps its claude. It
  /// runs on the state queue.
  func sessionsToStopForMove(_ args: JSON) throws -> [String] {
    var dryRun = args.object ?? [:]
    dryRun["dryRun"] = .bool(true)
    return try moveSessions(.object(dryRun)).moved.filter {
      if case .running = claudeState($0) { true } else { false }
    }
  }

  private func moveTarget(_ args: JSON) throws -> ClaudeAccount {
    guard let ref = args["account"]?.string, !ref.isEmpty else { throw APIError("name an account") }
    return try resolveClaudeAccount(ref)
  }

  /// The sessions that the request's `sessions` names, or nil when it names
  /// none. `stop` without `sessions` throws, so that it never stops every claude.
  private func namedForMove(_ args: JSON) throws -> [String]? {
    guard let value = args["sessions"] else {
      if args["stop"]?.bool == true { throw APIError("stop moves only named sessions. Name one with --session") }
      return nil
    }
    guard let refs = value.array, !refs.isEmpty else { throw APIError("sessions is a list of one or more sessions") }
    return try Set(refs.map { try lookup(["session": $0]) }).sorted()
  }

  /// Why a move of every session skips the session without listing it.
  private func notMovable(_ session: Session, to target: ClaudeAccount) -> String? {
    if session.cwd.isEmpty { return "it has not started" }
    if claudeAccount(of: session.id) == .local(target) { return "it already runs under \(target.name)" }
    return nil
  }

  /// Why the session cannot move now, so that `dryRun` lists the same
  /// sessions as a move. `stopsClaude` passes a claude that runs, because the
  /// move stops it first.
  private func moveRefusal(_ id: String, to target: ClaudeAccount, stopsClaude: Bool) -> String? {
    guard let e = entries[id] else { return "no session \(id)" }
    if let host = e.session.host { return "it runs under the Claude login of \(host)" }
    if let group = accountGroup(of: e.session), let bound = group.account, bound != target.folder {
      return
        "its group \(group.name) runs its sessions under the account \(ClaudeAccount(folder: bound).name). Move it out of the group, or change the group's account with sb group account"
    }
    if starting.contains(id) { return "it is starting" }
    if let refusal = beingDeletedRefusal(id) { return "\(refusal)" }
    switch claudeState(id) {
    case .stopped: break
    case .running where stopsClaude: break
    default: return "its claude is running. Stop it first"
    }
    if !e.pending.isEmpty || e.inFlight != nil { return "a message is on its way to it" }
    if let source = transcriptFile(e.session) {
      let dest = transcriptDestination(source, id: e.session.claudeSessionId, to: target)
      if let conflict = transcriptConflict(source, dest) { return conflict }
    }
    return nil
  }

  private func transcriptDestination(_ source: String, id: String, to target: ClaudeAccount) -> String {
    let folder = ((source as NSString).deletingLastPathComponent as NSString).lastPathComponent
    return "\(target.folder)/projects/\(folder)/\(id).jsonl"
  }

  /// Why the account's file at `dest` rules out a copy of `source`: it holds
  /// another transcript of the conversation.
  private func transcriptConflict(_ source: String, _ dest: String) -> String? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: dest), !sameFile(source, dest), !fm.contentsEqual(atPath: source, andPath: dest),
      !startsWith(source, dest)
    else { return nil }
    return "the account already holds another transcript of this conversation, at \(dest)"
  }

  /// Copies the conversation's transcript to the account, then switches the
  /// session to it. The old copy stays. A session whose claude never wrote a
  /// transcript has none to copy, and starts its conversation in the account.
  private func move(_ id: String, to target: ClaudeAccount) throws {
    let session = entries[id]!.session
    guard case .local(let from) = claudeAccount(of: id) else {
      throw APIError("it runs under the Claude login of \(session.host ?? "its host")")
    }
    if let source = transcriptFile(session) {
      try copyConversation(source, id: session.claudeSessionId, from: from, to: target)
    }
    try update(id) { $0.claudeConfigDir = target.folder }
    record(id, "account-moved", ["from": .string(from.folder), "to": .string(target.folder)])
  }

  /// Moves a stopped session to its group's account before claude launches.
  /// The caller has checked that no claude runs for the session. A pending
  /// message waits for this launch, so it does not stop the move. The move
  /// fails when the account holds no login, when its last reading found it
  /// signed out, or when the copy fails. The copy fails when the account holds
  /// another transcript of the conversation. After a failure, the session stays
  /// on its account, and an `account-move-skipped` event records why. Its next
  /// launch tries again.
  func moveToGroupAccount(_ id: String) {
    guard let session = entries[id]?.session, let target = accountGroup(of: session)?.account else { return }
    let from = claudeAccount(of: id).key
    guard from != target else { return }
    let account = ClaudeAccount(folder: target)
    let reason: String?
    if !account.holdsAccount {
      reason = "\(target) holds no Claude account"
    } else if let refusal = Self.signedOutRefusal(usageReader?.latest(target)) {
      reason = refusal
    } else {
      do {
        try move(id, to: account)
        reason = nil
      } catch {
        reason = "\(error)"
      }
    }
    guard let reason else { return }
    logLine("\(id) stays on the account \(from) instead of its group's \(target): \(reason)")
    record(id, "account-move-skipped", ["from": .string(from), "to": .string(target), "reason": .string(reason)])
  }

  /// Puts the transcript at <to>/projects/<same folder>/<id>.jsonl, the
  /// conversation's folder beside it, which holds its subagent transcripts and
  /// tool results, and its file history, which a rewind needs. An account that
  /// shares a folder, such as through a symlink, already holds those files. A
  /// copy of the transcript that is a prefix of the source, left by an earlier
  /// move, is replaced. Another transcript makes this throw, because claude
  /// resumes the one it finds.
  private func copyConversation(_ source: String, id: String, from: ClaudeAccount, to target: ClaudeAccount) throws {
    let fm = FileManager.default
    let dest = transcriptDestination(source, id: id, to: target)
    let dir = (dest as NSString).deletingLastPathComponent
    if let conflict = transcriptConflict(source, dest) { throw APIError(conflict) }
    if !fm.fileExists(atPath: dest) || !fm.contentsEqual(atPath: source, andPath: dest) {
      try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try replaceFile(dest, with: source)
    }
    let sourceDir = (source as NSString).deletingPathExtension
    try copyMissing(sourceDir, to: (dest as NSString).deletingPathExtension)
    try copyMissing("\(from.folder)/file-history/\(id)", to: "\(target.folder)/file-history/\(id)")
  }

  /// Copies each file under `source` that `dest` lacks. A file at `dest` that
  /// is the first bytes of the one at `source`, left by an earlier move, is
  /// replaced. Any other file at `dest` stays. Nothing happens when `source`
  /// does not exist.
  private func copyMissing(_ source: String, to dest: String) throws {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: source, isDirectory: &isDir) else { return }
    guard !fm.fileExists(atPath: dest) else {
      if isDir.boolValue {
        for name in try fm.contentsOfDirectory(atPath: source) {
          try copyMissing("\(source)/\(name)", to: "\(dest)/\(name)")
        }
      } else if !fm.contentsEqual(atPath: source, andPath: dest), startsWith(source, dest) {
        try replaceFile(dest, with: source)
      }
      return
    }
    try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try fm.copyItem(atPath: source, toPath: dest)
  }

  /// Copies `source` to `dest` through `<dest>.moving`, so `dest` never holds part of a copy. The copy is
  /// checked against `source` and readable only by its owner.
  private func replaceFile(_ dest: String, with source: String) throws {
    let fm = FileManager.default
    let partial = "\(dest).moving"
    try? fm.removeItem(atPath: partial)
    do {
      try fm.copyItem(atPath: source, toPath: partial)
      guard fm.contentsEqual(atPath: source, andPath: partial) else {
        throw APIError("the copy differs from \(source)")
      }
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial)
      if fm.fileExists(atPath: dest) {
        _ = try fm.replaceItemAt(
          URL(fileURLWithPath: dest), withItemAt: URL(fileURLWithPath: partial),
          backupItemName: nil, options: .usingNewMetadataOnly)
      } else {
        try fm.moveItem(atPath: partial, toPath: dest)
      }
    } catch {
      try? fm.removeItem(atPath: partial)
      throw error
    }
  }

  /// Whether the file at `prefix` is the first bytes of the file at `path`.
  private func startsWith(_ path: String, _ prefix: String) -> Bool {
    guard let file = FileHandle(forReadingAtPath: path), let head = FileHandle(forReadingAtPath: prefix) else {
      return false
    }
    defer {
      try? file.close()
      try? head.close()
    }
    while let expected = try? head.read(upToCount: 1 << 20), !expected.isEmpty {
      guard let actual = try? file.read(upToCount: expected.count), actual == expected else { return false }
    }
    return true
  }

  private func sameFile(_ a: String, _ b: String) -> Bool {
    URL(fileURLWithPath: a).resolvingSymlinksInPath() == URL(fileURLWithPath: b).resolvingSymlinksInPath()
  }
}
