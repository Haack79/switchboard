import SwiftUI
import SwitchboardCore

extension SessionSummary {
  /// True when Pause can act on the session. A session whose worktree cleanup removed is left out, because sbd
  /// can't resume a session without its folder.
  var canPause: Bool { pause == nil && hasTerminals }
}

/// Which of a group lane's Pause All and Resume All buttons show. They follow sbd's group fan-out over the
/// group's work sessions.
enum GroupPause {
  /// `pause` is true when a member has started, isn't marked done, and isn't paused. A member in Done only because
  /// its PR merged still counts. `resume` is true when a member is paused, including one marked done.
  static func actions(_ members: [SessionSummary]) -> (pause: Bool, resume: Bool) {
    let work = members.filter { $0.kind == .work }
    return (
      work.contains { $0.runsClaude && !$0.markedDone && $0.pause == nil },
      work.contains { $0.pause != nil }
    )
  }
}

/// "Paused" in a capsule, with who paused the session and why as its help.
struct PausedBadge: View {
  let pause: Pause

  var body: some View {
    Text("Paused")
      .font(.caption2.bold())
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(Capsule().fill(Color.secondary.opacity(0.15)))
      .foregroundStyle(.secondary)
      .help(pause.line)
      .accessibilityLabel(pause.line)
  }
}

/// A paused session's line: who paused it and why, the messages it holds, and Resume.
struct PauseBanner: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    if let pause = session.pause {
      HStack(spacing: 8) {
        Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(pause.line).lineLimit(2).textSelection(.enabled)
          if let held = session.heldMessages, held > 0 {
            Text(held == 1 ? "1 message waits for the resume" : "\(held) messages wait for the resume")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button("Resume") { model.resume(session.id) }
          .accessibilityLabel("Resume \(session.name)")
          .help(PauseBanner.resumeHelp)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(Color.secondary.opacity(0.08))
    }
  }

  static let resumeHelp =
    "Start claude again. It gets the resume message first, then each message that waited while it was paused."
  static let pauseHelp =
    "Stop claude and hold every message until you resume it. Nothing starts it again until then."
}

/// Pause or Resume in a session's context menu.
struct PauseMenuItem: View {
  let model: BoardModel
  let session: SessionSummary

  var body: some View {
    if session.pause != nil {
      Button("Resume") { model.resume(session.id) }.help(PauseBanner.resumeHelp)
    } else if session.canPause {
      Button("Pause") { model.pause(session.id) }.help(PauseBanner.pauseHelp)
    }
  }
}

/// A Board card's Resume button for a paused session.
struct ResumeButton: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    Button {
      model.resume(session.id)
    } label: {
      Image(systemName: "play.circle")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .accessibilityLabel("Resume \(session.name)")
    .help(PauseBanner.resumeHelp)
  }
}

/// A group lane's Pause All and Resume All, each shown when sbd's group pause or resume would act on a member.
struct GroupPauseButtons: View {
  @EnvironmentObject var model: BoardModel
  let group: GroupSummary

  var body: some View {
    // sbd pauses and resumes every member, including those the org filter hides.
    let actions = GroupPause.actions(model.allSessions.filter { $0.group == group.id })
    if actions.pause || actions.resume {
      HStack {
        if actions.pause {
          Button("Pause All") { model.pauseGroup(group.id) }
            .buttonStyle(.link).font(.caption)
            .help(
              "Pause each session in this group that has started and is not done. A session that is already paused keeps its pause."
            )
            .accessibilityLabel("Pause all sessions in \(group.name)")
        }
        if actions.resume {
          Button("Resume All") { model.resumeGroup(group.id) }
            .buttonStyle(.link).font(.caption)
            .help("Resume every paused session in this group. Each one gets the message from its own pause.")
            .accessibilityLabel("Resume all sessions in \(group.name)")
        }
      }
    }
  }
}
