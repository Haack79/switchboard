import Foundation
import Testing

@testable import SwitchboardCore

/// The short link that a publish's `tool_response.url` holds.
let artifactShortId = "AbCdEfGhIjKlMnOpQrStUv"
let artifactShortURL = "https://claude.ai/artifact/\(artifactShortId)"
/// The `artifact_id` of the same artifact. A `/code/artifact/<uuid>` link names it.
let artifactUUID = "00000000-1111-2222-3333-444444444444"
let artifactCodeURL = "https://claude.ai/code/artifact/\(artifactUUID)"
let artifactPage = "/private/tmp/claude-501/project/session/scratchpad/report.html"

/// A hook of Claude Code's Artifact tool, as sbd stores its payload. A nil `response` leaves `tool_response` out.
func artifactHook(
  _ t: Int64, kind: String = "PostToolUse", tool: String = "Artifact", input: [String: JSON], response: JSON?,
  agent: String? = nil
) -> Event {
  var fields: [String: JSON] = [
    "hook_event_name": .string(kind), "session_id": "uuid", "tool_name": .string(tool),
    "tool_use_id": .string("toolu_\(t)"), "tool_input": .object(input), "permission_mode": "default",
    "cwd": "/tmp", "transcript_path": "/tmp/t.jsonl", "duration_ms": 812,
  ]
  if let response { fields["tool_response"] = response }
  if let agent { fields["agent_id"] = .string(agent) }
  return event(kind, t, fields)
}

/// The `tool_response` of a first publish or a republish, in the shape of the plan's Evidence section.
func artifactPublishResponse(
  url: String = artifactShortURL, artifactId: String? = artifactUUID, title: String? = "Delta Rates",
  republish: Bool = false
) -> JSON {
  var r: [String: JSON] = [
    "url": .string(url), "path": .string(artifactPage), "updated": .bool(republish), "owned": true, "icon": "chart",
    "audience": "owner", "seq": republish ? 2 : 1, "version": "1794536181-a91c", "contract": "0.0.0",
    "liveSubscription": "arming",
  ]
  if let artifactId { r["artifact_id"] = .string(artifactId) }
  if let title { r["title"] = .string(title) }
  return .object(r)
}

/// The `tool_response` of a create from an Artifact type. It has no `artifact_id`.
func artifactTypeCreateResponse(url: String = artifactShortURL, title: String = "Q4 Plan") -> JSON {
  [
    "url": .string(url), "title": .string(title), "version": "1794536181-b02e", "created_from_type": true,
    "type": "Docs", "type_files": ["index.html"], "own_files": [], "instructions": "Fill the doc.",
    "instructions_chars": 14, "provisioned": true, "auto_open": "at_create", "liveSubscription": "arming",
  ]
}

/// The input of a first publish.
let artifactFirstInput: [String: JSON] = [
  "file_path": .string(artifactPage), "icon": "chart", "description": "How the delta rates chart is built.",
]

/// One hook that the publish guard sees, and the URL that it records, or nil when it records nothing.
struct PublishCase: Sendable, CustomTestStringConvertible {
  var name: String
  var kind = "PostToolUse"
  var tool = "Artifact"
  var input: [String: JSON]
  var response: JSON?
  var recorded: String?

  var testDescription: String { name }

  func hook(_ t: Int64, agent: String?) -> Event {
    artifactHook(t, kind: kind, tool: tool, input: input, response: response, agent: agent)
  }
}

/// The agents a hook can come from: the main session and a subagent. Neither changes what the guards decide.
let artifactAgents: [String?] = [nil, "a1b2c3d4e5"]

private func input(_ extra: [String: JSON]) -> [String: JSON] { artifactFirstInput.merging(extra) { $1 } }

