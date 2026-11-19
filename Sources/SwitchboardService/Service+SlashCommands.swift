import Foundation
import SwitchboardCore

extension Service {
  /// The `slash-commands` request: the commands that the user can type in
  /// the session's claude. It reads the transcript and the folders off the
  /// state queue. A repeat request on the same transcript reads only the
  /// lines added since the last one. For a Manager conversation or the
  /// operator, each row carries the label of the hook's decision.
  func slashCommands(_ args: JSON) throws -> JSON {
    let (id, findTranscript, account, cwd, machine, cached, decide) = try queue.sync {
      () -> (
        String, () -> String?, String?, String, any Machine, (path: String, state: SkillListing.State)?,
        SkillDecider?
      ) in
      let id = try lookup(args)
      let session = entries[id]!.session
      // Until a host answers, its folder is unknown. The scan then reads only the cwd.
      let account = try? claudeFolder(of: session)
      return (
        id, transcriptFinder(id), account, session.cwd, try site(of: id).machine, slashListings[id],
        managerSkillDecider(id)
      )
    }
    let listing = skillListing(id, findTranscript: findTranscript, machine: machine, cached: cached)
    var commands = SlashCommands.merge(
      listing: listing, scanned: SkillFolders.scan(account: account, cwd: cwd, on: machine),
      overrides: SkillFolders.overrides(account: account, on: machine))
    if let decide {
      for i in commands.indices { commands[i].label = decide(commands[i].name, nil).label }
    }
    return ["commands": try JSON(encoding: commands), "listing": .bool(listing != nil)]
  }

  /// The session's latest transcript skill listing, or nil when the
  /// transcript holds none or can't be found. It reads off the state queue
  /// and saves the folded state in `slashListings[id]`, so that a later read
  /// of the same transcript from `cached` reads only the lines added since.
  /// The caller takes `findTranscript`, `machine`, and `cached` (the
  /// session's `slashListings` entry) on the state queue.
  func skillListing(
    _ id: String, findTranscript: () -> String?, machine: any Machine,
    cached: (path: String, state: SkillListing.State)?
  ) -> [SlashCommand]? {
    dispatchPrecondition(condition: .notOnQueue(queue))
    guard let path = findTranscript() else { return nil }
    var state = SkillListing.State()
    let read: Bool
    if let cached, cached.path == path {
      state = cached.state
      read = SkillListing.read(path, from: state.offset, into: &state, on: machine)
    } else {
      read = SkillListing.read(path, into: &state, on: machine)
    }
    // A failed read drops the entry, so that the next request reads the transcript from the end again.
    queue.sync {
      if entries[id] != nil { slashListings[id] = read ? (path, state) : nil }
    }
    return state.commands
  }
}
