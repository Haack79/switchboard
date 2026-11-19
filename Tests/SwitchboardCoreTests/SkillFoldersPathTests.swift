import Foundation
import Testing

@testable import SwitchboardCore

private func write(_ text: String, to path: String) throws {
  try write(Data(text.utf8), to: path)
}

private func write(_ data: Data, to path: String) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try data.write(to: URL(fileURLWithPath: path))
}

private func skillFile(_ name: String) -> String {
  "---\nname: \(name)\ndescription: The \(name) skill.\n---\nSay hi.\n"
}

/// A temporary account folder and a cwd.
private struct Folders {
  let root: String
  var account: String { "\(root)/account" }
  var cwd: String { "\(root)/repo" }

  init() throws {
    root = try tempFolder()
    try FileManager.default.createDirectory(atPath: account, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
  }

  func remove() { try? FileManager.default.removeItem(atPath: root) }

  func scan() -> [ScannedSkill] { SkillFolders.scan(account: account, cwd: cwd, on: LocalMachine()) }
}

@Suite struct SkillFoldersPathTests {
  @Test func accountSkillHasItsSkillFilePathAndTheAccountSkillOrigin() throws {
    let folders = try Folders()
    defer { folders.remove() }
    try write(skillFile("deploy"), to: "\(folders.account)/skills/deploy/SKILL.md")

    let skill = try #require(folders.scan().first)

    #expect(skill.path == "\(folders.account)/skills/deploy/SKILL.md")
    #expect(skill.origin == ScannedSkill.Origin.accountSkill)
  }

  @Test func cwdSkillHasItsSkillFilePathAndTheCwdSkillOrigin() throws {
    let folders = try Folders()
    defer { folders.remove() }
    try write(skillFile("deploy"), to: "\(folders.cwd)/.claude/skills/deploy/SKILL.md")

    let skill = try #require(folders.scan().first)

    #expect(skill.path == "\(folders.cwd)/.claude/skills/deploy/SKILL.md")
    #expect(skill.origin == ScannedSkill.Origin.cwdSkill)
  }

  @Test func accountCommandHasItsFilePathAndTheAccountCommandOrigin() throws {
    let folders = try Folders()
    defer { folders.remove() }
    try write("Ships it.\n", to: "\(folders.account)/commands/ship.md")

    let command = try #require(folders.scan().first)

    #expect(command.path == "\(folders.account)/commands/ship.md")
    #expect(command.origin == ScannedSkill.Origin.accountCommand)
  }

  @Test func cwdCommandHasItsFilePathAndTheCwdCommandOrigin() throws {
    let folders = try Folders()
    defer { folders.remove() }
    try write("Ships it.\n", to: "\(folders.cwd)/.claude/commands/ship.md")

    let command = try #require(folders.scan().first)

    #expect(command.path == "\(folders.cwd)/.claude/commands/ship.md")
    #expect(command.origin == ScannedSkill.Origin.cwdCommand)
  }

  @Test func skillNamedInItsFrontmatterKeepsThePathOfItsFolder() throws {
    let folders = try Folders()
    defer { folders.remove() }
    try write(skillFile("real-name"), to: "\(folders.account)/skills/folder-name/SKILL.md")

    let skill = try #require(folders.scan().first)

    #expect(skill.name == "real-name")
    #expect(skill.path == "\(folders.account)/skills/folder-name/SKILL.md")
  }