/// The calls that create or redeploy an artifact's page. Each records the normalized `tool_response.url`.
private let publishes: [PublishCase] = [
  PublishCase(
    name: "no action and a file_path", input: ["file_path": .string(artifactPage)],
    response: artifactPublishResponse(), recorded: artifactShortURL),
  PublishCase(
    name: "the Evidence first publish", input: artifactFirstInput, response: artifactPublishResponse(),
    recorded: artifactShortURL),
  PublishCase(
    name: "a republish with an input url", input: input(["url": .string(artifactShortURL)]),
    response: artifactPublishResponse(republish: true), recorded: artifactShortURL),
  PublishCase(
    name: "an icon", input: input(["icon": "map"]), response: artifactPublishResponse(), recorded: artifactShortURL),
  PublishCase(
    name: "a favicon", input: input(["favicon": "map"]), response: artifactPublishResponse(),
    recorded: artifactShortURL),
  PublishCase(
    name: "a title", input: input(["title": "Delta Rates"]), response: artifactPublishResponse(),
    recorded: artifactShortURL),
  PublishCase(
    name: "capabilities", input: input(["capabilities": ["db": [:]]]), response: artifactPublishResponse(),
    recorded: artifactShortURL),
  PublishCase(
    name: "files", input: input(["files": ["data.json": "/tmp/data.json"]]), response: artifactPublishResponse(),
    recorded: artifactShortURL),
  PublishCase(
    name: "a label", input: input(["label": "Draft to legal"]), response: artifactPublishResponse(),
    recorded: artifactShortURL),
  PublishCase(
    name: "action publish and a file_path", input: input(["action": "publish"]), response: artifactPublishResponse(),
    recorded: artifactShortURL),
  PublishCase(
    name: "a create from a type",
    input: ["action": "publish", "type_url": "https://claude.ai/artifact/DocsType1", "title": "Q4 Plan"],
    response: artifactTypeCreateResponse(), recorded: artifactShortURL),
  PublishCase(
    name: "a create from a type without an action",
    input: ["type_url": "https://claude.ai/artifact/DocsType1", "title": "Q4 Plan"],
    response: artifactTypeCreateResponse(), recorded: artifactShortURL),
  PublishCase(
    name: "typed artifact data: files, root, and url",
    input: ["files": ["data/rows.json": "rows.json"], "root": "/tmp/scratch", "url": .string(artifactShortURL)],
    response: artifactPublishResponse(republish: true), recorded: artifactShortURL),
  PublishCase(
    name: "asset false", input: input(["asset": false]), response: artifactPublishResponse(),
    recorded: artifactShortURL),
  PublishCase(
    name: "an input url that differs from the response's",
    input: input(["url": "https://claude.ai/artifact/SomeOtherPage"]), response: artifactPublishResponse(),
    recorded: artifactShortURL),
  PublishCase(
    name: "a response url with upper case, a query, and a fragment", input: artifactFirstInput,
    response: artifactPublishResponse(url: "HTTPS://CLAUDE.AI/artifact/\(artifactShortId)?v=2#top"),
    recorded: artifactShortURL),
  PublishCase(
    name: "a response url in the /code/artifact form", input: artifactFirstInput,
    response: artifactPublishResponse(url: artifactCodeURL), recorded: artifactCodeURL),
]

