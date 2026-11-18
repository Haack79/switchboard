import SwiftUI
import SwitchboardCore

/// The removal sheet's confirmation: sbd checks the sessions, and the user confirms the plan. Delete All plans
/// every Done session with the `done` scope. Delete N Sessions… plans the multi-selection with the `work` scope.
/// `rm-queue` sends the same scope as the plan. Each check has its own `request`, so a reply to a check that the
/// user cancelled never fills a later one.
enum DoneRemoval: Equatable {
  case checking(RemovalScope, request: UUID)
  case confirming(RemovalPlan, scope: RemovalScope)
}

enum DoneRemovalText {
  static func title(_ plan: RemovalPlan, scope: RemovalScope) -> String {
    let kind = scope == .done ? "Done session" : "session"
    return switch plan.remove.count {
    case 0: "No \(kind) can be deleted"
    case 1: "Delete 1 \(kind)?"
    case let n: "Delete \(n) \(kind)s?"
    }
  }

  static func checking(_ scope: RemovalScope) -> String {
    scope == .done ? "Checking the Done sessions…" : "Checking the sessions…"
  }

  /// The heading of the sessions that the plan skips.
  static func stays(_ scope: RemovalScope) -> String { scope == .done ? "Stays in Done" : "Stays" }

  static func selected(_ count: Int) -> String { "\(count) sessions selected" }

  static func deleteSessions(_ count: Int) -> String {
    count == 1 ? "Delete 1 Session…" : "Delete \(count) Sessions…"
  }

  /// The plan row's note for a session whose claude the delete stops while it works, or nil.
  static func working(_ session: SessionSummary?) -> String? {
    session?.state == .working ? "claude is working and stops" : nil
  }

  static func removing(_ count: Int) -> String { count == 1 ? "Removing 1 session…" : "Removing \(count) sessions…" }

  static func notices(_ count: Int) -> String { count == 1 ? "1 delete notice" : "\(count) delete notices" }

  /// The banner's text for the sessions that a delete left in place, or that Undo could not bring back, after
  /// `heading`. It is nil when the list is empty.
  static func skipped(_ skips: [RemovalPlan.Skip], _ heading: String = "Not deleted") -> String? {
    skips.isEmpty ? nil : "\(heading): " + skips.map { "\($0.name): \($0.reason)" }.joined(separator: "; ")
  }

  static func deletes(_ item: RemovalPlan.Item) -> String {
    var parts = ["session"]
    if item.worktree != nil { parts.append("worktree") }
    if item.branch != nil { parts.append("branch") }
    if item.remoteBranch { parts.append("remote branch") }
    return englishList(parts)
  }
}

extension BoardModel {
  /// The arguments of Delete All's plan and of every `rm-queue` from the app: the worktree, and sbd adds the
  /// branch and the remote branch when the PR merged.
  nonisolated static let doneRemovalArgs: [String: JSON] = ["worktree": true, "remote_branch": true]

  /// The `rm-queue` that hands the sessions `ids` to sbd's removal job. `resolve` holds the ids of the
  /// open to-dos that the confirmation showed.
  nonisolated static func queueRequest(
    _ ids: [String], scope: RemovalScope, resolve: [String] = []
  ) -> [String: JSON] {
    resolving(planRequest(ids, scope: scope), resolve)
  }

  /// The `rm-plan` arguments for the sessions `ids`, or for every Done session when `ids` is nil. `rm-queue` takes
  /// the same ones.
  nonisolated static func planRequest(_ ids: [String]?, scope: RemovalScope) -> [String: JSON] {
    var args = doneRemovalArgs
    args["scope"] = .string(scope.rawValue)
    if let ids { args["targets"] = .array(ids.map(JSON.string)) }
    return args
  }

  nonisolated static let unreadOrgReason = "sbd hasn't read its org yet"
  nonisolated static let unlistedGroupsReason = "sbd hasn't listed the groups yet"
  nonisolated static let unlistedReason = "no longer listed"

  /// "hidden by the org filter", "hidden by the group filter", or "hidden by the filters".
  nonisolated static func hiddenReason(_ scope: SessionFilter.Scope) -> String { "hidden by \(scope.filterName)" }

  /// Why `filter` shows `s` but Delete All may not remove it: sbd hasn't read its org, or hasn't listed the groups.
  nonisolated static func unreadReason(_ s: SessionSummary, _ filter: SessionFilter) -> String {
    !filter.org.isAll && OrgFilter.key(of: s) == nil ? unreadOrgReason : unlistedGroupsReason
  }

  /// Why `filter` hides `s`, naming the filter that hides it.
  nonisolated static func hiddenReason(_ s: SessionSummary, _ filter: SessionFilter) -> String {
    let org = !filter.org.shows(s)
    let group = !filter.groupShows(s)
    return hiddenReason(org && group ? .both : group ? .groups : .orgs)
  }

  /// Why the removal sheet may not remove a session now, or nil when it may, as of this call. It reads the
  /// lists once, so a check of many sessions does not rebuild them for each one.
  func removalRefusals() -> (String) -> String? {
    let removable = removableIDs
    let shown = shownIDs
    let listed = Dictionary(listedBoard.map { ($0.id, $0) }) { first, _ in first }
    let filter = filter
    return { id in
      if removable.contains(id) { return nil }
      guard let s = listed[id] else { return Self.unlistedReason }
      return shown.contains(id) ? Self.unreadReason(s, filter) : Self.hiddenReason(s, filter)
    }
  }

  /// Asks sbd which Done sessions it would remove and which it would skip.
  func checkDoneRemoval() { checkRemoval(nil, scope: .done) }

  /// Asks sbd which sessions of the multi-selection it would remove, in any state, and which it would skip.
  func checkSelectionRemoval() { checkRemoval(multiSelected.map(\.id), scope: .work) }

