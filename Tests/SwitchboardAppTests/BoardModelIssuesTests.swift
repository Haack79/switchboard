import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func row(
  _ repo: String, _ number: Int, _ bucket: IssueBucket, updated: String = "2026-11-10T10:00:00Z",
  created: String = "2026-11-01T10:00:00Z", labels: [String] = [], session: String? = nil, backlog: Bool = false
) -> ListedIssue {
  ListedIssue(
    issue: InboxIssue(
      repo: repo, number: number, title: "Issue \(number)", url: "https://github.com/\(repo)/issues/\(number)",
      labels: labels, createdAt: created, updatedAt: updated),
    bucket: bucket, session: session, backlog: backlog)
}

private func list(
  _ rows: [ListedIssue], team: IssueTeam = IssueTeam(), presets: [IssuePreset] = IssuePreset.defaults
) -> IssueList {
  IssueList(
    viewer: "robin-k", issues: rows, sources: [IssueSource(name: "acme/ledger")], team: team,
    presets: presets, branchPrefix: "robin/")
}

private let rows = [
  row("acme/ledger", 1, .mine, updated: "2026-11-09T10:00:00Z"),
  row("acme/ledger", 2, .mine, updated: "2026-11-11T10:00:00Z"),
  row("acme/ledger-web", 3, .teamUnassigned),
  row("acme/ledger", 4, .teamAssigned),
  row("robin-k/dotkit", 5, .other),
  row("acme/ledger", 6, .workedOn, session: "s1"),
  row("robin-k/dotkit", 7, .teamUnassigned, updated: "2026-11-08T10:00:00Z"),
]

private let backlogTeam = IssueTeam(labels: ["team/billing"], backlog: ["backlog"])

/// 8 is in Team unassigned with the team's label, and 9 is in Mine. 8 has the newer update.
private let backlogRows = [
  row(
    "acme/ledger", 8, .teamUnassigned, updated: "2026-11-12T10:00:00Z", labels: ["team/billing", "backlog"],
    backlog: true),
  row("acme/ledger-web", 9, .mine, updated: "2026-11-07T10:00:00Z", labels: ["backlog"], backlog: true),
]

/// `rows` with the backlog rows at both ends, so the model can't rely on sbd's backlog-last order.
private let withBacklog = [backlogRows[0]] + rows + [backlogRows[1]]

/// The issue numbers of the move order.
@MainActor private func orderNumbers(_ model: BoardModel) -> [Int] {
  model.issueOrder.compactMap { id in model.issues.first { $0.id == id }?.issue.number }
}

@MainActor
@Suite struct BoardModelIssuesTests {
  private func model(_ filter: OrgFilter = OrgFilter()) -> BoardModel {
    let model = orgFilterModel(filter)
    model.issueList = list(rows)
    return model
  }

  @Test func countIsMinePlusTeamUnassigned() {
    #expect(model().issueCount == 4)
  }

  @Test func orgFilterHidesIssuesAndTheirCount() {
    let model = model(OrgFilter(keys: ["acme"]))
    #expect(model.issueCount == 3)
    #expect(!model.issues.contains { $0.issue.repo == "robin-k/dotkit" })
  }

  @Test func teamScopeListsBucketsInOrderWithoutOther() {
    let sections = model().issueSections
    #expect(sections.map(\.id) == ["mine", "teamUnassigned", "teamAssigned", "workedOn"])
    #expect(sections[0].issues.map(\.issue.number) == [2, 1])
  }

  @Test func mineScopeListsOnlyMine() {
    let model = model()
    model.issueScope = .mine
    #expect(model.issueSections.map(\.id) == ["mine"])
  }

  @Test func allScopeAddsOther() {
    let model = model()
    model.issueScope = .all
    #expect(model.issueSections.map(\.id).contains("other"))
  }