/// The calls that publish nothing. Each records nothing.
private let nonPublishes: [PublishCase] = [
  PublishCase(
    name: "asset true and a file_path",
    input: ["asset": true, "url": .string(artifactShortURL), "file_path": "/tmp/a.png"],
    response: artifactPublishResponse()),
  PublishCase(
    name: "asset true and file_paths",
    input: ["asset": true, "url": .string(artifactShortURL), "file_paths": ["/tmp/a.png", "/tmp/b.png"]],
    response: artifactPublishResponse()),
  PublishCase(
    name: "asset true, from_url, and asset_ids",
    input: [
      "asset": true, "url": .string(artifactShortURL), "from_url": "https://claude.ai/artifact/DesignSystem1",
      "asset_ids": ["0123456789abcdef0123456789abcdef"],
    ], response: artifactPublishResponse()),
  PublishCase(
    name: "from_url without asset",
    input: ["url": .string(artifactShortURL), "from_url": "https://claude.ai/artifact/DesignSystem1"],
    response: artifactPublishResponse()),
  PublishCase(
    name: "asset_ids without asset",
    input: ["url": .string(artifactShortURL), "asset_ids": ["0123456789abcdef0123456789abcdef"]],
    response: artifactPublishResponse()),
  PublishCase(
    name: "read", input: ["action": "read", "url": .string(artifactShortURL), "prompt": "the table"],
    response: [
      "read": ["url": .string(artifactShortURL), "title": "Delta Rates", "bytes": 4096], "artifactRead": true,
      "owned": true,
    ]),
  PublishCase(
    name: "open", input: ["action": "open", "url": .string(artifactShortURL)],
    response: [
      "url": .string(artifactShortURL), "title": "Delta Rates", "artifact_id": .string(artifactUUID), "opened": true,
      "owned": true,
    ]),
  PublishCase(
    name: "list", input: ["action": "list", "scope": "mine", "limit": 25],
    response: ["artifacts": [["url": .string(artifactShortURL), "title": "Delta Rates"]], "pins_enabled": true]),
  PublishCase(
    name: "pin", input: ["action": "pin", "url": .string(artifactShortURL)],
    response: ["url": .string(artifactShortURL), "pinned": true]),
  PublishCase(
    name: "unpin", input: ["action": "unpin", "url": .string(artifactShortURL)],
    response: ["url": .string(artifactShortURL), "pinned": false]),
  PublishCase(
    name: "quickstart", input: ["action": "quickstart", "intent": "other"],
    response: ["quickstart": ["url": .string(artifactShortURL)]]),
  PublishCase(
    name: "delete of an artifact that the session never listed",
    input: ["action": "delete", "url": .string(artifactShortURL)],
    response: artifactPublishResponse()),
  PublishCase(
    name: "an unknown action", input: ["action": "summarize", "url": .string(artifactShortURL)],
    response: artifactPublishResponse()),
  PublishCase(name: "an empty action", input: input(["action": ""]), response: artifactPublishResponse()),
  PublishCase(name: "an upper-case action", input: input(["action": "PUBLISH"]), response: artifactPublishResponse()),
  PublishCase(name: "an action that is not a string", input: input(["action": 1]), response: artifactPublishResponse()),
  PublishCase(
    name: "PostToolUseFailure", kind: "PostToolUseFailure", input: artifactFirstInput,
    response: "Error: publish refused: the page is over 16MB"),
  PublishCase(
    name: "PostToolUseFailure with a response object", kind: "PostToolUseFailure", input: artifactFirstInput,
    response: artifactPublishResponse()),
  PublishCase(name: "PreToolUse", kind: "PreToolUse", input: artifactFirstInput, response: artifactPublishResponse()),
  PublishCase(
    name: "PermissionRequest", kind: "PermissionRequest", input: artifactFirstInput, response: artifactPublishResponse()
  ),
  PublishCase(
    name: "a lower-case tool name", tool: "artifact", input: artifactFirstInput, response: artifactPublishResponse()),
  PublishCase(
    name: "the Claude Docs connector", tool: "mcp__claude_ai_Claude_Docs__create", input: ["title": "Q4 Plan"],
    response: artifactPublishResponse()),
  PublishCase(
    name: "another tool with a url in its response", tool: "WebFetch", input: ["url": .string(artifactShortURL)],
    response: ["url": .string(artifactShortURL)]),
  PublishCase(
    name: "a string response", input: artifactFirstInput,
    response: .string("Published report.html at \(artifactShortURL) (Version 1794536181-a91c)")),
  PublishCase(name: "a null response", input: artifactFirstInput, response: .null),
  PublishCase(name: "no response", input: artifactFirstInput, response: nil),
  PublishCase(
    name: "no response with a valid input url", input: input(["url": .string(artifactShortURL)]), response: nil),
  PublishCase(name: "an array response", input: artifactFirstInput, response: [.string(artifactShortURL)]),
  PublishCase(
    name: "a response object without url", input: artifactFirstInput,
    response: ["title": "Delta Rates", "artifact_id": .string(artifactUUID), "seq": 1]),
  PublishCase(name: "a response url that is a number", input: artifactFirstInput, response: ["url": 42]),
  PublishCase(
    name: "an invalid response url with a valid input url", input: input(["url": .string(artifactShortURL)]),
    response: artifactPublishResponse(url: "https://evil.com/artifact/\(artifactShortId)")),
]