  /// Asks sbd for an `rm-plan` of `ids`, or of every Done session when `ids` is nil, then shows it in the removal
  /// sheet. The plan leaves out the sessions that the filter hides. Under a filter, a shown session whose org sbd
  /// hasn't read yet, or any shown session under a group filter before sbd lists the groups, moves from the remove
  /// list to the skip list.
  private func checkRemoval(_ ids: [String]?, scope: RemovalScope) {
    guard !showingDoneRemoval else { return }
    let checking = DoneRemoval.checking(scope, request: UUID())
    doneRemoval = checking
    perform(
      "rm-plan", Self.planRequest(ids, scope: scope),
      then: { value in
        guard self.doneRemoval == checking else { return }
        do {
          var plan = try JSONCoding.convert(value, to: RemovalPlan.self)
          let shown = self.shownIDs
          let removable = self.removableIDs
          let refusal = self.removalRefusals()
          let unread = plan.remove.compactMap { item in
            shown.contains(item.id) ? refusal(item.id).map { (item, $0) } : nil
          }
          plan.remove.removeAll { !removable.contains($0.id) }
          plan.skip.removeAll { !shown.contains($0.id) }
          plan.skip += unread.map { item, reason in .init(id: item.id, name: item.name, reason: reason) }
          self.doneRemoval = .confirming(plan, scope: scope)
        } catch {
          self.actionError = "rm-plan: \(error)"
        }
      },
      finally: { if self.doneRemoval == checking { self.doneRemoval = nil } })
  }

  /// Closes the sheet and hands the plan's sessions to sbd's removal job in one `rm-queue`, off `worker`,
  /// so the request never waits behind a slow action. The app leaves out a session that `removalRefusals`
  /// refuses at that moment, because a filter change after the plan can hide it.
  func removeDone(_ plan: RemovalPlan) {
    guard case .confirming(_, let scope) = doneRemoval else { return }
    doneRemoval = nil
    var targets: [String] = []
    var refused: [RemovalPlan.Skip] = []
    let refusal = removalRefusals()
    for item in plan.remove {
      if let reason = refusal(item.id) {
        refused.append(.init(id: item.id, name: item.name, reason: reason))
      } else {
        targets.append(item.id)
      }
    }
    queueRemovals(targets, scope: scope, refused: refused, on: .global(qos: .userInitiated))
  }

  /// Sends one `rm-queue` for `ids`. The banner names each session in `refused` and each session that sbd
  /// skipped. sbd lists a queued session as held, so the refresh after the reply hides it.
  func queueRemovals(
    _ ids: [String], scope: RemovalScope, resolve: [String] = [], refused: [RemovalPlan.Skip] = [],
    on queue: DispatchQueue? = nil, finally: (() -> Void)? = nil
  ) {
    perform(
      "rm-queue", Self.queueRequest(ids, scope: scope, resolve: resolve), on: queue,
      then: { value in
        let skipped = (try? JSONCoding.convert(value, to: RemovalQueued.self))?.skipped ?? []
        self.actionError = DoneRemovalText.skipped(refused + skipped)
      },
      finally: finally)
  }
}

/// Opens the Delete All sheet. It is off while no session can be deleted from
/// Done, and while a Delete All is open.
struct DeleteAllDoneButton: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    Button {
      model.checkDoneRemoval()
    } label: {
      Label("Delete All…", systemImage: "trash")
    }
    .buttonStyle(.borderless)
    .font(.caption)
    .disabled(!model.board.contains(where: \.isRemovableDone) || model.showingDoneRemoval)
    .help("Delete every Done session, with its worktree, and its branch when the PR merged…")
    .accessibilityIdentifier("delete-all-done")
  }
}

struct DoneRemovalSheet: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let confirmation = model.doneRemoval {
        confirmationView(confirmation)
      }
    }
    .padding()
    .frame(width: 520)
  }

  @ViewBuilder private func confirmationView(_ confirmation: DoneRemoval) -> some View {
    switch confirmation {
    case .checking(let scope, _):
      ProgressView(DoneRemovalText.checking(scope))
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.doneRemoval = nil }.keyboardShortcut(.cancelAction)
      }
    case .confirming(let plan, let scope):
      Text(DoneRemovalText.title(plan, scope: scope)).font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(plan.remove, id: \.id) { item in
            VStack(alignment: .leading, spacing: 2) {
              Text(item.name + (item.pr.map { "  #\($0)" } ?? "")).fontWeight(.medium)
              Text("Deletes the \(DoneRemovalText.deletes(item))").font(.caption).foregroundStyle(.secondary)
              if let working = DoneRemovalText.working(model.summary(item.id)) {
                Text(working).font(.caption).foregroundStyle(.orange)
              }
              if let worktree = item.worktree {
                Text(worktree).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
              }
            }
          }
          SkipList(title: DoneRemovalText.stays(scope), skips: plan.skip)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 360)
      Text(
        "Each session's claude stops and its terminals close. The conversation transcripts stay. sbd checks each session again before it deletes it."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.doneRemoval = nil }.keyboardShortcut(.cancelAction)
        Button("Delete \(plan.remove.count)", role: .destructive) { model.removeDone(plan) }
          .disabled(plan.remove.isEmpty)
      }
    }
  }
}

private struct SkipList: View {
  let title: String
  let skips: [RemovalPlan.Skip]

  var body: some View {
    if !skips.isEmpty {
      Text(title).font(.subheadline.bold()).padding(.top, 4)
      ForEach(skips, id: \.id) { skip in
        VStack(alignment: .leading, spacing: 2) {
          Text(skip.name).fontWeight(.medium)
          InlineText(plain: skip.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
    }
  }
}
