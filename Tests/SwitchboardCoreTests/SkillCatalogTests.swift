import Foundation
import Testing

@testable import SwitchboardCore

private func write(_ text: String, to path: String) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try text.write(toFile: path, atomically: true, encoding: .utf8)
}

private func skillFile(_ name: String, _ flags: String...) -> String {
  (["---", "name: \(name)", "description: The \(name) skill."] + flags + ["---", "Say hi.", ""])
    .joined(separator: "\n")
}

private func listed(_ name: String, _ description: String? = nil) -> SlashCommand {
  SlashCommand(name: name, description: description, source: .listing)
}

/// A temporary account folder, a cwd, and a folder that plugins install into.
private struct Folders {
  let root: String
  var account: String { "\(root)/account" }
  var cwd: String { "\(root)/manager" }
  var plugins: String { "\(root)/plugin-cache" }

  init() throws {
    root = try tempFolder()
    for folder in [account, cwd, plugins] {
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }
  }

  func remove() { try? FileManager.default.removeItem(atPath: root) }

  func discover(listing: [SlashCommand]? = nil) -> [String: CatalogEntry] {
    SkillCatalog.discover(account: account, cwd: cwd, listing: listing, machine: LocalMachine())
  }

  func accountSkill(_ name: String, _ text: String? = nil) throws {
    try write(text ?? skillFile(name), to: "\(account)/skills/\(name)/SKILL.md")
  }

  func cwdSkill(_ name: String) throws {
    try write(skillFile(name), to: "\(cwd)/.claude/skills/\(name)/SKILL.md")
  }

  /// A plugin `<plugin>@market` whose install folder holds the skills and the commands. It returns that folder.
  @discardableResult
  func installPlugin(_ plugin: String, skills: [String] = [], commands: [String] = []) throws -> String {
    let path = "\(plugins)/\(plugin)/1.0.0"
    for skill in skills { try write(skillFile(skill), to: "\(path)/skills/\(skill)/SKILL.md") }
    for command in commands { try write("The \(command) command.\n", to: "\(path)/commands/\(command).md") }
    return path
  }

  /// Writes installed_plugins.json with one install of each plugin.
  func registerPlugins(version: JSON = 2, _ installs: [String: JSON]) throws {
    let plugins = JSON.object(installs.mapValues { JSON.array([$0]) })
    try write(
      JSON.object(["version": version, "plugins": plugins]).text, to: "\(account)/plugins/installed_plugins.json")
  }

  func settings(_ json: JSON) throws { try write(json.text, to: "\(account)/settings.json") }

  func enable(_ plugins: String...) throws {
    try settings(["enabledPlugins": .object(Dictionary(uniqueKeysWithValues: plugins.map { ($0, JSON.bool(true)) }))])
  }
}

private func userInstall(_ path: String) -> JSON { ["scope": "user", "installPath": .string(path)] }

@Suite struct SkillCatalogTests {
  // MARK: Skill and command folders

  @Test func userSkillIsFoundWithItsPathAndTheUserOrigin() throws {
    let f = try Folders()
    defer { f.remove() }
    try f.accountSkill("go")

    let entry = try #require(f.discover()["go"])

    #expect(entry.name == "go")
    #expect(entry.origin == .user)
    #expect(entry.path == "\(f.account)/skills/go/SKILL.md")
    #expect(entry.hash != nil)
  }

  @Test func cwdSkillIsFoundWithTheProjectOrigin() throws {
    let f = try Folders()
    defer { f.remove() }
    try f.cwdSkill("go")

    let entry = try #require(f.discover()["go"])

    #expect(entry.origin == .project)
    #expect(entry.path == "\(f.cwd)/.claude/skills/go/SKILL.md")
  }

  @Test(arguments: [true, false])
  func commandFileIsFoundWithTheCommandOrigin(_ inAccount: Bool) throws {
    let f = try Folders()
    defer { f.remove() }
    let path = inAccount ? "\(f.account)/commands/ship.md" : "\(f.cwd)/.claude/commands/ship.md"
    try write("Ships it.\n", to: path)

    let entry = try #require(f.discover()["ship"])

    #expect(entry.origin == .command)
    #expect(entry.path == path)
    #expect(entry.hash != nil)
  }

  @Test func userSkillBeatsACwdSkillOfTheSameName() throws {
    let f = try Folders()
    defer { f.remove() }
    try f.cwdSkill("go")
    try f.accountSkill("go")

    let entry = try #require(f.discover()["go"])

    #expect(entry.origin == .user)
    #expect(entry.path == "\(f.account)/skills/go/SKILL.md")
  }