  @Test func groupByRepoMakesARepoSectionEachAndKeepsBeingWorkedOnLast() {
    let model = model()
    model.issuesByRepo = true
    #expect(
      model.issueSections.map(\.id) == ["repo:acme/ledger", "repo:acme/ledger-web", "repo:robin-k/dotkit", "workedOn"])
  }

  @Test func collapsedSectionsLeaveTheMoveOrder() {
    let model = model()
    let numbers = { model.issueOrder.compactMap { id in rows.first { $0.id == id }?.issue.number } }
    #expect(numbers() == [2, 1, 3, 7])
    model.toggleIssueSection("teamAssigned")
    #expect(numbers() == [2, 1, 3, 7, 4])
  }

  @Test func jAndKMoveAroundTheEnds() {
    let model = model()
    #expect(model.currentIssue?.issue.number == 2)
    model.moveIssue(by: -1)
    #expect(model.currentIssue?.issue.number == 7)
    model.moveIssue(by: 1, wrap: false)
    #expect(model.currentIssue?.issue.number == 7)
  }

  // MARK: Backlog

  private func model(_ rows: [ListedIssue], team: IssueTeam = backlogTeam) -> BoardModel {
    let model = orgFilterModel()
    model.issueList = list(rows, team: team)
    return model
  }

  @Test func backlogRowsGoInOneSectionAfterBeingWorkedOn() {
    let sections = model(withBacklog).issueSections

    #expect(sections.map(\.id) == ["mine", "teamUnassigned", "teamAssigned", "workedOn", "backlog"])
    #expect(sections.last?.title == "Backlog")
    #expect(sections.last?.issues.map(\.issue.number) == [8, 9])
    #expect(sections.last?.hiddenCount == nil)
  }

  @Test func backlogSectionComesLastWhenGroupedByRepo() {
    let model = model(withBacklog)

    model.issuesByRepo = true

    let sections = model.issueSections
    #expect(
      sections.map(\.id) == [
        "repo:acme/ledger", "repo:acme/ledger-web", "repo:robin-k/dotkit", "workedOn", "backlog",
      ])
    #expect(sections.last?.issues.map(\.issue.number) == [8, 9])
    #expect(!sections.dropLast().contains { $0.issues.contains(where: \.backlog) })
  }

  /// 20 is in Team unassigned and 21 is in Mine. 20 has the newer update and the later creation, so Updated and
  /// Oldest give opposite orders. An order by bucket puts 21 first and fails the Updated case.
  @Test(arguments: zip([IssueSort.updated, .oldest], [[20, 21], [21, 20]]))
  func backlogSectionFollowsTheSort(_ sort: IssueSort, _ expected: [Int]) {
    let model = model(
      rows + [
        row(
          "acme/ledger", 20, .teamUnassigned, updated: "2026-11-12T10:00:00Z", created: "2026-10-09T10:00:00Z",
          labels: ["backlog"], backlog: true),
        row(
          "acme/ledger", 21, .mine, updated: "2026-11-05T10:00:00Z", created: "2026-10-01T10:00:00Z",
          labels: ["backlog"], backlog: true),
      ])

    model.issueSort = sort

    #expect(model.issueSections.last?.issues.map(\.issue.number) == expected)
  }

  @Test func backlogSectionHoldsOnlyTheScopesBuckets() {
    let other = model(rows + [row("robin-k/dotkit", 10, .other, labels: ["backlog"], backlog: true)])
    let mine = model(withBacklog)
    #expect(!other.issueSections.contains { $0.id == "backlog" })

    other.issueScope = .all
    mine.issueScope = .mine

    #expect(other.issueSections.last?.id == "backlog")
    #expect(other.issueSections.last?.issues.map(\.issue.number) == [10])
    #expect(mine.issueSections.map(\.id) == ["mine", "backlog"])
    #expect(mine.issueSections.last?.issues.map(\.issue.number) == [9])
  }

  @Test func aBacklogIssueWithATeamLabelLeavesTheTeamSection() {
    let sections = model(withBacklog).issueSections

    #expect(sections.first { $0.id == "teamUnassigned" }?.issues.map(\.issue.number) == [3, 7])
    #expect(sections.first { $0.id == "backlog" }?.issues.contains { $0.issue.number == 8 } == true)
  }

  /// Every row carries the label `backlog` and none has the flag, as for an issue that a session works on. The
  /// model reads only the flag, so the sections and the move order match a list whose rows have no labels.
  @Test(arguments: [IssueTeam(), backlogTeam])
  func withNoBacklogRowsTheSectionsAndMoveOrderAreUnchanged(_ team: IssueTeam) {
    let labeled = rows.map { plainRow in
      var labeledRow = plainRow
      labeledRow.issue.labels.append("backlog")
      return labeledRow
    }
    let plain = model(rows, team: IssueTeam())
    let model = model(labeled, team: team)

    for scope in IssueScope.allCases {
      for byRepo in [false, true] {
        plain.issueScope = scope
        plain.issuesByRepo = byRepo
        model.issueScope = scope
        model.issuesByRepo = byRepo

        #expect(model.issueSections.map(\.id) == plain.issueSections.map(\.id), "\(scope) byRepo: \(byRepo)")
        #expect(
          model.issueSections.map { $0.issues.map(\.id) } == plain.issueSections.map { $0.issues.map(\.id) },
          "\(scope) byRepo: \(byRepo)")
        #expect(model.issueOrder == plain.issueOrder, "\(scope) byRepo: \(byRepo)")
        #expect(!model.issueSections.contains { $0.id == "backlog" }, "\(scope) byRepo: \(byRepo)")
      }
    }
  }

  /// No issue list yet, a team with no backlog label, or a team with only blank ones matches no issue, so the sort
  /// menu offers no Hide Backlog. A nil team stands for no issue list.
  @Test(
    arguments: zip(
      [
        nil, IssueTeam(), IssueTeam(labels: ["team/billing"]), IssueTeam(backlog: [""]), IssueTeam(backlog: ["  "]),
        backlogTeam,
      ] as [IssueTeam?],
      [false, false, false, false, false, true]))
  func withNoBacklogLabelThereIsNoToggle(_ team: IssueTeam?, _ shows: Bool) {
    let model = orgFilterModel()

    model.issueList = team.map { list(rows, team: $0) }

    #expect(model.showsBacklogToggle == shows)
  }

  @Test func hidingTheBacklogKeepsTheDividerWithItsCount() {
    let model = model(withBacklog)

    model.hidesBacklog = true

    let sections = model.issueSections
    #expect(sections.map(\.id) == ["mine", "teamUnassigned", "teamAssigned", "workedOn", "backlog"])
    #expect(sections.last?.issues == [])
    #expect(sections.last?.hiddenCount == 2)
  }

  @Test func hiddenBacklogRowsLeaveTheMoveOrder() {
    let model = model(withBacklog)
    #expect(orderNumbers(model) == [2, 1, 3, 7, 8, 9])

    model.hidesBacklog = true

    #expect(orderNumbers(model) == [2, 1, 3, 7])
    model.moveIssue(by: -1)
    #expect(model.currentIssue?.issue.number == 7)
    model.moveIssue(by: 1)
    #expect(model.currentIssue?.issue.number == 2)
  }

  @Test func focusOnAHiddenIssueFallsBackToTheFirstRow() {
    let model = model(withBacklog)
    model.issueFocus = backlogRows[0].id
    #expect(model.currentIssue?.issue.number == 8)

    model.hidesBacklog = true

    #expect(model.currentIssue?.issue.number == 2)
  }

  @Test func hidingWhenOnlyBacklogIsInScopeLeavesTheDividerAlone() {
    let model = model(rows.filter { $0.bucket != .mine } + backlogRows)
    model.issueScope = .mine

    model.hidesBacklog = true

    #expect(model.issueSections.map(\.id) == ["backlog"])
    #expect(model.issueSections.first?.issues == [])
    #expect(model.issueSections.first?.hiddenCount == 1)
    #expect(model.issueOrder == [])
    #expect(model.currentIssue == nil)
  }

  /// Group by Repo drops the empty sections. The hidden divider has no rows and must stay.
  @Test func hidingTheBacklogWithGroupByRepoKeepsTheDivider() {
    let onlyBacklog = model(backlogRows)
    let model = model(withBacklog)
    model.issuesByRepo = true
    onlyBacklog.issuesByRepo = true

    model.hidesBacklog = true
    onlyBacklog.hidesBacklog = true

    #expect(
      model.issueSections.map(\.id) == [
        "repo:acme/ledger", "repo:acme/ledger-web", "repo:robin-k/dotkit", "workedOn", "backlog",
      ])
    #expect(model.issueSections.last?.hiddenCount == 2)
    #expect(onlyBacklog.issueSections.map(\.id) == ["backlog"])
    #expect(onlyBacklog.issueSections.first?.hiddenCount == 2)
  }

  @Test func hidingACollapsedBacklogKeepsTheDividerAndItsCount() {
    let model = model(withBacklog)
    model.toggleIssueSection("backlog")
    #expect(orderNumbers(model) == [2, 1, 3, 7])

    model.hidesBacklog = true

    #expect(model.issueSections.last?.id == "backlog")
    #expect(model.issueSections.last?.hiddenCount == 2)
    #expect(orderNumbers(model) == [2, 1, 3, 7])
  }

  @Test func showingACollapsedHiddenBacklogExpandsIt() {
    let model = model(withBacklog)
    model.toggleIssueSection("backlog")
    model.hidesBacklog = true

    model.showBacklog()

    #expect(!model.hidesBacklog)
    #expect(!model.collapsedIssueSections.contains("backlog"))
    #expect(orderNumbers(model) == [2, 1, 3, 7, 8, 9])
  }

  @Test func hidingTheBacklogIsSavedAndReadByTheNextModel() throws {
    let name = "issues-backlog-tests-" + UUID().uuidString
    let store = try #require(UserDefaults(suiteName: name))
    defer { store.removePersistentDomain(forName: name) }
    let first = orgFilterModel(store: store)
    #expect(!first.hidesBacklog)

    first.hidesBacklog = true

    #expect(store.bool(forKey: "issuesHideBacklog"))
    #expect(orgFilterModel(store: store).hidesBacklog)
    first.hidesBacklog = false
    #expect(!orgFilterModel(store: store).hidesBacklog)
  }

  @Test func withoutAStoreHidingTheBacklogSavesNothing() {
    let before = UserDefaults.standard.object(forKey: "issuesHideBacklog") as? Bool
    let model = orgFilterModel(store: nil)

    model.hidesBacklog = true

    #expect(UserDefaults.standard.object(forKey: "issuesHideBacklog") as? Bool == before)
    #expect(!orgFilterModel(store: nil).hidesBacklog)
  }

  @Test func countLeavesOutBacklogIssues() {
    #expect(model(withBacklog).issueCount == model().issueCount)
  }

  @Test func issuesIsTheThirdMainViewForNextSession() {
    let model = model()
    model.show(.issues)
    model.selectAdjacentSession(by: 1)
    #expect(model.currentIssue?.issue.number == 1)
  }

  @Test func startSendsTheIssueThePresetAndThePickedGroup() async {
    let sent = await firstRequest { model in
      model.issueGroupPicks[rows[0].id] = "g1"
      model.startIssue(rows[0], preset: IssuePreset(name: "go", prompt: ""))
    }
    #expect(sent.op == "issues-start")
    #expect(sent.args == ["issue": "acme/ledger#1", "preset": "go", "group": "g1"])
  }

  @Test func startWithAChosenFolderSendsItsPath() async {
    let sent = await firstRequest { model in
      model.startIssue(rows[0], preset: IssuePreset(name: "plain", prompt: ""), path: "/tmp/ledger")
    }
    #expect(sent.args == ["issue": "acme/ledger#1", "preset": "plain", "path": "/tmp/ledger"])
  }

  @Test func notMineSendsDismiss() async {
    let sent = await firstRequest { model in model.dismissIssue(rows[2]) }
    #expect(sent.op == "issues-dismiss")
    #expect(sent.args == ["issue": "acme/ledger-web#3"])
  }

  @Test func editThePromptFirstFillsTheNewSessionSheet() {
    let model = model()
    model.issueGroupPicks[rows[0].id] = "g1"
    model.editIssuePrompt(rows[0], preset: IssuePreset(name: "go", prompt: "/go --yolo {url}"))
    let request = model.newSession
    #expect(request?.repo == "acme/ledger")
    #expect(request?.branch == "robin/1-issue-1")
    #expect(request?.prompt == "/go --yolo https://github.com/acme/ledger/issues/1")
    #expect(request?.issue == IssueRef(repo: "acme/ledger", number: 1))
    #expect(request?.group == "g1")
  }

  @Test(arguments: [("robin-k", false), ("zed-q", true), (nil, true)] as [(String?, Bool)])
  func editThePromptFirstStartsInManualModeForAnOutsideAuthor(author: String?, manual: Bool) {
    let model = model()
    var issue = rows[0]
    issue.issue.author = author
    model.editIssuePrompt(issue, preset: IssuePreset(name: "go", prompt: "/go --yolo {url}"))

    #expect(model.newSession?.manualMode == manual)
  }

  @Test(arguments: [("robin-k", false), ("zed-q", true), (nil, true)] as [(String?, Bool)])
  func followUpFencesTheTitleOnTheIssuesBranchAndStartsInManualModeForAnOutsideAuthor(
    author: String?, manual: Bool
  ) async {
    var issue = rows[0]
    issue.issue.author = author
    let sent = await firstRequest { model in
      model.issueList = list(rows)
      model.followUpIssue(issue)
    }

    #expect(sent.op == "followup-add")
    #expect(sent.args["prompt"]?.string?.contains("<issue-title>Issue 1</issue-title>") == true)
    #expect(sent.args["branch"] == "robin/1-issue-1")
    #expect(sent.args["manualMode"] == (manual ? .bool(true) : nil))
    #expect(sent.args["autoMode"] == nil)
  }

  @Test(arguments: [false, true])
  func theSheetSendsTheRequestsManualMode(manual: Bool) {
    let form = NewSessionView.Form(request: NewSessionRequest(repo: "acme/ledger", manualMode: manual))
    form.offer([KnownRepo(path: "/dev/acme/ledger", name: "acme/ledger")])

    #expect(form.request(worktree: false, groups: [])?.manualMode == (manual ? true : nil))
  }

  @Test func aWorkedOnIssueDoesNotStart() async {
    let (model, release, requests) = heldModel()
    model.startIssue(rows[5], preset: IssuePreset(name: "go", prompt: ""))
    release.signal()
    #expect(requests.value == 0)
    #expect(model.startingIssues.isEmpty)
  }

  @Test func lastPresetWinsThenTheDefaultThenTheFirst() {
    let presets = [IssuePreset(name: "go", prompt: ""), IssuePreset(name: "plain", prompt: "")]
    #expect(IssuePreset.choose(presets, last: "plain", default: nil)?.name == "plain")
    #expect(IssuePreset.choose(presets, last: "gone", default: nil)?.name == "go")
    #expect(IssuePreset.choose(presets, last: "gone", default: "plain")?.name == "plain")
    #expect(IssuePreset.choose(presets, last: nil, default: "gone")?.name == "go")
  }
}

