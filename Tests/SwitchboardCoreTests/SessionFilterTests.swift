import Testing

@testable import SwitchboardCore

private func session(
  _ id: String, repository: String? = nil, read: Bool? = true, group: String? = nil, kind: SessionKind = .work,
  chat: String? = nil
) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: id, cwd: "/tmp/\(id)", repo: nil, branch: nil, claudeSessionId: id, state: .working, reason: "",
    since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
  s.repository = repository
  s.repositoryRead = read
  s.group = group
  s.kind = kind
  switch kind {
  case .manager, .operator: s.manager = true
  case .chat: s.chat = chat
  case .work: break
  }
  return s
}

private func group(_ id: String, _ name: String) -> GroupSummary {
  GroupSummary(SessionGroup(id: id, name: name, created: 0), sessions: [])
}

private let ungrouped = GroupFilter.ungroupedKey
private let known: Set<String> = ["g1", "g2"]

/// A PostHog session in g1, a haacked one in g1, a PostHog one in g2, a PostHog one in no group, a Local one in g2,
/// an unread one in g1, the chat of g1, the chat of g2, and the Manager.
private let phG1 = session("ph-g1", repository: "PostHog/a", group: "g1")
private let hkG1 = session("hk-g1", repository: "haacked/a", group: "g1")
private let phG2 = session("ph-g2", repository: "PostHog/b", group: "g2")
private let phNone = session("ph-none", repository: "PostHog/c")
private let loG2 = session("lo-g2", group: "g2")
private let unG1 = session("un-g1", read: nil, group: "g1")
private let chatG1 = session("c1", kind: .chat, chat: "g1")
private let chatG2 = session("c2", kind: .chat, chat: "g2")
private let manager = session("m", repository: "PostHog/posthog", kind: .manager)
private let everySession = [phG1, hkG1, phG2, phNone, loG2, unG1, chatG1, chatG2, manager]

@Suite struct SessionFilterTests {
  func filter(_ org: [String] = [], _ group: [String] = [], known: Set<String>? = known) -> SessionFilter {
    SessionFilter(org: OrgFilter(keys: org), group: GroupFilter(keys: group), knownGroups: known)
  }

  // MARK: shows

  struct ShowsCase: Sendable, CustomTestStringConvertible {
    var org: [String]
    var group: [String]
    var shown: Set<String>
    var testDescription: String {
      "org \(org.isEmpty ? "All" : org.joined(separator: ",")) × group \(group.isEmpty ? "All" : group.joined(separator: ","))"
    }
  }

  @Test(arguments: [
    ShowsCase(org: [], group: [], shown: Set(everySession.map(\.id))),
    ShowsCase(org: ["posthog"], group: [], shown: ["ph-g1", "ph-g2", "ph-none", "un-g1", "c1", "c2", "m"]),
    ShowsCase(org: [], group: ["g1"], shown: ["ph-g1", "hk-g1", "un-g1", "c1", "m"]),
    ShowsCase(org: ["posthog"], group: ["g1"], shown: ["ph-g1", "un-g1", "c1", "m"]),
    ShowsCase(org: ["haacked"], group: ["g2"], shown: ["c2", "m"]),
    ShowsCase(org: [OrgFilter.localKey], group: ["g2"], shown: ["lo-g2", "c2", "m"]),
    ShowsCase(org: ["posthog"], group: [ungrouped], shown: ["ph-none", "m"]),
    ShowsCase(
      org: ["posthog", OrgFilter.localKey], group: ["g2", ungrouped], shown: ["ph-g2", "ph-none", "lo-g2", "c2", "m"]),
    ShowsCase(org: ["acme"], group: ["g1"], shown: ["un-g1", "c1", "m"]),
  ])
  func aSessionShowsOnlyWhenBothFiltersShowIt(_ c: ShowsCase) {
    let f = filter(c.org, c.group)

    let shown = Set(everySession.filter(f.shows).map(\.id))

    #expect(shown == c.shown)
  }