  @Test func cwdSkillBeatsAnAccountCommandOfTheSameName() throws {
    let f = try Folders()
    defer { f.remove() }
    try write("Account command.\n", to: "\(f.account)/commands/go.md")
    try f.cwdSkill("go")

    let entry = try #require(f.discover()["go"])

    #expect(entry.origin == .project)
    #expect(entry.path == "\(f.cwd)/.claude/skills/go/SKILL.md")
  }

  @Test func accountCommandBeatsACwdCommandOfTheSameName() throws {
    let f = try Folders()
    defer { f.remove() }
    try write("Repo command.\n", to: "\(f.cwd)/.claude/commands/ship.md")
    try write("Account command.\n", to: "\(f.account)/commands/ship.md")

    #expect(f.discover()["ship"]?.path == "\(f.account)/commands/ship.md")
  }

  @Test func skillNamedInItsFrontmatterIsFoundByThatName() throws {
    let f = try Folders()
    defer { f.remove() }
    try write(skillFile("real-name"), to: "\(f.account)/skills/folder-name/SKILL.md")

    let entries = f.discover()

    #expect(entries["real-name"]?.path == "\(f.account)/skills/folder-name/SKILL.md")
    #expect(entries["folder-name"] == nil)
  }

  @Test func eachEntryIsKeyedByItsOwnName() throws {
    let f = try Folders()
    defer { f.remove() }
    try f.accountSkill("go")
    try f.cwdSkill("note")
    try write("Ships it.\n", to: "\(f.account)/commands/ship.md")

    let entries = f.discover()

    #expect(Set(entries.keys) == ["go", "note", "ship"])
    #expect(entries.allSatisfy { $0.key == $0.value.name })
  }

  @Test func skillThatSkillOverridesTurnsOffIsDropped() throws {
    let f = try Folders()
    defer { f.remove() }
    try f.accountSkill("go")
    try f.accountSkill("note")
    try f.settings(["skillOverrides": ["go": "off"]])

    let entries = f.discover()

    #expect(entries["go"] == nil)
    #expect(entries["note"] != nil)
  }

  @Test(arguments: ["user-invocable-only", "on"])
  func anOverrideOtherThanOffKeepsTheSkill(_ state: String) throws {
    let f = try Folders()
    defer { f.remove() }
    try f.accountSkill("go")
    try f.settings(["skillOverrides": ["go": .string(state)]])

    #expect(f.discover()["go"] != nil)
  }

  /// One of the two load paths, typing or the Skill tool, still reaches each of these.
  @Test(arguments: ["user-invocable: false", "disable-model-invocation: true"])
  func aSkillThatOneLoadPathCannotReachIsKept(_ flag: String) throws {
    let f = try Folders()
    defer { f.remove() }
    try f.accountSkill("go", skillFile("go", flag))

    #expect(f.discover()["go"]?.origin == .user)
  }

  @Test(.timeLimit(.minutes(1))) func skillLinkedToDevZeroIsStillFound() throws {
    let f = try Folders()
    defer { f.remove() }
    try FileManager.default.createDirectory(atPath: "\(f.account)/skills/zero", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: "\(f.account)/skills/zero/SKILL.md", withDestinationPath: "/dev/zero")

    let entry = try #require(f.discover()["zero"])

    #expect(entry.path == "\(f.account)/skills/zero/SKILL.md")
  }

  @Test func emptyFoldersFindNothing() throws {
    let f = try Folders()
    defer { f.remove() }

    #expect(f.discover().isEmpty)
  }

  @Test func missingAccountFolderFindsTheCwdSkills() throws {
    let f = try Folders()
    defer { f.remove() }
    try f.cwdSkill("go")
    try FileManager.default.removeItem(atPath: f.account)

    #expect(f.discover()["go"]?.origin == .project)
  }

  // MARK: Plugins

  @Test func pluginEnabledInSettingsAddsItsSkillsAndCommandsUnderItsName() throws {
    let f = try Folders()
    defer { f.remove() }
    let path = try f.installPlugin("tools", skills: ["review"], commands: ["deploy"])
    try f.registerPlugins(["tools@market": userInstall(path)])
    try f.enable("tools@market")

    let entries = f.discover()

    let skill = try #require(entries["tools:review"])
    #expect(skill.origin == .plugin)
    #expect(skill.path == "\(path)/skills/review/SKILL.md")
    #expect(skill.hash != nil)
    let command = try #require(entries["tools:deploy"])
    #expect(command.origin == .plugin)
    #expect(command.path == "\(path)/commands/deploy.md")
    #expect(entries["review"] == nil)
    #expect(entries["deploy"] == nil)
  }