@MainActor
@Suite struct NewSessionFormIssueTests {
  @Test func requestNamesTheRepoBranchPromptAndIssue() {
    let form = NewSessionView.Form(
      request: NewSessionRequest(
        group: nil, repo: "Acme/Ledger", branch: "robin/1-issue-1", prompt: "/go --yolo x",
        issue: IssueRef(repo: "acme/ledger", number: 1)))
    form.offer([
      KnownRepo(path: "/dev/acme/flagship", name: "acme/flagship", used: 2),
      KnownRepo(path: "/dev/acme/ledger", name: "acme/ledger", used: 1),
    ])
    let request = form.request(worktree: true, groups: [])
    #expect(request?.path == "/dev/acme/ledger")
    #expect(request?.branch == "robin/1-issue-1")
    #expect(request?.prompt == "/go --yolo x")
    #expect(request?.issue == IssueRef(repo: "acme/ledger", number: 1))
  }

  @Test func requestForARepoWithNoCheckoutSelectsNoRepo() {
    let form = NewSessionView.Form(
      request: NewSessionRequest(group: nil, repo: "acme/ledger-web", branch: "robin/1-issue-1", prompt: "x"))
    form.offer([KnownRepo(path: "/dev/acme/flagship", name: "acme/flagship", used: 2)])

    #expect(form.repo == nil)
    #expect(form.request(worktree: true, groups: []) == nil)
  }
}