  @Test(
    arguments: [[], ["posthog"], ["haacked", OrgFilter.localKey]] as [[String]],
    [[], ["g1"], [ungrouped], ["g2", ungrouped]] as [[String]])
  func showsIsTheAndOfEachDimension(_ org: [String], _ group: [String]) {
    let f = filter(org, group)

    for s in everySession {
      #expect(
        f.shows(s) == (OrgFilter(keys: org).shows(s) && GroupFilter(keys: group).shows(s, known: known)), "\(s.id)")
    }
  }

  @Test func theManagerShowsUnderEveryCombination() {
    for org in [[], ["acme"]] as [[String]] {
      for group in [[], ["gx"], [ungrouped]] as [[String]] {
        #expect(filter(org, group).shows(manager))
        #expect(filter(org, group, known: nil).shows(manager))
      }
    }
  }

  // MARK: isAll and scope

  @Test func isAllOnlyWhenBothFiltersAreAll() {
    #expect(filter().isAll)
    #expect(filter(known: nil).isAll)
    #expect(!filter(["posthog"]).isAll)
    #expect(!filter([], ["g1"]).isAll)
    #expect(!filter(["posthog"], ["g1"]).isAll)
  }

  @Test func scopeNamesTheDimensionsThatAreOn() {
    #expect(filter().scope == nil)
    #expect(filter(["posthog"]).scope == .orgs)
    #expect(filter([], ["g1"]).scope == .groups)
    #expect(filter([], [ungrouped]).scope == .groups)
    #expect(filter(["posthog"], ["g1"]).scope == .both)
  }

  // MARK: label

  static let orgSessions = [
    session("p", repository: "PostHog/p"), session("z", repository: "zed/z"), session("l"),
  ]
  static let groups = [group("g1", "Infra"), group("g2", "Web"), group("g3", "Docs")]
  static let groupSessions = [session("a", group: "g1"), session("b", group: "g2"), session("u")]

  func label(_ org: [String], _ group: [String]) -> String {
    let f = filter(org, group, known: ["g1", "g2", "g3"])
    let orgEntries = f.org.entries(Self.orgSessions)
    let groupEntries = f.group.entries(Self.groupSessions, groups: Self.groups, known: ["g1", "g2", "g3"])
    return f.label(orgEntries: orgEntries, groupEntries: groupEntries)
  }

  @Test(arguments: [
    ([] as [String], [] as [String], "All Sessions"),
    (["posthog"], [], "PostHog"),
    (["posthog", OrgFilter.localKey], [], "PostHog, Local"),
    (["posthog", "zed", OrgFilter.localKey], [], "PostHog +2"),
    ([], ["g1"], "Infra"),
    ([], ["g1", ungrouped], "Infra, Ungrouped"),
    ([], ["g1", "g2", "g3"], "Infra +2"),
    (["posthog"], ["g1"], "PostHog · Infra"),
    (["posthog"], ["g1", "g2"], "PostHog · Infra +1"),
    (["posthog", OrgFilter.localKey], ["g1"], "PostHog +1 · Infra"),
    (["posthog", "zed", OrgFilter.localKey], ["g1", "g2", ungrouped], "PostHog +2 · Infra +2"),
  ])
  func labelNamesBothSelections(_ org: [String], _ group: [String], _ expected: String) {
    #expect(label(org, group) == expected)
  }

  // MARK: surelyShows

  @Test func aGroupFilterBeforeGroupsLoadSurelyShowsNothing() {
    let f = filter([], ["g1"], known: nil)

    #expect(f.shows(phG1))
    #expect(!f.surelyShows(phG1))
    #expect(everySession.allSatisfy { !f.surelyShows($0) })
  }

  @Test func aGroupFilterAfterGroupsLoadSurelyShowsWhatItShows() {
    let f = filter([], ["g1"])

    #expect(everySession.filter(f.surelyShows).map(\.id) == everySession.filter(f.shows).map(\.id))
  }

  @Test func allGroupsBeforeGroupsLoadSurelyShowsEverySession() {
    let f = filter([], [], known: nil)

    #expect(everySession.allSatisfy(f.surelyShows))
  }

  @Test func anUnreadOrgIsNotSurelyShownUnderAnOrgFilterEvenWhenTheGroupMatches() {
    let f = filter(["posthog"], ["g1"])

    #expect(f.shows(unG1))
    #expect(!f.surelyShows(unG1))
    #expect(f.surelyShows(phG1))
  }

  @Test(arguments: [[], ["posthog"]] as [[String]], [[], ["g1"], [ungrouped]] as [[String]])
  func surelyShownSessionsAreAlwaysShown(_ org: [String], _ group: [String]) {
    for k in [known, nil] as [Set<String>?] {
      let f = filter(org, group, known: k)

      #expect(everySession.filter(f.surelyShows).allSatisfy(f.shows))
    }
  }
}