  @Test func pluginSkillTakesItsFrontmatterName() throws {
    let f = try Folders()
    defer { f.remove() }
    let path = "\(f.plugins)/tools/1.0.0"
    try write(skillFile("real"), to: "\(path)/skills/folder/SKILL.md")
    try f.registerPlugins(["tools@market": userInstall(path)])
    try f.enable("tools@market")

    let entries = f.discover()

    #expect(entries["tools:real"]?.path == "\(path)/skills/folder/SKILL.md")
    #expect(entries["tools:folder"] == nil)
  }

  /// The listing leaves out a skill that the model can't call. So `slash-commands` reads each plugin skill's flags.
  @Test func pluginSkillsKeepTheirFlagsUnderThePluginsName() throws {
    let f = try Folders()
    defer { f.remove() }
    let path = "\(f.plugins)/tools/1.0.0"
    try write(skillFile("ship", "disable-model-invocation: true"), to: "\(path)/skills/ship/SKILL.md")
    try write(skillFile("hidden", "user-invocable: false"), to: "\(path)/skills/hidden/SKILL.md")
    try write("The deploy command.\n", to: "\(path)/commands/deploy.md")
    try f.registerPlugins(["tools@market": userInstall(path)])
    try f.enable("tools@market")

    let skills = SkillCatalog.pluginSkills(account: f.account, cwd: f.cwd, listing: nil, machine: LocalMachine())

    #expect(skills.map(\.name) == ["tools:hidden", "tools:ship", "tools:deploy"])
    let ship = try #require(skills.first { $0.name == "tools:ship" })
    #expect(!ship.modelInvocable)
    #expect(ship.userInvocable)
    #expect(ship.path == "\(path)/skills/ship/SKILL.md")
    #expect(skills.first { $0.name == "tools:hidden" }?.userInvocable == false)
  }

  @Test func pluginEnabledOnlyThroughAListingNameAddsAllItsSkills() throws {
    let f = try Folders()
    defer { f.remove() }
    let path = try f.installPlugin("tools", skills: ["review", "lint"])
    try f.registerPlugins(["tools@market": userInstall(path)])

    let entries = f.discover(listing: [listed("tools:review", "Reviews code.")])

    #expect(entries["tools:review"]?.origin == .plugin)
    #expect(entries["tools:review"]?.path == "\(path)/skills/review/SKILL.md")
    #expect(entries["tools:lint"]?.origin == .plugin)
  }

  @Test(arguments: [JSON.object(["enabledPlugins": ["tools@market": false]]), JSON.object([:])])
  func pluginThatIsNotEnabledAddsNothing(_ settings: JSON) throws {
    let f = try Folders()
    defer { f.remove() }
    let path = try f.installPlugin("tools", skills: ["review"], commands: ["deploy"])
    try f.registerPlugins(["tools@market": userInstall(path)])
    try f.settings(settings)

    let entries = f.discover(listing: [listed("other:thing", "Another plugin's skill.")])

    #expect(entries.keys.filter { $0.hasPrefix("tools:") }.isEmpty)
  }

  @Test func pluginEnabledUnderAnotherMarketplaceAddsNothing() throws {
    let f = try Folders()
    defer { f.remove() }
    let path = try f.installPlugin("tools", skills: ["review"])
    try f.registerPlugins(["tools@market": userInstall(path)])
    try f.enable("tools@elsewhere")

    #expect(f.discover()["tools:review"] == nil)
  }

  @Test func projectScopePluginForAnotherPathAddsNothing() throws {
    let f = try Folders()
    defer { f.remove() }
    let path = try f.installPlugin("tools", skills: ["review"])
    try f.registerPlugins([
      "tools@market": ["scope": "project", "installPath": .string(path), "projectPath": "/somewhere/else"]
    ])
    try f.enable("tools@market")

    #expect(f.discover()["tools:review"] == nil)
  }

  @Test func projectScopePluginForTheCwdAddsItsSkills() throws {
    let f = try Folders()
    defer { f.remove() }
    let path = try f.installPlugin("tools", skills: ["review"])
    try f.registerPlugins([
      "tools@market": ["scope": "project", "installPath": .string(path), "projectPath": .string(f.cwd)]
    ])
    try f.enable("tools@market")

    #expect(f.discover()["tools:review"]?.origin == .plugin)
  }