/// Response URLs that `ArtifactLink` refuses. A publish whose response holds one records nothing.
private let refusedLinks = [
  "http://claude.ai/artifact/\(artifactShortId)",
  "https://claude.ai.evil.com/artifact/\(artifactShortId)",
  "https://evil.com/artifact/\(artifactShortId)",
  "https://claude.ai/artifact/\(artifactShortId)/extra",
  "https://claude.ai/docs/artifact/\(artifactShortId)",
  "https://claude.ai/artifact/",
  "https://claude.ai/artifact/abc%0Aignore",
  "https://claude.ai/artifact/abc%2Fdef",
  "javascript:alert(1)",
  "",
]

/// The publish guard (Risk 1): an event records the artifact at U only when it is an Artifact `PostToolUse`
/// whose action is absent or `publish`, that uploads or copies no assets, and whose `tool_response` is an object
/// with a `url` that `ArtifactLink` accepts. A subagent's hook decides the same as the main session's.
@Suite struct ArtifactCallTests {
  @Test(arguments: publishes, artifactAgents)
  func aPublishRecordsTheResponsesNormalizedURL(_ row: PublishCase, agent: String?) throws {
    let url = try #require(row.recorded)

    let f = facts([row.hook(1000, agent: agent)])

    #expect(f.artifacts.map(\.url) == [url])
  }

  @Test(arguments: nonPublishes, artifactAgents)
  func aCallThatPublishedNothingRecordsNothing(_ row: PublishCase, agent: String?) {
    let f = facts([row.hook(1000, agent: agent)])

    #expect(f.artifacts.isEmpty)
  }

  @Test(arguments: refusedLinks, artifactAgents)
  func aResponseURLThatArtifactLinkRefusesRecordsNothing(_ link: String, agent: String?) {
    let f = facts([
      artifactHook(1000, input: artifactFirstInput, response: artifactPublishResponse(url: link), agent: agent)
    ])

    #expect(f.artifacts.isEmpty)
  }

  /// A refused call after a publish leaves the entry as the publish wrote it. A delete is left out, because it
  /// names the published entry.
  @Test(arguments: nonPublishes.filter { $0.input["action"] != "delete" }, artifactAgents)
  func aCallThatPublishedNothingLeavesAnExistingEntryUnchanged(_ row: PublishCase, agent: String?) {
    let before = facts([artifactHook(1000, input: artifactFirstInput, response: artifactPublishResponse())])

    let after = facts([
      artifactHook(1000, input: artifactFirstInput, response: artifactPublishResponse()), row.hook(5000, agent: agent),
    ])

    #expect(after.artifacts == before.artifacts)
  }

  @Test func otherEventsRecordNothing() {
    let f = facts([
      event("SessionStart", 1), event("UserPromptSubmit", 2, ["prompt": .string(artifactShortURL)]),
      event("PostToolUse", 3, tool("Bash", ["command": .string("open \(artifactShortURL)")], id: "b1")),
      event("Stop", 4, ["last_assistant_message": .string("Published at \(artifactShortURL)")]),
    ])

    #expect(f.artifacts.isEmpty)
  }

  // MARK: The parse result

  @Test func parseReturnsThePublishOfTheEvidencePayload() {
    let call = ArtifactCall.parse(artifactHook(1000, input: artifactFirstInput, response: artifactPublishResponse()))

    #expect(call == .publish(url: artifactShortURL, artifactId: artifactUUID, title: "Delta Rates"))
  }