  @Test func oneNameInEveryFolderComesBackInPrecedenceOrderWithEachPath() throws {
    let folders = try Folders()
    defer { folders.remove() }
    try write("Repo command.\n", to: "\(folders.cwd)/.claude/commands/dup.md")
    try write("Account command.\n", to: "\(folders.account)/commands/dup.md")
    try write(skillFile("dup"), to: "\(folders.cwd)/.claude/skills/dup/SKILL.md")
    try write(skillFile("dup"), to: "\(folders.account)/skills/dup/SKILL.md")

    let found = folders.scan()

    #expect(found.map(\.name) == ["dup", "dup", "dup", "dup"])
    #expect(
      found.map(\.origin) == [
        ScannedSkill.Origin.accountSkill, .cwdSkill, .accountCommand, .cwdCommand,
      ])
    #expect(
      found.map(\.path) == [
        "\(folders.account)/skills/dup/SKILL.md",
        "\(folders.cwd)/.claude/skills/dup/SKILL.md",
        "\(folders.account)/commands/dup.md",
        "\(folders.cwd)/.claude/commands/dup.md",
      ])
  }

  @Test func entriesOfOneFolderStaySortedAndKeepTheirOwnPaths() throws {
    let folders = try Folders()
    defer { folders.remove() }
    try write(skillFile("zeta"), to: "\(folders.account)/skills/zeta/SKILL.md")
    try write(skillFile("alpha"), to: "\(folders.account)/skills/alpha/SKILL.md")
    try write("Z.\n", to: "\(folders.cwd)/.claude/commands/zed.md")
    try write("A.\n", to: "\(folders.cwd)/.claude/commands/able.md")

    let found = folders.scan()

    #expect(found.map(\.name) == ["alpha", "zeta", "able", "zed"])
    #expect(
      found.map(\.path) == [
        "\(folders.account)/skills/alpha/SKILL.md",
        "\(folders.account)/skills/zeta/SKILL.md",
        "\(folders.cwd)/.claude/commands/able.md",
        "\(folders.cwd)/.claude/commands/zed.md",
      ])
    #expect(
      found.map(\.origin) == [
        ScannedSkill.Origin.accountSkill, .accountSkill, .cwdCommand, .cwdCommand,
      ])
  }

  @Test func firstEntryOfANameIsTheAccountSkill() throws {
    let folders = try Folders()
    defer { folders.remove() }
    try write("Account command.\n", to: "\(folders.account)/commands/dup.md")
    try write(skillFile("dup"), to: "\(folders.cwd)/.claude/skills/dup/SKILL.md")
    try write(skillFile("dup"), to: "\(folders.account)/skills/dup/SKILL.md")

    let first = try #require(folders.scan().first { $0.name == "dup" })

    #expect(first.origin == ScannedSkill.Origin.accountSkill)
    #expect(first.path == "\(folders.account)/skills/dup/SKILL.md")
  }

  @Test func nilAccountGivesOnlyCwdOrigins() throws {
    let folders = try Folders()
    defer { folders.remove() }
    try write(skillFile("in-account"), to: "\(folders.account)/skills/in-account/SKILL.md")
    try write("In account.\n", to: "\(folders.account)/commands/in-account-command.md")
    try write(skillFile("in-repo"), to: "\(folders.cwd)/.claude/skills/in-repo/SKILL.md")
    try write("In repo.\n", to: "\(folders.cwd)/.claude/commands/in-repo-command.md")

    let found = SkillFolders.scan(account: nil, cwd: folders.cwd, on: LocalMachine())

    #expect(found.map(\.origin) == [ScannedSkill.Origin.cwdSkill, .cwdCommand])
    #expect(
      found.map(\.path) == [
        "\(folders.cwd)/.claude/skills/in-repo/SKILL.md",
        "\(folders.cwd)/.claude/commands/in-repo-command.md",
      ])
  }

  @Test(.timeLimit(.minutes(1))) func commandLinkedToAnEndlessDeviceKeepsTheLinkPath() throws {
    let folders = try Folders()
    defer { folders.remove() }
    try FileManager.default.createDirectory(
      atPath: "\(folders.cwd)/.claude/commands", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: "\(folders.cwd)/.claude/commands/zero.md", withDestinationPath: "/dev/zero")

    let found = folders.scan()

    #expect(found.map(\.path) == ["\(folders.cwd)/.claude/commands/zero.md"])
    #expect(found.map(\.origin) == [ScannedSkill.Origin.cwdCommand])
  }
}

@Suite struct SkillFoldersHeadTests {
  private static let cap = 64 << 10

  /// The head of a file that holds `data`.
  private func head(of data: Data) throws -> Data? {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    try write(data, to: "\(folder)/file")
    let result: Data? = SkillFolders.head("\(folder)/file", on: LocalMachine())
    return result
  }

  private func bytes(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

  @Test func smallFileComesBackWhole() throws {
    let data = Data("---\nname: go\n---\nRun it.\n".utf8)

    #expect(try head(of: data) == data)
  }

  @Test func bytesThatAreNotUTF8ComeBackUnchanged() throws {
    let data = Data([0xFF, 0xFE, 0x00, 0xC3, 0x28, 0x80, 0x0A])

    #expect(try head(of: data) == data)
  }

  @Test func emptyFileGivesEmptyData() throws {
    #expect(try head(of: Data()) == Data())
  }

  @Test func fileOfExactlyTheCapComesBackWhole() throws {
    let data = bytes(Self.cap)

    #expect(try head(of: data) == data)
  }

  @Test(arguments: [1, 4096, 1 << 20])
  func fileLongerThanTheCapGivesItsFirst64KiB(_ extra: Int) throws {
    let data = bytes(Self.cap + extra)

    #expect(try head(of: data) == data.prefix(Self.cap))
  }

  @Test func missingFileGivesNil() throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }

    let result: Data? = SkillFolders.head("\(folder)/missing", on: LocalMachine())

    #expect(result == nil)
  }

  @Test(.timeLimit(.minutes(1))) func linkToAnEndlessDeviceGivesTheCapOfBytes() throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    try FileManager.default.createSymbolicLink(atPath: "\(folder)/zero.md", withDestinationPath: "/dev/zero")

    let result: Data? = SkillFolders.head("\(folder)/zero.md", on: LocalMachine())

    #expect(result == Data(count: Self.cap))
  }
}
