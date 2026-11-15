import SwiftUI
import SwitchboardCore

/// The ⇧⌘K panel that asks one question about Switchboard. A claude turn with no tools answers it from a snapshot of
/// the state. Closing the panel discards the answer. Continue as Chat starts a Manager conversation that carries it.
struct QuickAskView: View {
  @EnvironmentObject var model: BoardModel
  @FocusState private var fieldFocused: Bool
  // The text stays in the view. A @Published copy on BoardModel would redraw every view that observes the model on
  // each keystroke.
  @State private var question = ""

  var body: some View {
    let state = model.quickAsk ?? QuickAskState()
    VStack(spacing: 0) {
      field
      if state.phase != .editing {
        Divider()
        result(state.phase)
      }
      Divider()
      footer(state)
    }
    .frame(width: 600)
    .onAppear { fieldFocused = true }
    .onDisappear { model.closeQuickAsk() }
    .onChange(of: state.phase) {
      switch state.phase {
      case .answered(let answer): AccessibilityNotification.Announcement(answer).post()
      case .failed(let reason): AccessibilityNotification.Announcement(reason).post()
      case .editing, .asking: break
      }
    }
    .onExitCommand { model.closeQuickAsk() }
  }

  private var field: some View {
    HStack(spacing: 8) {
      Image(systemName: "questionmark.bubble").foregroundStyle(.secondary)
      TextField("Ask Switchboard", text: $question)
        .textFieldStyle(.plain)
        .font(.title3)
        .focused($fieldFocused)
        .accessibilityLabel("Ask Switchboard")
        // An input method that is composing keeps Return. onSubmit only fires once it commits.
        .onSubmit { model.submitQuickAsk(question) }
    }
    .padding(12)
  }

  @ViewBuilder
  private func result(_ phase: QuickAskState.Phase) -> some View {
    switch phase {
    case .editing:
      EmptyView()
    case .asking:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Asking…").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
    case .answered(let answer):
      ScrollView {
        MarkdownView(text: answer).padding(12)
      }
      .frame(maxHeight: 360)
      .fixedSize(horizontal: false, vertical: true)
    case .failed(let reason):
      Label(reason, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
  }

  private func footer(_ state: QuickAskState) -> some View {
    HStack {
      Text("Read-only. The answer goes away when this closes.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Close") { model.closeQuickAsk() }
        .keyboardShortcut(.cancelAction)
      Button("Continue as Chat") { model.continueQuickAskAsChat() }
        .disabled(state.asked == nil)
    }
    .padding(12)
  }
}
