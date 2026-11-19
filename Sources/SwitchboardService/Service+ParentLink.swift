import Foundation
import SwitchboardCore

extension Service {
  /// The `parent` request, which moves `session` to the session that `parent` names, or with `clear` true unlinks
  /// it from its parent. The old parent stops hearing what changed in it, and queued lines about it are dropped. A
  /// new parent hears only what changes after the move. The session keeps its group, account, host, and waits. It
  /// records `unlinked` on the session and its old parent, and `linked` on the session and its new parent. It
  /// refuses a follow-up, whose parent is the session that captured it, the asking session `caller`, a session
  /// outside a scoped request's `scope`, and a move that would put the session under itself. A clear with `from`
  /// refuses when the session's parent is no longer `from`, so a stale view can't unlink it from another parent.
  func parentRequest(_ args: JSON, origin: RequestOrigin) throws -> JSON {
    let by = try Author(parsing: args["by"]?.string)
    let id = try lookupOther(args, refusing: "change its own parent")
    try requireInScope(.session(id), args)
    let session = entries[id]!.session
    if session.followup != nil {
      throw APIError("\(session.name) is a follow-up, and its parent is the session that captured it")
    }
    let clear = args["clear"]?.bool == true
    guard clear != (args["parent"] != nil) else { throw APIError("parent needs a parent or clear, not both") }
    let new: String?
    if clear {
      guard let old = session.parent else { throw APIError("\(session.name) has no parent") }
      if let from = args["from"]?.string, from != old {
        throw APIError("\(session.name) is no longer under \(entries[from]?.session.name ?? from)")
      }
      new = nil
    } else {
      let ref = args["parent"]!
      let parent: String
      do {
        parent = try lookup(["session": ref])
      } catch {
        // A scoped request gets the scope's refusal for a name that matches no session, so a group chat can't
        // learn which names exist outside its group.
        try requireInScope(.session(ref.string ?? ""), args)
        throw error
      }
      try requireInScope(.session(parent), args)
      try refuseParent(parent, for: id)
      guard parent != session.parent else { return try JSON(encoding: summary(id, for: origin)) }
      new = parent
    }
    try updateOrRestore([id]) { _, s in s.parent = new }
    forgetChild(id)
    if let old = session.parent { recordUnlink(child: id, from: old, by: by) }
    if let new {
      seedMark(id, now: nowMs())
      record(id, "linked", ["parent": .string(new), "by": .string(by.rawValue)])
      record(new, "linked", ["child": .string(id), "by": .string(by.rawValue)])
    }
    return try JSON(encoding: summary(id, for: origin))
  }

  private func refuseParent(_ parent: String, for id: String) throws {
    let child = entries[id]!.session
    let p = entries[parent]!.session
    guard parent != id else { throw APIError("\(child.name) can't be its own parent") }
    guard p.runsClaude else { throw APIError("\(p.name) runs no claude, so it can't hear about a child") }
    guard child.kind == .work else { throw APIError("only a work session can have a parent") }
    if reachesUp(from: parent, to: id) { throw APIError("\(p.name) is already under \(child.name)") }
  }

  /// True when following `parent` fields up from `start` reaches `target`. It stops at a session sbd doesn't hold
  /// and at a loop that doesn't pass through `target`.
  private func reachesUp(from start: String, to target: String) -> Bool {
    var seen: Set<String> = []
    var next: String? = start
    while let id = next, seen.insert(id).inserted {
      if id == target { return true }
      next = entries[id]?.session.parent
    }
    return false
  }

  /// Records `unlinked` on the child, and on the old parent when sbd still holds it.
  private func recordUnlink(child id: String, from old: String, by: Author) {
    record(id, "unlinked", ["parent": .string(old), "by": .string(by.rawValue)])
    if entries[old] != nil { record(old, "unlinked", ["child": .string(id), "by": .string(by.rawValue)]) }
  }
}
