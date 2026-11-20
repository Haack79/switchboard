import SwiftUI
import SwitchboardCore

/// The right pane of the Inbox: the session's decision card, and a field that
/// talks to the session itself. The terminals are behind a toggle.
struct TriageDetail: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  enum Pane { case terminal, summary }

  /// An unstarted follow-up and a docket row have no terminals, so they show their summary whatever the toggle says.
  /// A failed removal shows its summary too, because the summary holds Retry and Keep.
  static func pane(for session: SessionSummary, showingTerminal: Bool) -> Pane {
    showingTerminal && !session.waitsToStart && session.runsClaude && session.removal?.state != .failed
      ? .terminal : .summary
  }

  /// The PR that the bar links to, with the code owners of that PR. A docket
  /// row links to the PR that docket reviews and ignores its `pr`. The bar
  /// therefore never shows one PR's link beside another PR's code owners.
  /// `head` is the PR's branch when the folder is on another branch.
  static func prLink(for session: SessionSummary) -> (
    label: String, url: URL, owners: CodeOwnerStatus?, head: String?
  )? {
    if let docket = session.docket { return docket.link.map { (docket.pullRequest, $0, nil, nil) } }
    if let pr = session.pr, let url = pr.link {
      return (pr.line, url, pr.codeOwners, pr.otherBranch(than: session.branch))
    }
    return nil
  }

  struct ReplyKey: Hashable {
    var session: String
    var reply: String?
    var since: Int64
  }

  /// When the pane reads the session's reply again: for each new `lastReply`, and on each change of state.
  static func replyKey(_ session: SessionSummary) -> ReplyKey {
    ReplyKey(session: session.id, reply: session.lastReply, since: session.since)
  }

  var body: some View {
    VStack(spacing: 0) {
      bar
      Divider()
      if Self.pane(for: session, showingTerminal: model.showingTerminal) == .terminal {
        SessionView(session: session)
      } else {
        DetailPane {
          VStack(alignment: .leading, spacing: 14) {
            if session.removal?.state == .failed {
              FailedRemovalActions(session: session)
              reply
            } else if let item = session.triage {
              DecisionCard(session: session, item: item, step: step)
            } else {
              working
              reply
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let list = session.stepList {
          Divider()
          DecisionStepBar(session: session, list: list, step: step)
        }
        Divider()
        if session.waitsToStart {
          // A follow-up has no claude to message yet.
          StartButton(session: session).padding(8)
        } else if session.runsClaude {
          MessageField(
            session: session.id, draft: model.messageDraft(for: session),
            shortcut: KeyboardShortcut(.return, modifiers: [.command]), ref: session.triage?.ref
          )
          .padding(8)
        }
      }
    }
    .task(id: Self.replyKey(session)) { model.loadReply(session) }
    .referenceRepo(session)
  }

  /// The step that the card's decision view shows, which `BoardModel` keeps so that it survives leaving the item.
  private var step: Binding<DecisionStep?> {
    let id = session.id
    let ref = session.stepList?.ref
    return Binding(
      get: { ref.flatMap { model.decisionStep(session: id, ref: $0) } },
      set: { step in if let ref { model.setDecisionStep(step, session: id, ref: ref) } })
  }

  private var bar: some View {
    // Every item keeps to one line. When the pane is narrow, the repo and branch truncate first, then the PR link,
    // then the name. The buttons keep their full width.
    HStack(spacing: 8) {
      Text(model.inboxName(session)).fontWeight(.medium).lineLimit(1).layoutPriority(2)
        .help(model.inboxName(session))
      if let repo = session.repoFolder {
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        Text(name).foregroundStyle(.secondary).lineLimit(1).help(name)
      }
      if let branch = session.branch {
        Text(branch).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(branch)
      }
      if let link = Self.prLink(for: session) {
        HStack(spacing: 4) {
          PRLink(text: link.label, url: link.url).font(.caption).foregroundStyle(.link).lineLimit(1)
            .help(link.label)
          if let owners = link.owners { CodeOwnerShield(status: owners) }
          if let head = link.head {
            Text("uses \(head)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
              .help("The PR's branch, \(head). This folder is on \(session.branch ?? "another branch").")
          }
        }
        .layoutPriority(1)
      }
      Spacer(minLength: 0)
      Button("Open") { model.selection = session.id }
        .fixedSize()
        .help("Show the session in the sidebar, with its terminals")
      Toggle("Terminal", isOn: $model.showingTerminal)
        .toggleStyle(.button)
        .fixedSize()
        .disabled(!session.runsClaude)
        .help(
          session.waitsToStart
            ? "A follow-up has no terminals until it starts"
            : !session.runsClaude
              ? "A docket review has no terminals"
              : "Show the session's Claude terminal and shell in place of its summary")
    }
    .padding(10)
  }

  private var working: some View {
    HStack(spacing: 8) {
      if session.state == .working { ProgressView().controlSize(.small) }
      InlineText(plain: session.state == .working ? "Working: \(session.reason)" : session.reason)
        .foregroundStyle(.secondary)
      if session.acknowledged == true { AcknowledgeButton(session: session) }
    }
  }

  @ViewBuilder
  private var reply: some View {
    if let text = model.reply(for: session), !text.isEmpty {
      LastReplySection(text: text).padding(.top, 4)
    }
  }
}

/// The Inbox's detail pane, which scrolls the whole card. It puts its scroll proxy in the environment, so text boxes
/// in it drop their own height caps.
struct DetailPane<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView { content }
        .environment(\.detailScroll, proxy)
    }
  }
}
