import Foundation
import SwitchboardCore

/// The skills that Manager conversations and the operator can load, and their `work` or `safe` labels.
extension Service {
  /// How long a refresh waits before it runs a failed key again.
  static let skillRetryMs: Int64 = 15 * 60_000

  /// The account folder of each manager-kind session on this Mac, mapped to
  /// the account's most recently active one. Runs on the state queue.
  func managerSkillAccounts() -> [String: String] {
    var latest: [String: (id: String, at: Int64)] = [:]
    for (id, e) in entries where e.session.kind.runsInManagerFolder {
      guard case .local(let account) = claudeAccount(of: id) else { continue }
      if let seen = latest[account.folder], seen.at >= e.facts.lastActivity { continue }
      latest[account.folder] = (id, e.facts.lastActivity)
    }
    return latest.mapValues(\.id)
  }

  /// Scans the skills of every account that a manager-kind session uses. Runs on the state queue.
  func refreshManagerSkills() {
    for account in managerSkillAccounts().keys.sorted() { refreshManagerSkills(account: account) }
  }

  /// Scans the account's skills on `skillScanQueue`, then stores the index
  /// and queues the runs that it needs. Runs on the state queue.
  func refreshManagerSkills(account: String) {
    guard let scan = skillScan(account: account) else { return }
    skillScanQueue.async { [self] in
      let found = scan()
      queue.async { [self] in
        skillIndex[account] = found
        queueSkillRuns(account)
      }
    }
  }

  /// Runs on the state queue. It returns a function that runs discovery off
  /// the queue, with the listing of the account's most recently active
  /// manager-kind session. It returns nil when no such session uses the account.
  private func skillScan(account: String) -> (() -> [String: CatalogEntry])? {
    guard let id = managerSkillAccounts()[account] else { return nil }
    skillRefreshed[account] = nowMs()
    let (findTranscript, cached, machine, cwd) = (
      transcriptFinder(id), slashListings[id], mac.machine, home.managerFolder
    )
    return { [self] in
      let listing = skillListing(id, findTranscript: findTranscript, machine: machine, cached: cached)
      return SkillCatalog.discover(account: account, cwd: cwd, listing: listing, machine: machine)
    }
  }

  /// Queues a run for each of the account's entries whose key has no label,
  /// no run on its way, and no failure in the last `skillRetryMs`. A name
  /// that config.json labels never runs. Runs on the state queue.
  func queueSkillRuns(_ account: String) {
    let settings = config.managerSkills
    let now = nowMs()
    for entry in (skillIndex[account] ?? [:]).values.sorted(by: { $0.name < $1.name }) {
      guard settings.override(entry.name) == nil, let key = entry.key(model: settings.model),
        skillLabels.labels[key] == nil, !skillQueued.contains(key)
      else { continue }
      if let failure = skillFailures[key], now - failure.t < Self.skillRetryMs { continue }
      skillQueued.insert(key)
      skillJobs.addOperation { [self] in
        let outcome = classifySkill(entry, account: account, settings: settings)
        queue.async { [self] in finishSkillRun(entry, key: key, account: account, outcome) }
      }
    }
  }

  /// Labels the entry under the account's login, off the state queue. The
  /// label's key is the hash of the text that the run read, which differs
  /// from the queued key when the file changed after the scan.
  private func classifySkill(_ entry: CatalogEntry, account: String, settings: ManagerSkillSettings)
    -> Result<(key: String, answer: SkillClassifier.Answer), SkillFailure>
  {
    func failure(_ category: SkillFailure.Category, _ message: String) -> Result<
      (key: String, answer: SkillClassifier.Answer), SkillFailure
    > {
      .failure(SkillFailure(category: category, message: message, t: nowMs()))
    }
    do {
      try requireSignedIn(["account": .string(account)])
    } catch {
      return failure(.signedOut, "\(error)")
    }
    guard queue.sync(execute: { quota }).hasBudget(account: account) else {
      return failure(.noQuota, "no quota left for \(account)")
    }
    let text: String
    let hash: String
    if let path = entry.path {
      guard let head = SkillFolders.head(path, on: mac.machine), let size = mac.machine.size(path) else {
        return failure(.failed, "can't read \(path)")
      }
      (text, hash) = (String(decoding: head, as: UTF8.self), SkillHash.file(head: head, size: size))
    } else if let description = entry.description {
      (text, hash) = ("description: \(description)", SkillHash.listing(name: entry.name, description: description))
    } else {
      return failure(.failed, "\(entry.name) has neither a file nor a description")
    }
    let output: String
    do {
      output = try runHeadless(
        SkillClassifier.arguments(model: settings.model), input: SkillClassifier.input(name: entry.name, text: text),
        env: headlessEnv(session: nil, account: ClaudeAccount(folder: account)), folder: home.path,
        timeout: settings.timeoutSeconds)
    } catch let error as Headless.TimedOut {
      return failure(.timeout, "\(error)")
    } catch {
      return failure(.failed, "\(error)")
    }
    do {
      return .success((SkillLabelCache.key(hash: hash, model: settings.model), try SkillClassifier.parse(output)))
    } catch {
      return failure(.badAnswer, "\(error)")
    }
  }

