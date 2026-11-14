import SwiftUI
import SwitchboardCore

/// The Delete All sheet's confirmation: sbd checks every Done session, and
/// the user confirms the plan.
enum DoneRemoval: Equatable {
  case checking
  case confirming(RemovalPlan)
}

enum DoneRemovalText {
  static func title(_ plan: RemovalPlan) -> String {
    switch plan.remove.count {
    case 0: "No Done session can be deleted"
    case 1: "Delete 1 Done session?"
    case let n: "Delete \(n) Done sessions?"
    }
  }

  static func removing(_ count: Int) -> String { count == 1 ? "Removing 1 session…" : "Removing \(count) sessions…" }

  static func notices(_ count: Int) -> String { count == 1 ? "1 delete notice" : "\(count) delete notices" }

  /// The banner's text for the sessions that a delete left in place, or nil when it left none.
  static func skipped(_ skips: [RemovalPlan.Skip]) -> String? {
    skips.isEmpty ? nil : "Not deleted: " + skips.map { "\($0.name): \($0.reason)" }.joined(separator: "; ")
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

  /// The `rm-queue` that hands the Done sessions `ids` to sbd's removal job. `resolve` holds the ids of the
  /// open to-dos that the confirmation showed.
  nonisolated static func queueRequest(_ ids: [String], resolve: [String] = []) -> [String: JSON] {
    var args = doneRemovalArgs
    args["scope"] = .string(RemovalScope.done.rawValue)
    args["targets"] = .array(ids.map(JSON.string))
    return resolving(args, resolve)
  }

  nonisolated static let unreadOrgReason = "sbd hasn't read its org yet"
  nonisolated static let hiddenOrgReason = "hidden by the org filter"
  nonisolated static let unlistedReason = "no longer listed"

  /// Why Delete All may not remove the session now, or nil when it may.
  func removalRefusal(_ id: String) -> String? {
    if removableIDs.contains(id) { return nil }
    if shownIDs.contains(id) { return Self.unreadOrgReason }
    return listedBoard.contains { $0.id == id } ? Self.hiddenOrgReason : Self.unlistedReason
  }

  /// Asks sbd which Done sessions it would remove and which it would skip.
  /// The plan leaves out the sessions that the org filter hides. Under a
  /// filter, a shown session whose org sbd hasn't read yet moves from the
  /// remove list to the skip list.
  func checkDoneRemoval() {
    guard !showingDoneRemoval else { return }
    doneRemoval = .checking
    perform(
      "rm-done", Self.doneRemovalArgs,
      then: { value in
        guard self.doneRemoval == .checking else { return }
        do {
          var plan = try JSONCoding.convert(value, to: RemovalPlan.self)
          let shown = self.shownIDs
          let removable = self.removableIDs
          let unreadIDs = shown.subtracting(removable)
          let unread = plan.remove.filter { unreadIDs.contains($0.id) }
          plan.remove.removeAll { !removable.contains($0.id) }
          plan.skip.removeAll { !shown.contains($0.id) }
          plan.skip += unread.map { .init(id: $0.id, name: $0.name, reason: Self.unreadOrgReason) }
          self.doneRemoval = .confirming(plan)
        } catch {
          self.actionError = "rm-done: \(error)"
        }
      },
      finally: { if self.doneRemoval == .checking { self.doneRemoval = nil } })
  }

  /// Closes the sheet and hands the plan's sessions to sbd's removal job in one `rm-queue`, off `worker`,
  /// so the request never waits behind a slow action. The app leaves out a session that `removalRefusal`
  /// refuses at that moment, because a filter change after the plan can hide it.
  func removeDone(_ plan: RemovalPlan) {
    guard case .confirming = doneRemoval else { return }
    doneRemoval = nil
    var targets: [String] = []
    var refused: [RemovalPlan.Skip] = []
    for item in plan.remove {
      if let reason = removalRefusal(item.id) {
        refused.append(.init(id: item.id, name: item.name, reason: reason))
      } else {
        targets.append(item.id)
      }
    }
    queueRemovals(targets, refused: refused, on: .global(qos: .userInitiated))
  }

  /// Sends one `rm-queue` for `ids`. The banner names each session in `refused` and each session that sbd
  /// skipped. sbd lists a queued session as held, so the refresh after the reply hides it.
  func queueRemovals(
    _ ids: [String], resolve: [String] = [], refused: [RemovalPlan.Skip] = [], on queue: DispatchQueue? = nil,
    finally: (() -> Void)? = nil
  ) {
    perform(
      "rm-queue", Self.queueRequest(ids, resolve: resolve), on: queue,
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
    case .checking:
      ProgressView("Checking the Done sessions…")
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.doneRemoval = nil }.keyboardShortcut(.cancelAction)
      }
    case .confirming(let plan):
      Text(DoneRemovalText.title(plan)).font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(plan.remove, id: \.id) { item in
            VStack(alignment: .leading, spacing: 2) {
              Text(item.name + (item.pr.map { "  #\($0)" } ?? "")).fontWeight(.medium)
              Text("Deletes the \(DoneRemovalText.deletes(item))").font(.caption).foregroundStyle(.secondary)
              if let worktree = item.worktree {
                Text(worktree).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
              }
            }
          }
          SkipList(title: "Stays in Done", skips: plan.skip)
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
          Text(skip.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
    }
  }
}
