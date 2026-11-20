import Foundation
import SwitchboardCore

/// What sbd has seen of each child, and what it has not yet told each parent.
struct ParentNotices {
  /// What each child showed when its parent last heard about it. A work
  /// session hears about its children at each tick. A Manager or a chat
  /// hears at each digest.
  var marks: [String: ChildMark] = [:]
  /// The lines for each parent, oldest first.
  var unsent: [String: [Line]] = [:]

  /// A line of a notice, with the id of the child that it is about.
  struct Line: Equatable {
    var child: String
    var text: String
  }
}

extension Service {
  func parentOf(_ session: Session) -> String? {
    SessionTree.parentID(
      of: session.id, parent: session.parent, followup: session.followup, isKnown: { entries[$0] != nil })
  }

  /// What the child's parent sees of it. A parent on a host sees the child as `showsGitHub` lets that host see it.
  private func mark(_ id: String, now: Int64) -> (mark: ChildMark, reason: String) {
    let e = entries[id]!
    let facts = factsForParent(id)
    let isDocket = e.session.docket != nil
    // Until its first prompt, a child waits for the prompt that started it. A docket row never gets a prompt.
    if !isDocket, facts.prompts == 0, facts.lastReply == nil { return (.fresh, "") }
    let verdict = Attention.evaluate(e.session, facts, now: now, stateOf: lastState)
    let needs = isDocket && verdict.state == .needsYou ? verdict.reason : nil
    return (ChildMark(state: verdict.state, pr: facts.pr?.number, needs: needs), verdict.reason)
  }

  /// The child's facts as its parent may read them. A parent on a host reads them as a request from that host.
  private func factsForParent(_ id: String) -> SessionFacts {
    shownFacts(id, for: RequestOrigin(host: parentOf(entries[id]!.session).flatMap { entries[$0]?.session.host }))
  }

  /// Records that the child's parent hears what the child shows now. It
  /// returns the mark from before and the mark from now. The mark from now
  /// keeps every PR number that the parent heard before.
  private func hear(_ id: String, now: Int64) -> (before: ChildMark, after: ChildMark, reason: String) {
    let (seen, reason) = mark(id, now: now)
    let before = parentNotices.marks[id] ?? .fresh
    let after = before.updated(to: seen)
    parentNotices.marks[id] = after
    return (before, after, reason)
  }

  private func prURL(_ id: String) -> String? {
    factsForParent(id).pr.flatMap { PRSummary($0).link?.absoluteString }
  }

  private func hearsNotices(_ parent: String) -> Bool { entries[parent]?.session.kind.hearsChildNotices ?? true }

  /// Records what each child shows now and every PR number it has had, so sbd
  /// tells no parent about what happened before it started.
  func seedParentMarks(now: Int64) {
    for (id, e) in entries where parentOf(e.session) != nil { seedMark(id, now: now) }
  }

  /// Records what the child shows now and every PR number it has had, so its
  /// parent hears only what changes after now.
  func seedMark(_ id: String, now: Int64) {
    var seeded = mark(id, now: now).mark
    seeded.heardPRs.formUnion(factsForParent(id).prNumbers)
    parentNotices.marks[id] = seeded
  }

  /// Drops the child's mark and every line about it that a parent has not
  /// heard yet.
  func forgetChild(_ id: String) {
    parentNotices.marks[id] = nil
    for (parent, lines) in parentNotices.unsent {
      let kept = lines.filter { $0.child != id }
      parentNotices.unsent[parent] = kept.isEmpty ? nil : kept
    }
  }

  /// The states of the work sessions that are not the parent's children. A
  /// chat counts only the sessions in its group, because its tools reach no
  /// others.
  private func otherCounts(_ parent: String) -> BoardCounts {
    let group = entries[parent]?.session.chat
    var counts = BoardCounts()
    for e in entries.values
    where e.session.kind == .work && parentOf(e.session) != parent && (group == nil || e.session.group == group) {
      counts.add(e.facts.lastState)
    }
    return counts
  }

  /// Collects what changed in each child since the last tick, then sends each
  /// parent one message with everything it has not heard. A parent whose turn
  /// runs, or that still has a message on its way, hears it after the turn,
  /// so a busy parent gets one message for many changes.
  func notifyParents(now: Int64) {
    collectChildChanges(now: now)
    for parent in parentNotices.unsent.keys.sorted() {
      guard let e = entries[parent], !e.session.done else {
        parentNotices.unsent[parent] = nil
        continue
      }
      guard let lines = parentNotices.unsent[parent], !lines.isEmpty, canTakeNotice(e, now: now) else { continue }
      do {
        _ = try send(parent, ParentNotice.message(lines.map(\.text)), by: .sbd, trigger: .notice)
        parentNotices.unsent[parent] = nil
      } catch {
        logLine("can't tell \(parent) about its children: \(error)")
      }
    }
  }

  private func collectChildChanges(now: Int64) {
    var children: Set<String> = []
    for id in entries.keys.sorted() {
      guard let e = entries[id], let parent = parentOf(e.session) else { continue }
      children.insert(id)
      guard hearsNotices(parent) else { continue }
      let (before, after, reason) = hear(id, now: now)
      guard after != before else { continue }
      parentNotices.unsent[parent, default: []] += ParentNotice.lines(
        name: e.session.name, id: id, before: before, after: after, reason: reason,
        prURL: prURL(id)
      ).map { ParentNotices.Line(child: id, text: $0) }
    }
    parentNotices.marks = parentNotices.marks.filter { children.contains($0.key) }
  }

  /// What changed for a Manager or a chat since its last digest: a line for
  /// each of its children that moved, and `otherCounts`. It is nil for a work
  /// session, and when none of the parent's children moved. A change in the
  /// counts alone sends no digest, because each digest stays in the
  /// conversation's context for every later call. sbd counts the digest as
  /// heard once it returns it. The operator gets none, because its turns come
  /// from schedules and waits that carry their own status.
  func digest(_ parent: String, now: Int64) -> String? {
    guard entries[parent]?.session.kind != .operator, !hearsNotices(parent) else { return nil }
    var lines: [String] = []
    for id in entries.keys.sorted() {
      guard let e = entries[id], parentOf(e.session) == parent else { continue }
      let (heard, current, reason) = hear(id, now: now)
      if let line = ParentDigest.line(
        name: e.session.name, id: id, heard: heard, now: current, reason: reason, prURL: prURL(id))
      {
        lines.append(line)
      }
    }
    guard !lines.isEmpty else { return nil }
    return ParentDigest.text(lines, elsewhere: otherCounts(parent))
  }

  /// The digest that a Manager conversation or the operator gets when its
  /// conversation starts, which a SessionStart with `source` startup reports.
  /// It is nil for every other kind and source. It leaves out every Manager
  /// conversation and the operator.
  func startDigest(_ id: String, source: String?) -> String? {
    guard let session = entries[id]?.session, session.kind.runsInManagerFolder, source == "startup" else { return nil }
    let all = summaries(for: RequestOrigin(host: session.host)).filter { $0.id != id && !$0.kind.runsInManagerFolder }
    return ParentDigest.startText(all, inbox: Triage.order(all))
  }

  func canTakeNotice(_ e: Entry, now: Int64) -> Bool {
    Pause.blocker(e.session) == nil && !messageWaiting(e, now: now) && !e.facts.turnRunning
      && !mcpStarting(now: now)
  }
}
