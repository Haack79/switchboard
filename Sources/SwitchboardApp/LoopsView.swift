import SwiftUI
import SwitchboardCore

/// Every shown session's loops, with the current loop's prompt, status, and history on the right.
struct LoopsView: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    // A loop turns overdue with the time alone, while sbd's `ls` answer stays the same.
    TimelineView(.everyMinute) { _ in
      let now = nowMs()
      let rows = model.loopRows(now: now)
      if rows.isEmpty {
        ContentUnavailableView {
          Label("No loops", systemImage: MainView.loops.symbol)
        } description: {
          Text("A loop sends a prompt to a session on an interval. New Loop… or `sb schedule` adds one.")
        } actions: {
          NewLoopButton()
        }
      } else {
        ListDetailSplit {
          VStack(spacing: 0) {
            LoopListHeader()
            Divider()
            LoopRows(rows: rows, now: now)
          }
        } detail: {
          if let row = model.currentLoop(in: rows) {
            LoopDetail(row: row, now: now).id(row.id)
          }
        }
      }
    }
  }
}

/// Opens the loop editor for a new loop.
private struct NewLoopButton: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    Button("New Loop…") { model.loopEditor = .new }
      .help("Add a loop that sends a prompt to a session on an interval")
  }
}

/// The session filter, the sort menu, and New Loop….
private struct LoopListHeader: View {
  @EnvironmentObject var model: BoardModel

  var body: some View {
    HStack(spacing: 6) {
      Picker("Session", selection: Binding(get: { model.loopSessionChoice }, set: { model.loopSessionFilter = $0 })) {
        Text("All Sessions").tag(String?.none)
        Divider()
        ForEach(model.loopSessions) { Text($0.nameWithHost).tag(Optional($0.id)) }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .help("Show the loops of one session, or of every session")
      Menu {
        Picker("Sort", selection: $model.loopSort) {
          ForEach(LoopSort.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
      } label: {
        Image(systemName: "arrow.up.arrow.down")
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Sort the loops by status or by session. The loops that need attention stay on top")
      .accessibilityLabel("Sort")
      Spacer(minLength: 0)
      NewLoopButton().fixedSize()
    }
    .padding(8)
  }
}

/// The loops, one row each. j and k move around the ends, ↓ and ↑ stop at them, and Return opens the loop's
/// session.
private struct LoopRows: View {
  @EnvironmentObject var model: BoardModel
  @FocusState private var focused: Bool
  let rows: [LoopRow]
  let now: Int64

  var body: some View {
    let current = model.currentLoop(in: rows)?.id
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(rows) { row in
            LoopListRow(row: row, now: now, current: row.id == current).id(row.id)
              .simultaneousGesture(TapGesture().onEnded { focused = true })
          }
        }
        .padding(.vertical, 6)
      }
      .listKeys(.loops, $focused, model: model) {
        model.moveLoop(by: $0, wrap: $1)
      } open: {
        if let row = model.currentLoop { model.showInSidebar(row.session) }
      }
      .onChange(of: model.loopJumps) {
        if let id = model.currentLoop?.id { withAnimation { proxy.scrollTo(id) } }
      }
    }
  }
}

private struct LoopListRow: View {
  @EnvironmentObject var model: BoardModel
  let row: LoopRow
  let now: Int64
  let current: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      LoopSessionLink(row: row)
      ScheduleItem(schedule: row.schedule, caption: ScheduleCaption(row.schedule, session: row.session, now: now))
    }
    .listRowChrome(current: current)
    .onTapGesture { model.loopFocus = row.id }
    .accessibilityAddTraits(current ? .isSelected : [])
  }
}

/// The loop's session name, and its host when it has one, as a link that selects the session.
private struct LoopSessionLink: View {
  @EnvironmentObject var model: BoardModel
  let row: LoopRow

  var body: some View {
    Button(row.session.nameWithHost) { model.showInSidebar(row.session) }
      .buttonStyle(.link)
      .font(.caption)
      .lineLimit(1)
      .help("Open \(row.session.name)")
      .accessibilityLabel("Open session \(row.session.nameWithHost) of loop: \(row.schedule.prompt)")
  }
}

/// The current loop: its session, status, actions, whole prompt, and recent runs, newest first.
private struct LoopDetail: View {
  let row: LoopRow
  let now: Int64

  var body: some View {
    let caption = ScheduleCaption(row.schedule, session: row.session, now: now)
    let history = row.schedule.history
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        LoopSessionLink(row: row)
        ScheduleTiming(caption: caption)
        ScheduleActions(schedule: row.schedule, caption: caption)
      }
      .padding(12)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(row.schedule.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .leading, spacing: 4) {
            ListSectionHeader(title: "Recent Runs", count: history.count, inset: false)
            if history.isEmpty {
              Text("never ran").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(history.enumerated()), id: \.offset) { _, run in
              Text(run.text(now: now)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
        }
        .padding(12)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
