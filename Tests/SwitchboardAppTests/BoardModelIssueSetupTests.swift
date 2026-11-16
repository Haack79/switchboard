import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private func known(_ name: String, at path: String? = nil) -> KnownRepo {
  KnownRepo(path: path ?? "/dev/\(name)", name: name)
}

private func sourceList(_ sources: [IssueSource]) -> IssueList {
  IssueList(
    viewer: "robin-k", issues: [], sources: sources, team: IssueTeam(), presets: IssuePreset.defaults,
    branchPrefix: "robin/")
}

/// Names that `Issues.validRepo` refuses: a bare folder name, and malformed `owner/name` forms.
private let invalidRepoNames = [
  "dotfiles", "acme/ledger/web", "acme/", "/ledger", "acme/led ger", "./ledger", "acme/..", "äcme/ledger", "",
]

private let batchNames = ["acme/flagship", "acme/ledger", "robin-k/dotkit"]

/// Long enough for a poll that a batch add queues after `done` to reach `send`.
private func grace() async { try? await Task.sleep(nanoseconds: 300_000_000) }

@MainActor
@Suite struct BoardModelIssueSetupTests {
  private func model(
    known repos: [KnownRepo]?, sources: [IssueSource]? = [], sessions: [SessionSummary] = []
  ) -> BoardModel {
    let model = appliedModel(sessions)
    model.knownRepos = repos
    model.issueList = sources.map(sourceList)
    return model
  }

  // MARK: - Offered known repos

  @Test func offersEachValidKnownRepo() {
    let model = model(known: [known("robin-k/dotkit"), known("acme/ledger")])

    #expect(model.offeredIssueRepos.sorted() == ["acme/ledger", "robin-k/dotkit"])
  }

  @Test(arguments: invalidRepoNames)
  func doesNotOfferAKnownRepoThatIsNotOwnerAndName(name: String) {
    let model = model(known: [known(name, at: "/dev/bad"), known("acme/ledger")])

    #expect(model.offeredIssueRepos == ["acme/ledger"])
  }

  @Test(arguments: [
    IssueSource(name: "acme/ledger"),
    IssueSource(name: "ACME/Ledger"),
    IssueSource(name: "acme/ledger", label: "bug"),
    IssueSource(name: "acme/ledger", person: "robin-k"),
  ])
  func doesNotOfferARepoThatIsAlreadyASource(source: IssueSource) {
    let model = model(known: [known("Acme/ledger"), known("robin-k/dotkit")], sources: [source])

    #expect(model.offeredIssueRepos == ["robin-k/dotkit"])
  }

  @Test func anOrgSourceDoesNotHideItsRepos() {
    let model = model(known: [known("acme/ledger")], sources: [IssueSource(name: "acme", label: "team/billing")])

    #expect(model.offeredIssueRepos == ["acme/ledger"])
  }

  @Test(arguments: ["acme/ledger", "ACME/Ledger"])
  func twoCheckoutsOfOneRepoAreOfferedOnce(second: String) {
    let model = model(known: [known("acme/ledger", at: "/dev/ledger"), known(second, at: "/work/ledger")])

    #expect(model.offeredIssueRepos == ["acme/ledger"])
  }

  @Test func noKnownReposOffersNothing() {
    #expect(model(known: nil).offeredIssueRepos.isEmpty)
  }

  @Test func offersKnownReposBeforeTheIssueListLoads() {
    let model = model(known: [known("acme/ledger")], sources: nil)

    #expect(model.offeredIssueRepos == ["acme/ledger"])
  }

  // MARK: - Suggested sources

  @Test func suggestsAKnownRepoAndItsOrgWithoutSessions() {
    let model = model(known: [known("acme/ledger")])

    #expect(model.suggestedIssueSources == ["acme", "acme/ledger"])
  }

  @Test func suggestsTheOrgsThenTheReposOfSessionsAndKnownRepos() {
    let model = model(known: [known("acme/ledger")], sessions: [orgSession("s1", "robin-k/dotkit")])

    #expect(model.suggestedIssueSources == ["acme", "robin-k", "acme/ledger", "robin-k/dotkit"])
  }

  @Test func aRepoInBothASessionAndKnownReposIsSuggestedOnceWithItsOrgOnce() {
    let model = model(known: [known("acme/ledger")], sessions: [orgSession("s1", "Acme/Ledger")])

    #expect(model.suggestedIssueSources.map { $0.lowercased() } == ["acme", "acme/ledger"])
  }

  @Test(arguments: invalidRepoNames)
  func aKnownRepoThatIsNotOwnerAndNameSuggestsNeitherARepoNorAnOrg(name: String) {
    let model = model(known: [known(name)])

    #expect(model.suggestedIssueSources.isEmpty)
  }

  @Test func doesNotSuggestExistingSourcesWhateverTheirCase() {
    let model = model(
      known: [known("acme/ledger")],
      sources: [IssueSource(name: "ACME", label: "bug"), IssueSource(name: "Acme/Ledger")],
      sessions: [orgSession("s1", "acme/ledger")])

    #expect(model.suggestedIssueSources.isEmpty)
  }

  // MARK: - Adding sources

  @Test func addsEverySourceWithTheSharedFiltersInOneRequest() async {
    let sent = await firstRequest { model in
      model.addIssueSources(batchNames, label: "team/billing", person: "") { _ in }
    }

    #expect(sent.op == "issues-source-add")
    #expect(
      sent.args["sources"]
        == .array(batchNames.map { ["source": .string($0), "label": "team/billing", "person": ""] }))
  }

  @Test func pollsOnceAfterTheSourcesAreAdded() async {
    let (model, sent) = recordingModel()
    var refusal: String?? = nil
    model.addIssueSources(batchNames, label: "", person: "") { refusal = .some($0) }
    await sent.wait(for: "issues-refresh")
    await grace()

    #expect(refusal == .some(nil))
    #expect(sent.ops == ["issues-source-add", "issues-refresh"])
    #expect(sent.value.last?.args == ["maxAgeSeconds": 0])
  }

  @Test func aRefusalReachesDoneAndStartsNoPoll() async {
    let (model, sent) = recordingModel { op, _ in op == "issues-source-add" ? "acme/ledger is already a source" : nil }
    var refusal: String?? = nil
    model.addIssueSources(batchNames, label: "", person: "") { refusal = .some($0) }
    await settle { refusal != nil }
    await grace()

    #expect(refusal == .some("acme/ledger is already a source"))
    #expect(sent.ops == ["issues-source-add"])
  }
}
