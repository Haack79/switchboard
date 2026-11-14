import SwiftUI
import SwitchboardCore

/// What the sidebar's removal row shows: the sessions that sbd's removal job holds, and the branches it
/// kept after it forgot their sessions.
struct RemovalStatus: Equatable {
  var sessions: [SessionSummary]
  var notices: [RemovalNotice]
  var count: Int { sessions.count }
  var warning: Bool { !notices.isEmpty }

  var title: String { count > 0 ? DoneRemovalText.removing(count) : DoneRemovalText.notices(notices.count) }

  /// The sessions that Undo can bring back at `now`, in ms since the epoch: those the job has not started and
  /// will not start before their `notBefore`.
  func undoable(now: Int64) -> [String] { sessions.filter { $0.removal?.startsAfter(now) == true }.map(\.id) }

  /// The times at which a session stops being undoable, so the row can drop Undo then.
  func undoDeadlines(now: Int64) -> [Date] {
    sessions.compactMap(\.removal).filter { $0.startsAfter(now) }.map(\.notBefore).sorted()
      .map { Date(timeIntervalSince1970: Double($0) / 1000) }
  }
}

extension BoardModel {
  /// The removal row's content, or nil while the job holds no session and no notice waits. The job runs for
  /// every org, so the row counts the sessions that the org filter hides too.
  var removalStatus: RemovalStatus? {
    let held = allSessions.filter(\.isBeingRemoved)
    guard !held.isEmpty || !removalNotices.isEmpty else { return nil }
    return RemovalStatus(sessions: held, notices: removalNotices)
  }

  /// Asks sbd to cancel, in one `rm-cancel`, every removal that is undoable at `now`. sbd refuses a session that
  /// started since, and the banner names it with the reason. The refresh after the reply lists the others again.
  func undoRemovals(now: Int64) {
    let ids = (removalStatus?.undoable(now: now) ?? []).filter { answeringRemovals.insert($0).inserted }
    guard !ids.isEmpty else { return }
    perform(
      "rm-cancel", ["sessions": .array(ids.map(JSON.string))], on: undos,
      then: { value in
        let refused = (try? JSONCoding.convert(value, to: RemovalCancelled.self))?.refused ?? []
        self.actionError = DoneRemovalText.skipped(refused, "Not undone")
      },
      finally: { self.answeringRemovals.subtract(ids) })
  }

  func retryRemoval(_ id: String) { answerRemoval(id, "rm-retry") }

  /// sbd clears the failed removal, and the session goes back to Done.
  func keepRemoval(_ id: String) { answerRemoval(id, "rm-keep") }

  private func answerRemoval(_ id: String, _ op: String) {
    answer(id, in: \.answeringRemovals, op, ["session": .string(id)]) { _ in }
  }

  /// sbd reads the notice's id as a number.
  func dismissRemovalNotice(_ id: Int64) { perform("removal-notice-dismiss", ["id": .number(Double(id))]) }
}

/// The row at the bottom of the sidebar that shows the removal job. Its popover lists the held sessions and
/// the notices.
struct RemovalStatusView: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    if let status = model.removalStatus {
      // The schedule starts at `now`, so the first render reads it as its date.
      let now = Date()
      TimelineView(.explicit([now] + status.undoDeadlines(now: now.ms))) { context in
        RemovalStatusButton(status: status, undoable: !status.undoable(now: context.date.ms).isEmpty)
      }
    }
  }
}

/// The row's popover state lives here, so it resets when the row goes away.
private struct RemovalStatusButton: View {
  @EnvironmentObject var model: BoardModel
  let status: RemovalStatus
  let undoable: Bool
  @State private var showing = false

  var body: some View {
    HStack(spacing: 6) {
      Button {
        showing = true
      } label: {
        HStack(spacing: 6) {
          if status.count > 0 { ProgressView().controlSize(.small) }
          Text(status.title)
          Spacer(minLength: 4)
          if status.warning {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
              .accessibilityLabel("A delete left something behind")
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Show the sessions that sbd is deleting, and what a delete left behind")
      .accessibilityIdentifier("sidebar-removal-status")
      .popover(isPresented: $showing, arrowEdge: .top) { RemovalStatusPopover(status: status) }
      if undoable {
        Button("Undo") { model.undoRemovals(now: nowMs()) }
          .buttonStyle(.borderless)
          .help("Bring back the sessions whose delete hasn't started")
          .accessibilityIdentifier("sidebar-removal-undo")
      }
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
  }
}

private struct RemovalStatusPopover: View {
  @EnvironmentObject var model: BoardModel
  let status: RemovalStatus

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        if !status.sessions.isEmpty {
          Text(status.title).font(.subheadline.bold())
          ForEach(status.sessions) { s in
            HStack {
              Text(s.name).fontWeight(.medium)
              Spacer()
              Text(s.removal?.state == .running ? "Deleting…" : "Waiting").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        if !status.notices.isEmpty {
          Text("Left behind").font(.subheadline.bold()).padding(.top, status.sessions.isEmpty ? 0 : 4)
          ForEach(status.notices, id: \.id) { notice in
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 2) {
                Text(notice.name).fontWeight(.medium)
                Text(notice.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
              }
              Spacer()
              Button("Dismiss") { model.dismissRemovalNotice(notice.id) }
            }
          }
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 340)
    .frame(maxHeight: 400)
  }
}

/// Retry and Keep for a session whose removal failed. The Inbox shows the failure as the session's reason.
struct FailedRemovalActions: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      Text(session.reason).textSelection(.enabled)
      Spacer()
      Button("Keep") { model.keepRemoval(session.id) }
        .help("Keep the session in Done")
      Button("Retry") { model.retryRemoval(session.id) }
        .help("Ask sbd to delete the session again")
    }
    .disabled(model.answeringRemovals.contains(session.id))
  }
}

extension Date {
  /// The date in ms since the epoch. It rounds, so a date made from a `notBefore` reads back as that `notBefore`.
  fileprivate var ms: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