  @Test(arguments: ["plugin-cache/tools/1.0.0", "./plugin-cache/tools/1.0.0", "~/plugin-cache/tools/1.0.0", ""])
  func pluginWithAnInstallPathThatIsNotAbsoluteIsSkipped(_ installPath: String) throws {
    let f = try Folders()
    defer { f.remove() }
    try f.installPlugin("tools", skills: ["review"])
    try f.registerPlugins(["tools@market": userInstall(installPath)])
    try f.enable("tools@market")

    #expect(f.discover()["tools:review"] == nil)
  }

  @Test(arguments: [JSON.number(1), 3, "2", .null])
  func pluginFileOfAnotherVersionIsSkipped(_ version: JSON) throws {
    let f = try Folders()
    defer { f.remove() }
    let path = try f.installPlugin("tools", skills: ["review"])
    try f.registerPlugins(version: version, ["tools@market": userInstall(path)])
    try f.enable("tools@market")
    try f.accountSkill("go")

    let entries = f.discover()

    #expect(entries["tools:review"] == nil)
    #expect(entries["go"] != nil)
  }

  @Test func corruptPluginFileSkipsPluginsAndKeepsTheRest() throws {
    let f = try Folders()
    defer { f.remove() }
    try write("{not json", to: "\(f.account)/plugins/installed_plugins.json")
    try f.accountSkill("go")

    #expect(Set(f.discover().keys) == ["go"])
  }

  @Test func userSkillBeatsAPluginEntryOfTheSameName() throws {
    let f = try Folders()
    defer { f.remove() }
    try f.accountSkill("tools:review", skillFile("tools:review"))
    let path = try f.installPlugin("tools", skills: ["review"])
    try f.registerPlugins(["tools@market": userInstall(path)])
    try f.enable("tools@market")

    #expect(f.discover()["tools:review"]?.origin == .user)
  }

  @Test func pluginSkillThatSkillOverridesTurnsOffIsDropped() throws {
    let f = try Folders()
    defer { f.remove() }
    let path = try f.installPlugin("tools", skills: ["review", "lint"])
    try f.registerPlugins(["tools@market": userInstall(path)])
    try f.settings(["enabledPlugins": ["tools@market": true], "skillOverrides": ["tools:review": "off"]])

    let entries = f.discover()

    #expect(entries["tools:review"] == nil)
    #expect(entries["tools:lint"] != nil)
  }

  // MARK: Listing-only names

  @Test func listingOnlyBundledSkillIsFoundFromItsDescription() throws {
    let f = try Folders()
    defer { f.remove() }

    let entry = try #require(f.discover(listing: [listed("code-review", "Reviews the diff.")])["code-review"])

    #expect(entry.origin == .listing)
    #expect(entry.path == nil)
    #expect(entry.description == "Reviews the diff.")
    #expect(entry.hash == SkillHash.listing(name: "code-review", description: "Reviews the diff."))
  }

  /// With neither a file nor a description, nothing can be classified, so the entry has no hash and stays
  /// unlabeled.
  @Test func listingOnlyNameWithoutADescriptionHasNoHash() throws {
    let f = try Folders()
    defer { f.remove() }

    let entry = try #require(f.discover(listing: [listed("mystery")])["mystery"])

    #expect(entry.origin == .listing)
    #expect(entry.path == nil)
    #expect(entry.hash == nil)
  }

  @Test func listingNameThatAFileHoldsKeepsTheFileEntry() throws {
    let f = try Folders()
    defer { f.remove() }
    try f.accountSkill("go")

    let entry = try #require(f.discover(listing: [listed("go", "A different description.")])["go"])

    #expect(entry.origin == .user)
    #expect(entry.path == "\(f.account)/skills/go/SKILL.md")
  }

  @Test func listingNameThatAPluginHoldsKeepsThePluginEntry() throws {
    let f = try Folders()
    defer { f.remove() }
    let path = try f.installPlugin("tools", skills: ["review"])
    try f.registerPlugins(["tools@market": userInstall(path)])

    let entry = try #require(f.discover(listing: [listed("tools:review", "Reviews code.")])["tools:review"])

    #expect(entry.origin == .plugin)
    #expect(entry.path == "\(path)/skills/review/SKILL.md")
  }

  @Test func listingOnlyNameThatSkillOverridesTurnsOffIsDropped() throws {
    let f = try Folders()
    defer { f.remove() }
    try f.settings(["skillOverrides": ["code-review": "off"]])

    #expect(f.discover(listing: [listed("code-review", "Reviews the diff.")])["code-review"] == nil)
  }

  @Test func noListingFindsOnlyFiles() throws {
    let f = try Folders()
    defer { f.remove() }
    try f.accountSkill("go")

    #expect(Set(f.discover(listing: nil).keys) == ["go"])
  }
}
