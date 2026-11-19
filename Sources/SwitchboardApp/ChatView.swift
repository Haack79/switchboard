import SwiftUI
import SwitchboardCore

/// A group chat, a Manager conversation, or the operator: its last messages
/// and a field that sends it one. The terminals are behind a toggle.
struct ChatView: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    VStack(spacing: 0) {
      ChatHeader(session: session)
      if session.kind == .manager { ManagerStatusStrip(session: session) }
      SchedulesStrip(session: session)
      Divider()
      if model.showingTerminal {
        SessionView(session: session)
      } else {
        ChatMessages(
          log: model.chatLogs[session.id],
          pending: pending,
          emptyText: emptyText,
          session: session.id)
        Divider()
        // The Inbox leaves out the cards of a chat and a Manager, such as a group message that waits for the user.
        // They show here instead.
        CardList(cards: session.cards)
        let proposals = session.chat.map { g in model.planProposals.filter { $0.group == g } } ?? []
        if !proposals.isEmpty { PlanProposalList(proposals: proposals) }
        PauseBanner(session: session)
        WorkSkillOfferBar(session: session)
        MessageField(
          session: session.id, draft: model.messageDraft(for: session),
          shortcut: KeyboardShortcut(.return, modifiers: [.command]),
          intercept: session.kind.runsInManagerFolder ? { model.submitChecked(session: session.id, draft: $0) } : nil
        )
        .padding(8)
      }
    }
    // A tool call changes lastActivity, so the log reloads only when the reply or the state changes.
    .task(id: "\(session.lastReply?.count ?? 0)/\(session.state)/\(session.since)") { model.loadChatLog(session.id) }
    // A reload on the state change can run before claude writes the prompt to the transcript. The log therefore
    // reloads while a message that sbd accepted waits. Each state change starts the reads again. The cap stops them for a
    // message that never arrives, such as one queued for a host that is down.
    .task(id: Polling(accepted: pending.filter(\.accepted).map(\.id), since: session.since)) {
      guard pending.contains(where: \.accepted) else { return }
      for _ in 0..<10 {
        try? await Task.sleep(for: .seconds(2))
        if Task.isCancelled { return }
        model.loadChatLog(session.id)
      }
    }
    .onChange(of: pending.last(where: \.failed)) { _, failed in
      if let error = failed?.error { AccessibilityNotification.Announcement("Not sent: \(error)").post() }
    }
    .referenceRepo(session)
  }

  private var emptyText: String {
    switch session.kind {
    case .manager: "No messages yet. Ask the Manager about your sessions."
    case .operator: "The operator hasn't run yet. It follows through on waits that your conversations hand it."
    case .chat, .work: "No messages yet. Ask the chat about this group's sessions."
    }
  }

  private struct Polling: Hashable {
    var accepted: [UUID]
    var since: Int64
  }

  private var pending: [PendingChatMessage] { model.pendingChat[session.id] ?? [] }
}

private struct ChatHeader: View {
  @EnvironmentObject var model: BoardModel
  let session: SessionSummary

  var body: some View {
    HStack(spacing: 8) {
      Text(session.name).fontWeight(.medium).lineLimit(1)
      StateBadge(state: session.state)
      Spacer()
      SessionAccountControl(session: session)
      if session.kind.runsInManagerFolder { MCPServerMenu(session: session) }
      if session.kind == .manager {
        Button("New Task", systemImage: "plus") { model.openNewSession(parent: session.id) }
          .help("Start a session that this conversation follows")
          .fixedSize()
      }
      Toggle("Terminal", isOn: $model.showingTerminal)
        .toggleStyle(.button)
        .help("Show the Claude terminal and shell in place of the messages")
    }
    .padding(10)
  }
}

/// The messages and then the sent messages that the log does not hold yet, or a spinner while `log` is nil
/// because the log has not loaded.
private struct ChatMessages: View {
  let log: [ChatMessage]?
  let pending: [PendingChatMessage]
  let emptyText: String
  let session: String

  private var messages: [ChatMessage] { log ?? [] }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if log == nil {
            ProgressView().controlSize(.small)
          } else if messages.isEmpty && pending.isEmpty {
            Text(emptyText).foregroundStyle(.secondary)
          }
          ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
            ChatBubble(message: message).id(index)
          }
          ForEach(pending) { message in
            PendingBubble(message: message, session: session).id(message.id)
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      // The scroll follows the last message, because the count stops changing once the log is full.
      .onChange(of: messages.last, initial: true) { scrollToBottom(proxy) }
      .onChange(of: pending) { scrollToBottom(proxy) }
    }
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy) {
    if let last = pending.last {
      proxy.scrollTo(last.id, anchor: .bottom)
    } else {
      proxy.scrollTo(messages.count - 1, anchor: .bottom)
    }
  }
}

/// A message. A notice from Switchboard and a built-in command's output show as one grey line with the full
/// text in the tooltip.
private struct ChatBubble: View {
  let message: ChatMessage

  var body: some View {
    if let grey = message.commandOutput ?? (message.isNotice ? message.text : nil) {
      if !grey.isEmpty { GreyLine(text: grey) }
    } else {
      Bubble(role: message.role) {
        if message.role == .user {
          InlineText(plain: message.slashCommand ?? message.text).textSelection(.enabled)
        } else {
          MarkdownView(text: message.text)
        }
      }
    }
  }
}

/// A sent message that the log does not hold yet, with a line that says how far it got, or why sbd refused it.
private struct PendingBubble: View {
  @EnvironmentObject var model: BoardModel
  let message: PendingChatMessage
  let session: String

  var body: some View {
    Bubble(role: .user) {
      if !message.text.isEmpty { InlineText(plain: message.text).textSelection(.enabled) }
      if let progress = message.progress {
        HStack(spacing: 6) {
          HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(progress).font(.caption).foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(progress)
          // An accepted message can fail to reach the transcript. The user can then remove its bubble. The button sits
          // outside the ignored group so that VoiceOver reaches it.
          if message.accepted {
            Spacer()
            Button("Hide") { model.dismissPending(message.id, in: session) }.controlSize(.small)
          }
        }
      } else if let error = message.error {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          InlineText(plain: "Not sent: \(error)").font(.caption).foregroundStyle(.red)
          Spacer()
          Button("Dismiss") { model.dismissPending(message.id, in: session) }.controlSize(.small)
        }
      }
    }
  }
}

/// A message's speaker above its content, on the user's tint for the user's messages.
private struct Bubble<Content: View>: View {
  let role: ChatMessage.Role
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(role.label).font(.caption.bold()).foregroundStyle(.secondary)
      content
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(role == .user ? Color.accentColor.opacity(0.08) : Color.clear))
  }
}

/// A notice or command output, cut to its first line. The full text is the
/// tooltip, so the line draws names without links, whose tooltip would compete with it.
private struct GreyLine: View {
  @Environment(\.sessionNames) private var names
  let text: String

  var body: some View {
    InlineText(plain: String(text.prefix { !$0.isNewline }), links: false)
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .help(names.replacingIDs(in: text))
      .padding(.horizontal, 10)
  }
}
