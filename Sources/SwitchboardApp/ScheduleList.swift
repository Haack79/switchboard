import SwiftUI
import SwitchboardCore

/// The strings of one schedule's row. They match what `sb schedule ls` prints.
struct ScheduleCaption {
  let prompt: String
  /// Such as `every 30m · next in 12m`, `every 30m · paused`, or `every 30m · due, runs when the session is free`.
  let timing: String
  /// Such as `last: pasted 5m ago · 2 skipped`, `last: failed 2m ago: <error>`, or `never ran`.
  let result: String
  let toggleTitle: String

  init(_ schedule: Schedule, now: Int64) {
    prompt = schedule.prompt
    timing = schedule.timingText(now: now)
    result = schedule.lastText(now: now)
    toggleTitle = schedule.paused == true ? "Resume" : "Pause"
  }
}

/// A session's schedules, each with Pause or Resume and Remove.
struct ScheduleList: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    TimelineView(.everyMinute) { _ in
      let now = nowMs()
      VStack(alignment: .leading, spacing: 10) {
        ForEach(session.schedules ?? [], id: \.id) { row($0, ScheduleCaption($0, now: now)) }
      }
    }
  }

  private func row(_ schedule: Schedule, _ caption: ScheduleCaption) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(caption.prompt).lineLimit(3).help(caption.prompt).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Text(caption.timing).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Text(caption.result).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Button(caption.toggleTitle) { model.pauseSchedule(schedule.id, paused: schedule.paused != true) }
          .help(
            schedule.paused == true
              ? "Start the schedule again. Its next run comes one interval from now."
              : "Stop the schedule until you resume it."
          )
          .accessibilityLabel("\(caption.toggleTitle) schedule: \(caption.prompt)")
        Button("Remove") { model.removeSchedule(schedule.id) }
          .help("Delete the schedule. It does not run again.")
          .accessibilityLabel("Remove schedule: \(caption.prompt)")
      }
      .controlSize(.small)
      .padding(.top, 2)
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
