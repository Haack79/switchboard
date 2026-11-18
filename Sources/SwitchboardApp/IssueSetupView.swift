import AppKit
import SwiftUI
import SwitchboardCore

/// The Issues view's setup sheet: the sources, the team's labels and logins, and the default start preset.
struct IssueSetupView: View {
  @EnvironmentObject var model: BoardModel
  @Environment(\.dismiss) private var dismiss
  @Binding var uncheckedRepos: Set<String>
  @State private var offerLabelFocused = false
  @State private var name = ""
  @State private var label = ""
  @State private var person = ""
  @State private var addError: String?
  @State private var adding = false
  @State private var labels = ""
  @State private var people = ""
  @State private var backlog = ""
  @State private var defaultPreset: String?
  /// The team that the fields loaded, or nil before the first read. The sheet can open before it.
  @State private var loadedTeam: IssueTeam?

  var body: some View {
    let list = model.issueList
    VStack(alignment: .leading, spacing: 14) {
      Text("Issue Sources").font(.title2.bold())
      if !model.offeredIssueRepos.isEmpty {
        GroupBox("Your Repositories") {
          IssueRepoOffer(unchecked: $uncheckedRepos) { offerLabelFocused = $0 }.padding(4)
        }
      }
      GroupBox("Sources") {
        VStack(alignment: .leading, spacing: 6) {
          if list?.sources.isEmpty ?? true {
            Text("No sources yet").foregroundStyle(.secondary)
          }
          ForEach(list?.sources ?? [], id: \.key) { source in
            HStack {
              Text(source.name).fontWeight(.medium)
              Text(filterText(source)).foregroundStyle(.secondary)
              Spacer()
              Button {
                model.removeIssueSource(source)
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
              .help("Remove this source")
              .accessibilityLabel("Remove \(source.key)")
            }
          }
          Divider()
          HStack {
            TextField("Org or owner/name", text: $name)
            Menu {
              ForEach(model.suggestedIssueSources, id: \.self) { suggestion in
                Button(suggestion) { name = suggestion }
              }
            } label: {
              Image(systemName: "text.badge.plus")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.suggestedIssueSources.isEmpty)
            .help("The orgs and repositories of your sessions and checkouts")
            .accessibilityLabel("Suggested sources")
            TextField("Label", text: $label, prompt: Text(isOrg ? "Label" : "Label (optional)"))
            TextField("Person", text: $person, prompt: Text(isOrg ? "Person" : "Person (optional)"))
            Button("Add") { add() }
              .disabled(!canAdd || adding)
              .keyboardShortcut(returnOwner == .add ? .defaultAction : nil)
          }
          if let problem = addProblem ?? addError {
            Text(problem).font(.caption).foregroundStyle(.red)
          } else {
            Text(
              "Sources decide which issues are fetched. A repository needs no filter. An org needs a label or a person."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(4)
        .announcesRefusal(addError)
      }
      GroupBox("My Team") {
        VStack(alignment: .leading, spacing: 6) {
          TextField("Labels", text: $labels, prompt: Text("Labels, separated by commas"))
          TextField("People", text: $people, prompt: Text("Logins, separated by commas"))
          TextField("Backlog", text: $backlog, prompt: Text("Backlog labels, separated by commas"))
          Text(
            "Sorts fetched issues into the Mine and Team views, with backlog issues last. It doesn't change which issues are fetched."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        .padding(4)
      }
      HStack {
        Picker("Start preset", selection: $defaultPreset) {
          ForEach(list?.presets ?? [], id: \.name) { Text($0.name).tag(Optional($0.name)) }
        }
        .fixedSize()
        Button("Edit Presets…") { NSWorkspace.shared.open(URL(fileURLWithPath: Home().config)) }
          .help("Presets are prompt templates under issues.presets in config.json")
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          model.saveIssueSettings(
            labels: Self.list(labels, loaded: loadedTeam?.labels),
            people: Self.list(people, loaded: loadedTeam?.people),
            backlog: Self.list(backlog, loaded: loadedTeam?.backlog), defaultPreset: defaultPreset)
          dismiss()
        }
        .keyboardShortcut(returnOwner == .save ? .defaultAction : nil)
      }
    }
    .padding(20)
    .frame(width: 600)
    .onAppear { model.loadRepos() }
    .onChange(of: model.issueList == nil, initial: true) {
      guard loadedTeam == nil, let list = model.issueList else { return }
      loadedTeam = list.team
      labels = Self.text(list.team.labels)
      people = Self.text(list.team.people)
      backlog = Self.text(list.team.backlog)
      defaultPreset = IssuePreset.choose(list.presets, last: nil, default: list.defaultPreset)?.name
    }
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

  /// Whether the typed name is an org, which needs a label or a person. A repository takes either one as an optional
  /// filter.
  private var isOrg: Bool { IssueSource(name: trimmedName).isOrg }

  private enum ReturnOwner { case offer, add, save }

  /// The one button that Return presses. Return adds the checked repositories while the offer's label field has
  /// focus, and it adds a typed source instead of saving the sheet without it.
  private var returnOwner: ReturnOwner { offerLabelFocused ? .offer : trimmedName.isEmpty ? .save : .add }

  private var canAdd: Bool { !trimmedName.isEmpty && addProblem == nil }

  /// The rule that sbd also checks, shown before Add.
  private var addProblem: String? {
    guard !trimmedName.isEmpty, isOrg else { return nil }
    let blank = { (s: String) in s.trimmingCharacters(in: .whitespaces).isEmpty }
    return blank(label) && blank(person) ? IssueSource.orgNeedsFilter : nil
  }

  private func add() {
    adding = true
    addError = nil
    model.addIssueSources([trimmedName], label: label, person: person) { error in
      adding = false
      addError = error
      if error == nil {
        name = ""
        label = ""
        person = ""
      }
    }
  }

  private func filterText(_ source: IssueSource) -> String {
    [source.label.map { "label \($0)" }, source.person.map { "assigned to \($0)" }].compactMap { $0 }
      .joined(separator: ", ")
  }

  static func text(_ list: [String]) -> String { list.joined(separator: ", ") }

  /// The entries of a field that lists them separated by commas. A field that still shows the text of the list it
  /// loaded gives that list back, because an entry that config.json or `sb issues team` set can hold a comma.
  static func list(_ text: String, loaded: [String]?) -> [String] {
    if let loaded, text == Self.text(loaded) { return loaded }
    return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }
}
