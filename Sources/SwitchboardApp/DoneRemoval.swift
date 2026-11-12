import SwiftUI
import SwitchboardCore

/// The Delete All sheet's confirmation: sbd checks every Done session, and
/// the user confirms the plan.
enum DoneRemoval: Equatable {
  case checking
  case confirming(RemovalPlan)
}

/// The Delete All sheet's progress: the app removes the sessions one at a
/// time, and the sheet shows what happened.
enum DoneRemovalProgress: Equatable {
  case removing(RemovalPlan, done: Int)
  case finished(RemovalResult)
}

/// The request that removes one Done session.
enum DoneRemovalRequest {
  /// The Done delete icon's `rm`. Its arguments come from `deleteRequest`
  /// and name one session's own branch.
  case rm
  /// Delete All's confirmed `rm-done`. sbd checks again that the session is
  /// still a removable Done session.
  case rmDone

  /// An `rm` that succeeds reports the session as removed.
  func send(_ id: String, _ args: [String: JSON], _ send: (String, [String: JSON]) throws -> JSON) throws
    -> RemovalResult
  {
    var args = args
    switch self {
    case .rm:
      args["session"] = .string(id)
      _ = try send("rm", args)
      return RemovalResult(removed: [id], skipped: [], partial: [])
    case .rmDone:
      args["confirmed"] = true
      args["targets"] = [.string(id)]
      return try JSONCoding.convert(try send("rm-done", args), to: RemovalResult.self)
    }
  }
}

enum DoneRemovalText {
  static func title(_ plan: RemovalPlan) -> String {
    switch plan.remove.count {
    case 0: "No Done session can be deleted"
    case 1: "Delete 1 Done session?"
    case let n: "Delete \(n) Done sessions?"
    }
  }

  static func progress(done: Int, total: Int) -> String { "Removing \(min(done + 1, total)) of \(total)…" }

  static func summary(removed: Int, skipped: Int) -> String {
    skipped == 0 ? "Removed \(removed)" : "Removed \(removed), skipped \(skipped)"
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
  /// The arguments of the Done delete icon's `rm`: the worktree, and the
  /// branch and the remote branch when the PR merged.
  nonisolated static let doneRemovalArgs: [String: JSON] = ["worktree": true, "remote_branch": true]

  nonisolated static let unreadOrgReason = "sbd hasn't read its org yet"
  nonisolated static let hiddenOrgReason = "hidden by the org filter"
  nonisolated static let unlistedReason = "no longer listed"
  nonisolated static let rmTakesOneReason = "rm takes one session"

  /// Why Delete All may not remove the session now, or nil when it may.
  func removalRefusal(_ id: String) -> String? {
    if removableIDs.contains(id) { return nil }
    if shownIDs.contains(id) { return Self.unreadOrgReason }
    return allBoard.contains { $0.id == id } ? Self.hiddenOrgReason : Self.unlistedReason
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

  /// Removes the plan's sessions one request at a time, so the sheet can show
  /// progress. sbd checks each session again. A session that fails its
  /// checks, or left Done, is skipped, and the rest continue.
  func removeDone(_ plan: RemovalPlan) {
    guard case .confirming = doneRemoval else { return }
    doneRemovalProgress = .removing(plan, done: 0)
    doneRemoval = nil
    removeSessions(
      plan.remove, args: Self.doneRemovalArgs, request: .rmDone,
      progress: { self.doneRemovalProgress = .removing(plan, done: $0) },
      finished: { removed in
        var result = RemovalResult(removed: [], skipped: plan.skip, partial: [])
        result.add(removed)
        self.doneRemovalProgress = .finished(result)
      })
  }

  /// Removes `sessions` one request at a time, in order. `args` are the `rm`
  /// arguments that every request takes. A request that fails skips its
  /// session, and the rest continue. After the last reply, `finished` gets
  /// what sbd removed, kept, and skipped. Then the removed sessions lose the
  /// selection, and the board refreshes.
  ///
  /// `.rm` takes one session and refuses a longer list, because its
  /// arguments name one session's branch. It runs on `worker`, after the
  /// requests queued before it.
  /// `.rmDone` requests run off `worker`, so a long Delete All doesn't hold
  /// up other requests. Before each `.rmDone` request, the app skips a
  /// session that `removalRefusal` refuses at that moment, because a filter
  /// change after the plan can hide it. `progress` gets the number of
  /// sessions handled so far.
  func removeSessions(
    _ sessions: [RemovalPlan.Item], args: [String: JSON], request: DoneRemovalRequest,
    progress: (@MainActor @Sendable (Int) -> Void)? = nil,
    finished: @escaping @MainActor @Sendable (RemovalResult) -> Void
  ) {
    let send = send
    let queue = request == .rm ? worker : DispatchQueue.global(qos: .userInitiated)
    queue.async {
      var result = RemovalResult(removed: [], skipped: [], partial: [])
      for (n, item) in sessions.enumerated() {
        let refusal: String? =
          switch request {
          case .rm: sessions.count > 1 ? Self.rmTakesOneReason : nil
          case .rmDone: DispatchQueue.main.sync { MainActor.assumeIsolated { self.removalRefusal(item.id) } }
          }
        if let refusal {
          result.skipped.append(.init(id: item.id, name: item.name, reason: refusal))
        } else {
          do {
            result.add(try request.send(item.id, args, send))
          } catch {
            result.skipped.append(.init(id: item.id, name: item.name, reason: "\(error)"))
          }
        }
        if let progress { DispatchQueue.main.async { MainActor.assumeIsolated { progress(n + 1) } } }
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { [result] in
          finished(result)
          self.deselect(result.removed)
          self.refresh(followups: true)
        }
      }
    }
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
      if let progress = model.doneRemovalProgress {
        progressView(progress)
      } else if let confirmation = model.doneRemoval {
        confirmationView(confirmation)
      }
    }
    .padding()
    .frame(width: 520)
    .interactiveDismissDisabled(isRemoving)
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

  @ViewBuilder private func progressView(_ progress: DoneRemovalProgress) -> some View {
    switch progress {
    case .removing(let plan, let done):
      ProgressView(value: Double(done), total: Double(max(plan.remove.count, 1))) {
        Text(DoneRemovalText.progress(done: done, total: plan.remove.count))
      }
    case .finished(let result):
      Text(DoneRemovalText.summary(removed: result.removed.count, skipped: result.skipped.count)).font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          SkipList(title: "Removed, with something kept", skips: result.partial)
          SkipList(title: "Skipped", skips: result.skipped)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 360)
      HStack {
        Spacer()
        Button("Done") { model.doneRemovalProgress = nil }.keyboardShortcut(.defaultAction)
      }
    }
  }

  private var isRemoving: Bool {
    if case .removing = model.doneRemovalProgress { return true }
    return false
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
