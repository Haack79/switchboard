import SwiftUI
import SwitchboardCore

/// What the loop editor sheet opens for: a new loop, or the loop with this schedule id.
enum LoopEditorRequest: Equatable, Sendable {
  case new
  case edit(String)
}

/// The New Loop… and Edit… sheet: a session (new loops only), an interval, and a prompt.
struct LoopEditor: View {
  /// A session that a new loop can run on.
  struct Choice: Equatable {
    /// The session id, or `Manager.operatorName` when there is no operator yet. sbd's `schedule` creates the
    /// operator for that name.
    let session: String
    let name: String
  }

  /// The sheet's fields, and what Save sends.
  struct Form {
    /// The loop being edited, or nil for a new loop.
    let original: Schedule?
    /// The chosen session id. It is nil for an edit, which can't move a loop to another session.
    var session: String?
    var interval: String
    var prompt: String

    init(new choices: [Choice]) {
      original = nil
      session = choices.first?.session
      interval = ""
      prompt = ""
    }

    init(editing schedule: Schedule) {
      original = schedule
      session = nil
      interval = Schedule.intervalText(schedule.every)
      prompt = schedule.prompt
    }

    private var trimmedInterval: String { interval.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedInterval: Result<Int64, any Error> { Result { try Schedule.parseInterval(trimmedInterval) } }
    private var intervalMs: Int64? { try? parsedInterval.get() }
    /// The prompt that sbd stores, or nil when sbd refuses it.
    private var cleanPrompt: String? { try? Schedule.cleanPrompt(prompt) }

    /// Why the interval can't be read, or nil while it is readable or empty.
    var intervalError: String? {
      guard !trimmedInterval.isEmpty, case .failure(let error) = parsedInterval else { return nil }
      return "\(error)"
    }

    /// The trimmed interval to send, or nil when it doesn't parse or has the edited loop's length.
    var changedInterval: String? {
      guard let ms = intervalMs, ms != original?.every else { return nil }
      return trimmedInterval
    }

    /// The clean prompt to send, or nil when sbd refuses it or it is the edited loop's prompt.
    var changedPrompt: String? {
      guard let text = cleanPrompt, text != original?.prompt else { return nil }
      return text
    }

    var canSave: Bool {
      guard intervalMs != nil, cleanPrompt != nil else { return false }
      if original == nil { return session != nil }
      return changedInterval != nil || changedPrompt != nil
    }
  }

  /// The sessions that a new loop can run on: the operator first, then the Manager conversations, the group chats,
  /// and the work sessions, each by name. A session with no folder is left out, because sbd's `schedule` refuses
  /// it. With no operator, the first choice is `Manager.operatorName`.
  static func sessionChoices(_ sessions: [SessionSummary], operatorID: String?) -> [Choice] {
    let first =
      sessions.first { $0.id == operatorID }.map { Choice(session: $0.id, name: $0.nameWithHost) }
      ?? Choice(session: Manager.operatorName, name: Manager.operatorName)
    func rank(_ kind: SessionKind) -> Int {
      switch kind {
      case .operator: 0
      case .manager: 1
      case .chat: 2
      case .work: 3
      }
    }
    let rest =
      sessions
      .filter { !$0.cwd.isEmpty && $0.id != first.session && $0.kind != .operator }
      .sorted { a, b in
        rank(a.kind) != rank(b.kind) ? rank(a.kind) < rank(b.kind) : BoardModel.byName(a, b)
      }
    return [first] + rest.map { Choice(session: $0.id, name: $0.nameWithHost) }
  }

  @EnvironmentObject var model: BoardModel
  private let editing: Bool
  /// The choices are fixed when the sheet opens, so a newer `ls` answer can't take away the picked session.
  @State private var choices: [Choice]
  @State private var form: Form

  /// `schedule` is the loop that an edit opens with. It is nil for a new loop, and for an edit whose loop is gone.
  init(request: LoopEditorRequest, schedule: Schedule?, choices: [Choice]) {
    editing = request != .new
    _choices = State(initialValue: choices)
    _form = State(initialValue: schedule.map { Form(editing: $0) } ?? Form(new: choices))
  }

  /// The loop that the edit names no longer exists.
  private var missing: Bool { editing && form.original == nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(editing ? "Edit Loop" : "New Loop").font(.title2.bold())
      if missing {
        Text("This loop no longer exists.").foregroundStyle(.secondary)
      } else {
        fields
      }
      if let error = model.loopEditorError {
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.loopEditor = nil }
          .keyboardShortcut(.cancelAction)
        if !missing {
          Button("Save") { save() }
            .keyboardShortcut(.defaultAction)
            .disabled(!form.canSave || model.savingLoop)
        }
      }
    }
    .padding(20)
    .frame(width: 480)
    .announcesRefusal(model.loopEditorError)
  }

  private var fields: some View {
    SwiftUI.Form {
      if !editing {
        Picker("Session", selection: $form.session) {
          ForEach(choices, id: \.session) { Text($0.name).tag(Optional($0.session)) }
        }
        .help("The session that the loop sends its prompt to")
      }
      VStack(alignment: .leading, spacing: 2) {
        TextField("Every", text: $form.interval, prompt: Text("30m"))
          .help("One number and one unit, such as 30m, 2h, or 1d. The shortest is 1m.")
        if let error = form.intervalError {
          Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
      }
      VStack(alignment: .leading) {
        Text("Prompt")
        TextEditor(text: $form.prompt)
          .font(.body.monospaced())
          .frame(minHeight: 120)
          .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
          .accessibilityLabel("Prompt")
      }
    }
  }

  private func save() {
    if let original = form.original {
      model.editSchedule(original.id, every: form.changedInterval, prompt: form.changedPrompt)
    } else if let session = form.session, let every = form.changedInterval, let prompt = form.changedPrompt {
      model.addSchedule(session: session, every: every, prompt: prompt)
    }
  }
}