  /// Saves a label, or keeps the failure in memory. Runs on the state queue.
  private func finishSkillRun(
    _ entry: CatalogEntry, key: String, account: String,
    _ outcome: Result<(key: String, answer: SkillClassifier.Answer), SkillFailure>
  ) {
    skillQueued.remove(key)
    switch outcome {
    case .success(let (labelKey, answer)):
      skillFailures[key] = nil
      skillLabels.labels[labelKey] = SkillLabelCache.Label(
        label: answer.label, reason: answer.reason, model: config.managerSkills.model, t: nowMs())
      saveSkillLabels()
    case .failure(let failure):
      skillFailures[key] = failure
      logLine("can't label the skill \(entry.name) of \(account): \(failure.message)")
    }
  }

  private func saveSkillLabels() {
    do {
      try skillLabels.save(home.skillLabels)
    } catch {
      logLine("can't save the skill labels: \(error)")
    }
  }

  /// The `manager-skills` request. It answers the rows of every account that
  /// a manager-kind session uses, or of `session`'s account. `relabel` and
  /// `all` scan the folders again first. Then `relabel` drops the labels and
  /// failures of those names' current keys and queues them again, and `all`
  /// does the same for every name. It runs off the state queue.
  func managerSkills(_ args: JSON) throws -> JSON {
    let all = args["all"]?.bool == true
    let names = (args["relabel"]?.array ?? []).compactMap(\.string).map {
      $0.hasPrefix("/") ? String($0.dropFirst()) : $0
    }
    let rescan = all || !names.isEmpty
    let scans = try queue.sync {
      () -> [(account: String, scan: (() -> [String: CatalogEntry])?)] in
      try skillAccounts(args["session"]?.string).sorted().map { ($0, rescan ? skillScan(account: $0) : nil) }
    }
    var found: [String: [String: CatalogEntry]] = [:]
    for (account, scan) in scans {
      if let scan { found[account] = skillScanQueue.sync(execute: scan) }
    }
    return try queue.sync {
      let accounts = scans.map(\.account)
      found.forEach { skillIndex[$0.key] = $0.value }
      if rescan { try relabelSkills(all ? nil : names, accounts: accounts) }
      let settings = config.managerSkills
      let rows = accounts.flatMap { account in
        ManagerSkillRow.rows(
          skillIndex[account] ?? [:], settings: settings, labels: skillLabels, failures: skillFailures,
          queued: skillQueued)
      }
      return try JSON(encoding: rows)
    }
  }

  /// The accounts that the request covers: every one that a manager-kind
  /// session uses, or the account of the conversation or operator that `ref`
  /// names. Runs on the state queue.
  private func skillAccounts(_ ref: String?) throws -> [String] {
    let accounts = managerSkillAccounts()
    guard let ref, !ref.isEmpty else { return Array(accounts.keys) }
    let sessions = entries.values.map(\.session).filter(\.kind.runsInManagerFolder)
    let id = try resolveRef(ref, "Manager conversation", sessions.map { ($0.id, $0.name) })
    guard case .local(let account) = claudeAccount(of: id) else { return [] }
    return [account.folder]
  }

  /// Drops the labels and failures of the names' current keys, or of every
  /// name when `names` is nil, and queues them again. It throws for a name
  /// that no account holds. Runs on the state queue.
  private func relabelSkills(_ names: [String]?, accounts: [String]) throws {
    if let names {
      let settings = config.managerSkills
      let known = Set(accounts.flatMap { (skillIndex[$0] ?? [:]).keys } + settings.work + settings.safe)
      let unknown = names.filter { !known.contains($0) }
      guard unknown.isEmpty else { throw APIError("no skill named \(unknown.joined(separator: ", "))") }
    }
    let model = config.managerSkills.model
    for account in accounts {
      for entry in (skillIndex[account] ?? [:]).values where names?.contains(entry.name) ?? true {
        guard let key = entry.key(model: model) else { continue }
        skillLabels.labels[key] = nil
        skillFailures[key] = nil
      }
    }
    saveSkillLabels()
    accounts.forEach(queueSkillRuns)
  }
}