  @Test func parseReturnsATypeCreateWithoutAnArtifactId() {
    let call = ArtifactCall.parse(
      artifactHook(
        1000, input: ["action": "publish", "type_url": "https://claude.ai/artifact/DocsType1", "title": "Q4 Plan"],
        response: artifactTypeCreateResponse()))

    #expect(call == .publish(url: artifactShortURL, artifactId: nil, title: "Q4 Plan"))
  }

  @Test func parseReturnsADeleteWithTheNormalizedInputURL() {
    let call = ArtifactCall.parse(
      artifactHook(1000, input: ["action": "delete", "url": .string("\(artifactShortURL)?x=1#y")], response: nil))

    #expect(call == .delete(url: artifactShortURL))
  }

  @Test(arguments: [
    PublishCase(
      name: "open", input: ["action": "open", "url": .string(artifactShortURL)], response: artifactPublishResponse()),
    PublishCase(
      name: "delete of an asset",
      input: ["action": "delete", "url": .string(artifactShortURL), "path": "0123456789abcdef0123456789abcdef"],
      response: nil),
    PublishCase(name: "delete without a url", input: ["action": "delete"], response: nil),
    PublishCase(
      name: "a failed delete", kind: "PostToolUseFailure",
      input: ["action": "delete", "url": .string(artifactShortURL)], response: "Error"),
  ])
  func parseReturnsNilForACallThatIsNeitherAPublishNorADelete(_ row: PublishCase) {
    #expect(ArtifactCall.parse(row.hook(1000, agent: nil)) == nil)
  }
}

/// One delete hook after a publish of `artifactShortURL` whose `artifact_id` is `artifactUUID`, and whether it
/// marks that entry removed.
struct DeleteCase: Sendable, CustomTestStringConvertible {
  var name: String
  var kind = "PostToolUse"
  var tool = "Artifact"
  var input: [String: JSON]
  var response: JSON? = nil
  var removes: Bool

  var testDescription: String { name }
}

private let deletes: [DeleteCase] = [
  DeleteCase(
    name: "delete and the short link", input: ["action": "delete", "url": .string(artifactShortURL)], removes: true),
  DeleteCase(
    name: "delete and the short link with a query and a fragment",
    input: ["action": "delete", "url": .string("\(artifactShortURL)?v=1#top")], removes: true),
  DeleteCase(
    name: "delete and the link in upper case",
    input: ["action": "delete", "url": .string("HTTPS://CLAUDE.AI/artifact/\(artifactShortId)")], removes: true),
  DeleteCase(
    name: "delete and the /code/artifact link, matched by artifactId",
    input: ["action": "delete", "url": .string(artifactCodeURL)], removes: true),
  DeleteCase(
    name: "delete with a string response", input: ["action": "delete", "url": .string(artifactShortURL)],
    response: .string("Deleted \(artifactShortURL)"), removes: true),
  DeleteCase(
    name: "delete with an object response", input: ["action": "delete", "url": .string(artifactShortURL)],
    response: ["deleted": true], removes: true),
  DeleteCase(
    name: "delete with a path removes one asset",
    input: ["action": "delete", "url": .string(artifactShortURL), "path": "0123456789abcdef0123456789abcdef"],
    removes: false),
  DeleteCase(name: "delete without a url", input: ["action": "delete"], removes: false),
  DeleteCase(name: "delete with a url that is not a string", input: ["action": "delete", "url": 7], removes: false),
  DeleteCase(
    name: "delete with an http link",
    input: ["action": "delete", "url": .string("http://claude.ai/artifact/\(artifactShortId)")],
    removes: false),
  DeleteCase(
    name: "delete with another host's link",
    input: ["action": "delete", "url": .string("https://evil.com/artifact/\(artifactShortId)")], removes: false),
  DeleteCase(
    name: "delete with an id that holds %0A",
    input: ["action": "delete", "url": .string("https://claude.ai/artifact/\(artifactShortId)%0A")], removes: false),
  DeleteCase(
    name: "delete of a link that matches no entry",
    input: ["action": "delete", "url": "https://claude.ai/artifact/SomeOtherPage"], removes: false),
  DeleteCase(
    name: "delete of a /code/artifact link with another uuid",
    input: ["action": "delete", "url": "https://claude.ai/code/artifact/99999999-1111-2222-3333-444444444444"],
    removes: false),
  DeleteCase(
    name: "a failed delete", kind: "PostToolUseFailure", input: ["action": "delete", "url": .string(artifactShortURL)],
    response: "Error: not found", removes: false),
  DeleteCase(
    name: "a delete before it ran", kind: "PreToolUse", input: ["action": "delete", "url": .string(artifactShortURL)],
    removes: false),
  DeleteCase(
    name: "a delete's permission request", kind: "PermissionRequest",
    input: ["action": "delete", "url": .string(artifactShortURL)], removes: false),
  DeleteCase(
    name: "a delete by another tool", tool: "mcp__claude_ai_Claude_Docs__delete",
    input: ["action": "delete", "url": .string(artifactShortURL)], removes: false),
  DeleteCase(name: "a read of the link", input: ["action": "read", "url": .string(artifactShortURL)], removes: false),
]

