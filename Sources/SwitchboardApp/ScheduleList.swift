import SwiftUI
import SwitchboardCore

/// The strings of one schedule's row. They match what `sb schedule ls` prints.
struct ScheduleCaption {
  let prompt: String
  /// Computed from the session facts that sbd's tick reads, so the row says held exactly when the tick holds the
  /// session.
  let status: ScheduleStatus
  /// Such as `every 30m · next in 12m`, `every 30m · paused`, or `every 30m · held: the session is marked done`.
  let timing: String
  /// Such as `last: pasted 5m ago · 2 skipped`, `last: failed 2m ago: <error>`, or `never ran`.
  let result: String
  let toggleTitle: String
  /// Why Run Now can't run the schedule, in the order that sbd's `run-schedule` refuses, or nil when it can. A held
  /// session refuses even a schedule that isn't due, whose status is `active`.
  let runNowBlocker: String?
  let deleteQuestion: String

  init(_ schedule: Schedule, session: SessionSummary, now: Int64) {
    let hold = session.scheduleHold
    prompt = schedule.prompt
    status = ScheduleStatus(schedule, hold: hold, now: now)
    timing = schedule.timingText(status.text)
    result = schedule.lastText(now: now)
    toggleTitle = schedule.paused == true ? "Resume" : "Pause"
    if schedule.paused == true {
      runNowBlocker = "The loop is paused. Resume it first."
    } else {
      runNowBlocker = hold.map { "The loop can't run, because \($0)." }
    }
    deleteQuestion = "Delete this loop? \(schedule.prompt.prefix { !$0.isNewline })"
  }

  var needsAttention: Bool { status.needsAttention }
}

/// A session's schedules, each with its status and actions.
struct ScheduleList: View {
  let session: SessionSummary

  var body: some View {
    TimelineView(.everyMinute) { _ in
      let now = nowMs()
      VStack(alignment: .leading, spacing: 10) {
        ForEach(session.schedules ?? [], id: \.id) {
          ScheduleItem(schedule: $0, caption: ScheduleCaption($0, session: session, now: now))
        }
      }
    }
  }
}

/// One schedule's row: its prompt, timing, and last run, with its actions.
struct ScheduleItem: View {
  let schedule: Schedule
  let caption: ScheduleCaption

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(caption.prompt).lineLimit(3).help(caption.prompt).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      ScheduleTiming(caption: caption)
      Text(caption.result).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      ScheduleActions(schedule: schedule, caption: caption).padding(.top, 2)
    }
  }
}

/// The interval and the status, in the attention color when the loop needs attention.
struct ScheduleTiming: View {
  let caption: ScheduleCaption

  var body: some View {
    Text(caption.timing)
      .font(.caption)
      .foregroundStyle(caption.needsAttention ? AttentionState.needsYou.color : .secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Pause or Resume, Run Now, Edit…, and Delete…, which asks first because the prompt is lost.
struct ScheduleActions: View {
  @EnvironmentObject var model: BoardModel
  let schedule: Schedule
  let caption: ScheduleCaption
  @State private var confirmingDelete = false

  var body: some View {
    HStack(spacing: 8) {
      Button(caption.toggleTitle) { model.pauseSchedule(schedule.id, paused: schedule.paused != true) }
        .help(
          schedule.paused == true
            ? "Start the loop again. Its next run comes one interval from now."
            : "Stop the loop until you resume it."
        )
        .accessibilityLabel("\(caption.toggleTitle) loop: \(caption.prompt)")
      Button("Run Now") { model.runSchedule(schedule.id) }
        .disabled(caption.runNowBlocker != nil)
        .help(caption.runNowBlocker ?? "Run the loop now, or once its session is free.")
        .accessibilityLabel("Run loop now: \(caption.prompt)")
        .accessibilityHint(caption.runNowBlocker ?? "")
      Button("Edit…") { model.loopEditor = .edit(schedule.id) }
        .help("Change the loop's interval or prompt")
        .accessibilityLabel("Edit loop: \(caption.prompt)")
      Button("Delete…") { confirmingDelete = true }
        .help("Delete the loop. It does not run again.")
        .accessibilityLabel("Delete loop: \(caption.prompt)")
    }
    .controlSize(.small)
    .confirmationDialog(caption.deleteQuestion, isPresented: $confirmingDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive) { model.removeSchedule(schedule.id) }
    } message: {
      Text("Its prompt is lost.")
    }
  }
}

/// A chat pane's line such as `2 schedules · next in 12m`, which opens the session's schedules in a popover. It
/// draws nothing when the session has no schedule.
struct SchedulesStrip: View {
  let session: SessionSummary
  @State private var showing = false

  /// The strip's text, or nil when there is no schedule. A paused schedule counts, but its `next` does not.
  static func text(_ schedules: [Schedule]?, now: Int64) -> String? {
    guard let schedules, !schedules.isEmpty else { return nil }
    let count = schedules.count == 1 ? "1 schedule" : "\(schedules.count) schedules"
    guard let soonest = schedules.filter({ $0.paused != true }).min(by: { $0.next < $1.next }) else {
      return "\(count) · paused"
    }
    return "\(count) · \(soonest.isDue(now: now) ? "due" : soonest.nextText(now: now))"
  }

  var body: some View {
    TimelineView(.everyMinute) { _ in
      if let text = Self.text(session.schedules, now: nowMs()) {
        HStack {
          Button {
            showing = true
          } label: {
            Label(text, systemImage: "clock.arrow.circlepath")
          }
          .help("Show this conversation's schedules")
          .accessibilityLabel("Schedules: \(text)")
          .popover(isPresented: $showing, arrowEdge: .bottom) {
            ScheduleList(session: session).padding(12).frame(width: 340)
          }
          // Without the reset, the popover would open by itself when the next schedule arrives.
          .onDisappear { showing = false }
          Spacer()
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
      }
    }
  }
}
