import Foundation
import SwitchboardCore
import Testing

/// A group's links: `sb group link add` and `sb group link rm`, the
/// `group-link-add` and `group-link-rm` requests, and how `sb group ls`, a
/// restart, and a merge treat them. Only the user adds or removes a link.
@Suite(.blocking(timeLimit: .seconds(120))) struct GroupLinkTests {
  let shared = GroupTests()

  static let rfc = "https://example.com/rfcs/flag-evaluations"
  static let doc = "https://example.com/docs/cache-design"

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  func linkAdd(_ sbd: Instance, _ group: String, _ url: String, title: String? = nil) throws -> GroupSummary {
    let flag = title.map { ["--title", $0] } ?? []
    return try decode(GroupSummary.self, sbd.sb(["group", "link", "add", "--json", group, url] + flag))
  }

  func linkRm(_ sbd: Instance, _ group: String, _ link: String) throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb("group", "link", "rm", "--json", group, link))
  }

  func listed(_ sbd: Instance, _ id: String) throws -> GroupSummary {
    try #require(try shared.list(sbd).groups.first { $0.id == id })
  }

  func links(_ sbd: Instance, _ id: String) throws -> [GroupLink] { try listed(sbd, id).links ?? [] }

  /// The one link of the group that has `url`.
  func link(_ g: GroupSummary, _ url: String) throws -> GroupLink {
    try #require(g.links?.first { $0.url == url })
  }

  // MARK: add

  @Test func aNewGroupHasNoLinks() throws {
    let sbd = try Instance()

    let g = try shared.add(sbd, "Flags")

    #expect((g.links ?? []).isEmpty)
  }

  @Test func addWithoutATitleUsesTheURL() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    let linked = try linkAdd(sbd, "Flags", Self.rfc)

    let added = try link(linked, Self.rfc)
    #expect(added.title == Self.rfc)
    #expect(try links(sbd, g.id).map(\.title) == [Self.rfc])
  }

  @Test func addWithATitleKeepsIt() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    let linked = try linkAdd(sbd, "Flags", Self.rfc, title: "Flag evaluations RFC")

    #expect(try link(linked, Self.rfc).title == "Flag evaluations RFC")
    #expect(try links(sbd, g.id).map(\.title) == ["Flag evaluations RFC"])
  }

  @Test func aLinkIsByYouAndStampedWithWhenItWasAdded() throws {
    let sbd = try Instance()
    _ = try shared.add(sbd, "Flags")
    let start = try sbd.now()

    let added = try link(try linkAdd(sbd, "Flags", Self.rfc), Self.rfc)

    #expect(added.by == .you)
    #expect(added.t >= start)
    #expect(!added.id.isEmpty)
  }

  @Test(arguments: ["Design\ndoc", "Design\r\ndoc", "Design \t doc", "Design\u{2028}doc", "  Design   doc  "])
  func aTitleIsKeptOnOneLine(_ title: String) throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    _ = try linkAdd(sbd, "Flags", Self.rfc, title: title)

    #expect(try links(sbd, g.id).map(\.title) == ["Design doc"])
  }

  @Test func linksKeepTheOrderTheyWereAddedIn() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    _ = try linkAdd(sbd, "Flags", Self.rfc)
    _ = try linkAdd(sbd, "Flags", Self.doc)

    #expect(try links(sbd, g.id).map(\.url) == [Self.rfc, Self.doc])
  }

  @Test func addFindsTheGroupByItsId() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    _ = try linkAdd(sbd, g.id, Self.rfc)

    #expect(try links(sbd, g.id).map(\.url) == [Self.rfc])
  }

  @Test func addPrintsTheGroup() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    let text = try sbd.sb("group", "link", "add", "Flags", Self.rfc, "--title", "Flag evaluations RFC")

    #expect(text.contains(g.id))
    #expect(text.contains("Flags"))
    #expect(text.contains(Self.rfc))
  }

  @Test func theJSONOfAddIsTheGroupAsLsListsIt() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    let linked = try linkAdd(sbd, "Flags", Self.rfc, title: "RFC")

    #expect(try listed(sbd, g.id) == linked)
  }

  @Test func addLeavesTheDescriptionAndNotesAlone() throws {
    let sbd = try Instance()
    let g = try decode(
      GroupSummary.self,
      sbd.sb("group", "add", "--json", "Flags", "--description", "Ship the cache.", "--note", "Ask Ana first."))

    _ = try linkAdd(sbd, "Flags", Self.rfc)

    let after = try listed(sbd, g.id)
    #expect(after.description == "Ship the cache.")
    #expect(after.notes.map(\.text) == ["Ask Ana first."])
  }

  // MARK: Refusals of add

  @Test func aDuplicateURLInTheSameGroupIsRefused() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    _ = try linkAdd(sbd, "Flags", Self.rfc, title: "First")

    let r = try sbd.run(["group", "link", "add", "--json", "Flags", Self.rfc, "--title", "Second"])

    #expect(r.status != 0)
    #expect(try links(sbd, g.id).map(\.title) == ["First"])
  }

  @Test func theSameURLInAnotherGroupIsAdded() throws {
    let sbd = try Instance()
    _ = try shared.add(sbd, "Flags")
    let billing = try shared.add(sbd, "Billing")
    _ = try linkAdd(sbd, "Flags", Self.rfc)

    _ = try linkAdd(sbd, "Billing", Self.rfc)

    #expect(try links(sbd, billing.id).map(\.url) == [Self.rfc])
  }

  @Test func addToAGroupItCantFindIsRefused() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    let r = try sbd.run(["group", "link", "add", "--json", "Nowhere", Self.rfc])

    #expect(r.status != 0)
    #expect(try links(sbd, g.id).isEmpty)
  }

  /// URLs that are not http or https, have no scheme or host, or hold whitespace.
  static let refusedURLs = [
    "ftp://example.com/file", "file:///etc/passwd", "javascript:alert(1)", "mailto:ana@example.com",
    "data:text/html,hi", "ssh://git@github.com/o/r", "httpx://example.com", "example.com", "www.example.com/rfcs",
    "//example.com/rfcs", "/rfcs/flag-evaluations", "", "https://exa mple.com", "https://example.com/a\tb",
    "https://example.com\nhttps://evil.example", "https://example.com/a\u{00A0}b", "https://", "https:///rfcs",
  ]

  @Test(arguments: refusedURLs) func aURLThatIsNotHTTPIsRefused(_ url: String) throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    let message = failure(sbd, "group-link-add", ["group": "Flags", "url": .string(url), "by": "you"])

    #expect(message != "no error", "\(url)")
    #expect(try links(sbd, g.id).isEmpty)
  }

  @Test func theCLIRefusesAURLThatIsNotHTTP() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    let r = try sbd.run(["group", "link", "add", "--json", "Flags", "file:///etc/passwd"])

    #expect(r.status != 0)
    #expect(try links(sbd, g.id).isEmpty)
  }

  @Test(arguments: ["http://example.com", "https://example.com/rfcs/1?draft=2#scope"])
  func anHTTPOrHTTPSURLIsAdded(_ url: String) throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    _ = try linkAdd(sbd, "Flags", url)

    #expect(try links(sbd, g.id).map(\.url) == [url])
  }

  // MARK: Length

  @Test func addTakesATitleOfExactlyTheLimit() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    let title = String(repeating: "a", count: GroupLink.titleLimit)

    _ = try linkAdd(sbd, "Flags", Self.rfc, title: title)

    #expect(try links(sbd, g.id).map(\.title) == [title])
  }

  @Test func addRefusesATitleOneOverTheLimitAndAddsNoLink() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    let title = String(repeating: "a", count: GroupLink.titleLimit + 1)

    let r = try sbd.run(["group", "link", "add", "--json", "Flags", Self.rfc, "--title", title])

    #expect(r.status != 0)
    #expect(r.stderr.contains("\(GroupLink.titleLimit)"))
    #expect(try links(sbd, g.id).isEmpty)
  }

  /// An https URL of exactly `count` characters.
  static func url(ofLength count: Int) -> String {
    let base = "https://example.com/"
    return base + String(repeating: "a", count: count - base.count)
  }

  @Test func addTakesAURLOfExactlyTheLimit() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    let url = Self.url(ofLength: GroupLink.urlLimit)

    _ = try linkAdd(sbd, "Flags", url, title: "Long")

    #expect(try links(sbd, g.id).map(\.url) == [url])
  }

  @Test func addRefusesAURLOneOverTheLimitAndAddsNoLink() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    let url = Self.url(ofLength: GroupLink.urlLimit + 1)

    let message = failure(sbd, "group-link-add", ["group": "Flags", "url": .string(url), "by": "you"])

    #expect(message.contains("\(GroupLink.urlLimit)"))
    #expect(try links(sbd, g.id).isEmpty)
  }

  // MARK: Only the user adds or removes a link

  @Test func aRawAddByClaudeIsRefused() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    let message = failure(sbd, "group-link-add", ["group": "Flags", "url": .string(Self.rfc), "by": "claude"])

    #expect(message != "no error")
    #expect(try links(sbd, g.id).isEmpty)
  }

  @Test func aRawAddByAnUnknownAuthorIsRefused() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")

    let message = failure(sbd, "group-link-add", ["group": "Flags", "url": .string(Self.rfc), "by": "robot"])

    #expect(message != "no error")
    #expect(try links(sbd, g.id).isEmpty)
  }

  @Test func addInsideClaudeFails() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let g = try shared.add(sbd, "Flags")

    let r = try sbd.run(["group", "link", "add", "--json", "Flags", Self.rfc], env: shared.inside(s.id))

    #expect(r.status != 0)
    #expect(try links(sbd, g.id).isEmpty)
  }

  @Test func aRawRmByClaudeIsRefusedAndKeepsTheLink() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    let id = try link(try linkAdd(sbd, "Flags", Self.rfc), Self.rfc).id

    let message = failure(sbd, "group-link-rm", ["group": "Flags", "link": .string(id), "by": "claude"])

    #expect(message != "no error")
    #expect(try links(sbd, g.id).map(\.id) == [id])
  }

  @Test func rmInsideClaudeFailsAndKeepsTheLink() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "alpha")
    let g = try shared.add(sbd, "Flags")
    let id = try link(try linkAdd(sbd, "Flags", Self.rfc), Self.rfc).id

    let r = try sbd.run(["group", "link", "rm", "--json", "Flags", id], env: shared.inside(s.id))

    #expect(r.status != 0)
    #expect(try links(sbd, g.id).map(\.id) == [id])
  }

  // MARK: rm

  @Test func rmRemovesOnlyThatLink() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    let first = try link(try linkAdd(sbd, "Flags", Self.rfc), Self.rfc)
    _ = try linkAdd(sbd, "Flags", Self.doc)

    let removed = try linkRm(sbd, "Flags", first.id)

    #expect(removed.links?.map(\.url) == [Self.doc])
    #expect(try links(sbd, g.id).map(\.url) == [Self.doc])
  }

  @Test func theJSONOfRmIsTheGroupAsLsListsIt() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    let id = try link(try linkAdd(sbd, "Flags", Self.rfc), Self.rfc).id

    let removed = try linkRm(sbd, "Flags", id)

    #expect(try listed(sbd, g.id) == removed)
  }

  @Test func rmPrintsTheGroup() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    let id = try link(try linkAdd(sbd, "Flags", Self.rfc), Self.rfc).id

    let text = try sbd.sb("group", "link", "rm", "Flags", id)

    #expect(text.contains(g.id))
    #expect(!text.contains(Self.rfc))
  }

  @Test func rmOfAnUnknownLinkIsRefusedAndKeepsTheLinks() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    _ = try linkAdd(sbd, "Flags", Self.rfc)

    let r = try sbd.run(["group", "link", "rm", "--json", "Flags", "lnope1"])

    #expect(r.status != 0)
    #expect(try links(sbd, g.id).map(\.url) == [Self.rfc])
  }

  @Test func rmOfAnotherGroupsLinkIsRefusedAndKeepsBoth() throws {
    let sbd = try Instance()
    let flags = try shared.add(sbd, "Flags")
    let billing = try shared.add(sbd, "Billing")
    _ = try linkAdd(sbd, "Flags", Self.rfc)
    let theirs = try link(try linkAdd(sbd, "Billing", Self.doc), Self.doc).id

    let r = try sbd.run(["group", "link", "rm", "--json", "Flags", theirs])

    #expect(r.status != 0)
    #expect(try links(sbd, flags.id).map(\.url) == [Self.rfc])
    #expect(try links(sbd, billing.id).map(\.id) == [theirs])
  }

  @Test func aLinkCanBeAddedAgainAfterItsRemoved() throws {
    let sbd = try Instance()
    let g = try shared.add(sbd, "Flags")
    let id = try link(try linkAdd(sbd, "Flags", Self.rfc), Self.rfc).id
    _ = try linkRm(sbd, "Flags", id)

    _ = try linkAdd(sbd, "Flags", Self.rfc, title: "Again")

    #expect(try links(sbd, g.id).map(\.title) == ["Again"])
  }

  // MARK: ls

  @Test func lsPrintsALinkLineWithTheTitleAndURLOfEachLink() throws {
    let sbd = try Instance()
    _ = try shared.add(sbd, "Flags")
    let rfc = try link(try linkAdd(sbd, "Flags", Self.rfc, title: "Flag evaluations RFC"), Self.rfc)
    let doc = try link(try linkAdd(sbd, "Flags", Self.doc, title: "Cache design"), Self.doc)

    let text = try sbd.sb("group", "ls")

    let lines = text.split(separator: "\n").filter { $0.contains("link:") }
    #expect(lines.count == 2)
    #expect(lines.first?.contains(rfc.id) == true)
    #expect(lines.first?.contains("Flag evaluations RFC") == true)
    #expect(lines.first?.contains(Self.rfc) == true)
    #expect(lines.last?.contains(doc.id) == true)
    #expect(lines.last?.contains("Cache design") == true)
    #expect(lines.last?.contains(Self.doc) == true)
  }

  @Test func lsPrintsTheLinksUnderTheirOwnGroup() throws {
    let sbd = try Instance()
    let a = try sbd.new(name: "alpha")
    let b = try sbd.new(name: "bravo")
    _ = try shared.add(sbd, "Billing", b.id)
    _ = try shared.add(sbd, "Flags", a.id)
    _ = try linkAdd(sbd, "Flags", Self.rfc)

    let text = try sbd.sb("group", "ls")

    let flags = try #require(text.range(of: "Flags"))
    let url = try #require(text.range(of: Self.rfc))
    let billing = try #require(text.range(of: "Billing"))
    #expect(billing.lowerBound < flags.lowerBound)
    #expect(flags.lowerBound < url.lowerBound)
  }

  @Test func lsPrintsNoLinkLineForAGroupWithoutLinks() throws {
    let sbd = try Instance()
    _ = try shared.add(sbd, "Flags")

    let text = try sbd.sb("group", "ls")

    #expect(!text.contains("link:"))
  }

  // MARK: Restart

  @Test func linksSurviveARestartOfSbd() throws {
    let sbd = try Instance()
    let flags = try shared.add(sbd, "Flags")
    let billing = try shared.add(sbd, "Billing")
    _ = try linkAdd(sbd, "Flags", Self.rfc, title: "RFC")
    _ = try linkAdd(sbd, "Flags", Self.doc)
    let gone = try link(try linkAdd(sbd, "Billing", Self.rfc), Self.rfc).id
    _ = try linkRm(sbd, "Billing", gone)
    let before = try shared.list(sbd)

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try shared.list(sbd) == before)
    #expect(try links(sbd, flags.id).map(\.url) == [Self.rfc, Self.doc])
    #expect(try links(sbd, flags.id).map(\.title) == ["RFC", Self.doc])
    #expect(try links(sbd, billing.id).isEmpty)
  }

  // MARK: Merges

  @Test func aMergeKeepsTheSurvivorsLinksThenAddsTheAbsorbedOnesWithoutDuplicates() throws {
    let l = try shared.linkedGroups()
    let other = "https://example.com/docs/readme"
    _ = try linkAdd(l.sbd, "Flags", Self.rfc, title: "Flags RFC")
    _ = try linkAdd(l.sbd, "Docs", other)
    _ = try linkAdd(l.sbd, "Docs", Self.rfc, title: "Docs RFC")
    _ = try linkAdd(l.sbd, "Docs", Self.doc)

    _ = try shared.accept(l.sbd, shared.mergeId(l.flags, l.docs))

    let merged = try links(l.sbd, l.flags.id)
    #expect(merged.map(\.url) == [Self.rfc, other, Self.doc])
    #expect(merged.first?.title == "Flags RFC")
    #expect(Set(merged.map(\.id)).count == merged.count)
  }
}