/// The delete guard (Risk 2): a delete marks an entry removed only when it is an Artifact `PostToolUse` with
/// action `delete`, no `path`, and a `url` that `ArtifactLink` accepts and that names one of the session's
/// entries by URL or by artifact id. The entry stays in the list.
@Suite struct ArtifactDeleteCallTests {
  @Test(arguments: deletes, artifactAgents)
  func aDeleteMarksTheEntryRemovedOnlyWhenEveryConditionHolds(_ row: DeleteCase, agent: String?) throws {
    let f = facts([
      artifactHook(1000, input: artifactFirstInput, response: artifactPublishResponse()),
      artifactHook(5000, kind: row.kind, tool: row.tool, input: row.input, response: row.response, agent: agent),
    ])

    let entry = try #require(f.artifacts.first)
    #expect(f.artifacts.count == 1)
    #expect(entry.removed == (row.removes ? 5000 : nil))
  }

  @Test(arguments: deletes, artifactAgents)
  func aDeleteChangesNothingButRemoved(_ row: DeleteCase, agent: String?) throws {
    let before = facts([artifactHook(1000, input: artifactFirstInput, response: artifactPublishResponse())])
    let f = facts([
      artifactHook(1000, input: artifactFirstInput, response: artifactPublishResponse()),
      artifactHook(5000, kind: row.kind, tool: row.tool, input: row.input, response: row.response, agent: agent),
    ])

    var entry = try #require(f.artifacts.first)
    entry.removed = nil
    #expect([entry] == before.artifacts)
  }

  /// An entry from a type create has no artifact id, so a `/code/artifact/<uuid>` link can't name it.
  @Test func aCodeLinkDoesNotMatchAnEntryWithoutAnArtifactId() throws {
    let f = facts([
      artifactHook(
        1000, input: ["action": "publish", "type_url": "https://claude.ai/artifact/DocsType1", "title": "Q4 Plan"],
        response: artifactTypeCreateResponse()),
      artifactHook(5000, input: ["action": "delete", "url": .string(artifactCodeURL)], response: nil),
    ])

    #expect(try #require(f.artifacts.first).removed == nil)
  }

  /// A delete marks only the entry that it names.
  @Test func aDeleteLeavesTheSessionsOtherEntries() {
    let other = "https://claude.ai/artifact/SecondPage"
    let f = facts([
      artifactHook(1000, input: artifactFirstInput, response: artifactPublishResponse()),
      artifactHook(
        2000, input: ["file_path": "/tmp/other.html"],
        response: artifactPublishResponse(
          url: other, artifactId: "55555555-1111-2222-3333-444444444444", title: "Other")),
      artifactHook(5000, input: ["action": "delete", "url": .string(artifactShortURL)], response: nil),
    ])

    #expect(f.artifacts.map(\.url) == [artifactShortURL, other])
    #expect(f.artifacts.map(\.removed) == [5000, nil])
  }
}
