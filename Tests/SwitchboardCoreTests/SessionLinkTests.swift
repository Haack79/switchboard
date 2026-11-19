import Foundation
import Testing

@testable import SwitchboardCore

/// `target(from:)` gives `.id` only when the URL's text is exactly what `url(for:)` builds for a session id. It gives
/// `.name` when the single path segment after `switchboard://session/` percent-decodes to a valid name. Any app or
/// web page can open the scheme, so each refused case changes one thing about `switchboard://session/seb4ec`.
@Suite struct SessionLinkTests {
  private static let ids = [
    "seb4ec", "sgcctv", "s23456", "szzzzz", "sebc4e", "swb_eb4ec", "swb_23456", "swb_zzzzz", "swb_s2abc",
  ]

  private func target(_ string: String) throws -> SessionLink.Target? {
    SessionLink.target(from: try #require(URL(string: string), "\(string) is not a URL"))
  }

  // MARK: Id targets

  @Test(arguments: ["seb4ec", "swb_eb4ec"])
  func urlForAnIdIsTheSchemeTheHostAndTheId(_ id: String) {
    #expect(SessionLink.url(for: id).absoluteString == "switchboard://session/\(id)")
  }

  /// Launch Services hands the app a URL parsed from text, so the round trip goes through the text.
  @Test(arguments: ids)
  func targetFromTheTextOfTheURLForAnIdIsThatId(_ id: String) throws {
    #expect(try target(SessionLink.url(for: id).absoluteString) == .id(id))
  }

  @Test(arguments: ids)
  func targetFromTheURLForAnIdIsThatId(_ id: String) {
    #expect(SessionLink.target(from: SessionLink.url(for: id)) == .id(id))
  }

  @Test func targetFromAParsedSessionURLIsTheId() throws {
    #expect(try target("switchboard://session/seb4ec") == .id("seb4ec"))
  }

  @Test func targetFromAURLBuiltFromComponentsIsTheId() throws {
    var components = URLComponents()
    components.scheme = "switchboard"
    components.host = "session"
    components.path = "/seb4ec"
    let url = try #require(components.url)

    #expect(SessionLink.target(from: url) == .id("seb4ec"))
  }

  // MARK: Refused: other schemes

  /// The window's URL handler passes each of these to the system, so a PR
  /// link or a Markdown link that names a session id keeps opening the browser.
  @Test(arguments: [
    "https://github.com/haacked/switchboard/pull/309",
    "https://example.com/seb4ec",
    "https://switchboard-session/seb4ec",
    "https://session/seb4ec",
    "http://session/seb4ec",
    "http://session/fix-cache",
    "http://example.com/?session=seb4ec",
    "file:///tmp/seb4ec",
    "file:///Users/me/.sb/sessions/seb4ec/claude.sh",
    "mailto:seb4ec@example.com",
    "other:seb4ec",
    "other://session/seb4ec",
    "other://session/fix-cache",
    "session:seb4ec",
  ])
  func aURLWithAnotherSchemeIsNotASessionLink(_ string: String) throws {
    #expect(try target(string) == nil)
  }

  @Test func aFileURLMadeFromAPathIsNotASessionLink() {
    #expect(SessionLink.target(from: URL(fileURLWithPath: "/tmp/seb4ec")) == nil)
  }

  // MARK: Refused: structure

  /// Each case is the canonical `switchboard://session/seb4ec`, or a name link, with one structural change. Decision 2
  /// keeps each of these refused, whether the path would read as an id or as a name.
  @Test(arguments: [
    // Case of the scheme or the host
    "SWITCHBOARD://session/seb4ec",
    "Switchboard://session/seb4ec",
    "switchboard://SESSION/seb4ec",
    "switchboard://Session/seb4ec",
    "Switchboard://session/fix-cache",
    "switchboard://SESSION/fix-cache",
    // Query and fragment
    "switchboard://session/seb4ec?x=1",
    "switchboard://session/seb4ec?",
    "switchboard://session/seb4ec#top",
    "switchboard://session/seb4ec#",
    "switchboard://session/fix-cache?x=1",
    "switchboard://session/fix-cache#top",
    // Path: extra, empty, and dot segments, a trailing slash, and parameters
    "switchboard://session/seb4ec/",
    "switchboard://session/seb4ec/claude.sh",
    "switchboard://session//seb4ec",
    "switchboard://session/./seb4ec",
    "switchboard://session/x/../seb4ec",
    "switchboard://session/seb4ec;x",
    "switchboard://session/fix-cache/",
    "switchboard://session//fix-cache",
    "switchboard://session/./fix-cache",
    "switchboard://session/x/../fix-cache",
    "switchboard://session/fix-cache;x",
    "switchboard://session/.",
    "switchboard://session/..",
    "switchboard://session/",
    "switchboard://session",
    // A raw slash starts a second segment
    "switchboard://session/posthog-code/flag-evaluations-table",
    // User info and port
    "switchboard://u@session/seb4ec",
    "switchboard://u:p@session/seb4ec",
    "switchboard://@session/seb4ec",
    "switchboard://session:80/seb4ec",
    "switchboard://session:/seb4ec",
    "switchboard://u@session/fix-cache",
    "switchboard://session:80/fix-cache",
    // Host
    "switchboard://other/seb4ec",
    "switchboard://seb4ec",
    "switchboard://session./seb4ec",
    "switchboard:///session/seb4ec",
    "switchboard://other/fix-cache",
    "switchboard://fix-cache",
    "switchboard://",
    "switchboard:",
    // Percent-escapes in the host
    "switchboard://%73ession/seb4ec",
    "switchboard://%73ession/fix-cache",
    // Other forms of the scheme
    "switchboard:seb4ec",
    "switchboard:/session/seb4ec",
    "switchboard:session/seb4ec",
    "switchboard:session/fix-cache",
    "switchboard-session:seb4ec",
    "switchboard-session://session/seb4ec",
  ])
  func aSwitchboardURLWithAnotherStructureIsNotASessionLink(_ string: String) throws {
    #expect(try target(string) == nil)
  }

  // MARK: Refused: the decoded name

  /// A percent-encoded id decodes to the id's shape. Decision 3 refuses an id-shaped name, so the id path stays the
  /// only way to reach a session by its id.
  @Test(arguments: [
    "switchboard://session/%73eb4ec",
    "switchboard://session/seb4e%63",
    "switchboard://session/%73%65%62%34%65%63",
    "switchboard://session/s%67cctv",
    "switchboard://session/swb%5Feb4ec",
    "switchboard://session/swb%5feb4ec",
    "switchboard://session/%73wb_eb4ec",
    "switchboard://session/swb_eb4e%63",
    "switchboard://session/%73%77%62%5F%65%62%34%65%63",
  ])
  func aPercentEncodedIdIsNotASessionLink(_ string: String) throws {
    #expect(try target(string) == nil)
  }

  /// An encoded dot decodes to the dot segment that the raw path refuses.
  @Test(arguments: [
    "switchboard://session/%2E", "switchboard://session/%2e", "switchboard://session/%2E%2E",
    "switchboard://session/.%2E",
  ])
  func anEncodedDotSegmentIsNotASessionLink(_ string: String) throws {
    #expect(try target(string) == nil)
  }

  /// Each escape is valid percent syntax, so `URL(string:)` keeps it, but the bytes are not UTF-8.
  @Test(arguments: [
    "switchboard://session/%ff",
    "switchboard://session/fix%ffcache",
    "switchboard://session/%C3",
    "switchboard://session/caf%C3",
    "switchboard://session/%C3%28",
    "switchboard://session/%80",
  ])
  func aNameThatDoesNotDecodeIsNotASessionLink(_ string: String) throws {
    #expect(try target(string) == nil)
  }

  @Test(arguments: [
    "switchboard://session/%20",
    "switchboard://session/%20%20",
    "switchboard://session/%09",
    "switchboard://session/%C2%A0",
    "switchboard://session/%E3%80%80",
    "switchboard://session/%20%09%20",
  ])
  func aNameOfOnlyWhitespaceIsNotASessionLink(_ string: String) throws {
    #expect(try target(string) == nil)
  }

  @Test(arguments: [
    "switchboard://session/%0A",
    "switchboard://session/%0D",
    "switchboard://session/fix%0Acache",
    "switchboard://session/fix%0D%0Acache",
    "switchboard://session/fix-cache%0A",
    "switchboard://session/fix%E2%80%A8cache",
    "switchboard://session/fix%E2%80%A9cache",
    "switchboard://session/fix%C2%85cache",
  ])
  func aNameWithANewlineIsNotASessionLink(_ string: String) throws {
    #expect(try target(string) == nil)
  }

  @Test(arguments: [
    "switchboard://session/%00",
    "switchboard://session/fix%00cache",
    "switchboard://session/fix-cache%00",
    "switchboard://session/fix%1Bcache",
    "switchboard://session/fix%07cache",
    "switchboard://session/fix%7Fcache",
    "switchboard://session/fix%09cache",
  ])
  func aNameWithAControlCharacterIsNotASessionLink(_ string: String) throws {
    #expect(try target(string) == nil)
  }

  // MARK: Name length

  @Test func aNameOf200ASCIIScalarsIsANameTarget() throws {
    let name = String(repeating: "a", count: 200)

    #expect(try target("switchboard://session/\(name)") == .name(name))
  }

  @Test func aNameOf201ASCIIScalarsIsNotASessionLink() throws {
    #expect(try target("switchboard://session/\(String(repeating: "a", count: 201))") == nil)
  }

  /// Each `é` is two UTF-8 bytes and one scalar, so the limit counts scalars, not bytes.
  @Test func aNameOf200TwoByteScalarsIsANameTarget() throws {
    let encoded = String(repeating: "%C3%A9", count: 200)

    #expect(try target("switchboard://session/\(encoded)") == .name(String(repeating: "é", count: 200)))
  }

  @Test func aNameOf201TwoByteScalarsIsNotASessionLink() throws {
    #expect(try target("switchboard://session/\(String(repeating: "%C3%A9", count: 201))") == nil)
  }

  /// `e` and a combining acute accent are two scalars and one character, so the limit counts scalars, not characters.
  @Test func aNameOf201ScalarsIn101CharactersIsNotASessionLink() throws {
    let encoded = String(repeating: "e%CC%81", count: 100) + "e"

    #expect(try target("switchboard://session/\(encoded)") == nil)
  }

  @Test func aNameOf200ScalarsIn100CharactersIsANameTarget() throws {
    let encoded = String(repeating: "e%CC%81", count: 100)

    #expect(try target("switchboard://session/\(encoded)") == .name(String(repeating: "e\u{301}", count: 100)))
  }

  // MARK: Name targets

  /// A path that is not the exact id text and decodes to a valid name is a name target. These were refusals before
  /// name links. Each resolves only to a session with exactly that name, never to a session whose id it resembles.
  @Test(
    arguments: [
      // Not the id format: one character too many or too few, upper case, another first letter, letters outside
      // the id alphabet
      ("switchboard://session/seb4ecx", "seb4ecx"),
      ("switchboard://session/seb4e", "seb4e"),
      ("switchboard://session/SEB4EC", "SEB4EC"),
      ("switchboard://session/Seb4ec", "Seb4ec"),
      ("switchboard://session/g4rvrf", "g4rvrf"),
      ("switchboard://session/w3k9ap", "w3k9ap"),
      ("switchboard://session/sl0o1x", "sl0o1x"),
      ("switchboard://session/s", "s"),
      // Whitespace around an id is not whitespace only, so it is a name, not the id
      ("switchboard://session/seb4ec%20", "seb4ec "),
      ("switchboard://session/%20seb4ec", " seb4ec"),
      // The same for the new form, and the new prefix alone
      ("switchboard://session/swb_", "swb_"),
      ("switchboard://session/swb_eb4e", "swb_eb4e"),
      ("switchboard://session/swb_eb4ec1", "swb_eb4ec1"),
      ("switchboard://session/swb_eb4eC", "swb_eb4eC"),
      ("switchboard://session/SWB_eb4ec", "SWB_eb4ec"),
      ("switchboard://session/swb-eb4ec", "swb-eb4ec"),
      ("switchboard://session/swb__eb4e", "swb__eb4e"),
      ("switchboard://session/swbeb4ec", "swbeb4ec"),
      ("switchboard://session/swb_eb4e1", "swb_eb4e1"),
      ("switchboard://session/swb_eb4ec%20", "swb_eb4ec "),
    ] as [(String, String)])
  func aPathThatIsNotTheIdTextIsANameTarget(_ string: String, _ name: String) throws {
    #expect(try target(string) == .name(name))
  }

  @Test(
    arguments: [
      ("switchboard://session/fix-cache", "fix-cache"),
      ("switchboard://session/session", "session"),
      ("switchboard://session/Manager", "Manager"),
      ("switchboard://session/Operator", "Operator"),
      ("switchboard://session/snake_case_name", "snake_case_name"),
      ("switchboard://session/Fix%20CI%20chat", "Fix CI chat"),
      ("switchboard://session/posthog-code%2Fflag-evaluations-table", "posthog-code/flag-evaluations-table"),
      ("switchboard://session/posthog-code%2fflag-evaluations-table", "posthog-code/flag-evaluations-table"),
      ("switchboard://session/caf%C3%A9", "café"),
      ("switchboard://session/caf%c3%a9", "café"),
      ("switchboard://session/100%25", "100%"),
      ("switchboard://session/a%2Fb%3Fc%23d", "a/b?c#d"),
      ("switchboard://session/a%3Bb", "a;b"),
      ("switchboard://session/%E6%97%A5%E6%9C%AC%E8%AA%9E", "日本語"),
      // Decoded once, so an encoded escape of an id stays a name that is not id-shaped
      ("switchboard://session/%2573eb4ec", "%73eb4ec"),
    ] as [(String, String)])
  func aDecodedNameIsANameTarget(_ string: String, _ name: String) throws {
    #expect(try target(string) == .name(name))
  }

  /// `+` means a space only in a form body, not in a URL path.
  @Test func aPlusInTheNameStaysAPlus() throws {
    #expect(try target("switchboard://session/a+b") == .name("a+b"))
  }

  /// `URL(string:)` percent-encodes a raw space and a raw non-ASCII letter, so such text reaches the parser as
  /// the encoded name.
  @Test(
    arguments: [
      ("switchboard://session/Fix CI chat", "Fix CI chat"),
      ("switchboard://session/café", "café"),
    ] as [(String, String)])
  func textWithARawSpaceOrLetterParsesAsTheEncodedName(_ string: String, _ name: String) throws {
    #expect(try target(string) == .name(name))
  }

  /// `URL(string:)` encodes a `%` that does not start an escape as `%25`, so `%zz` reaches the parser as the
  /// valid name `%zz`, the same URL that `url(forName:)` builds for that name.
  @Test(arguments: ["%zz", "%", "a%2"])
  func anInvalidEscapeInTextParsesAsTheNameThatHoldsIt(_ written: String) throws {
    let url = try #require(URL(string: "switchboard://session/\(written)"))

    #expect(SessionLink.target(from: url) == .name(written))
    #expect(url == SessionLink.url(forName: written))
  }

  /// Without the encoding that `URL(string:)` adds, an invalid escape gives no URL at all, so it can never reach
  /// the parser in its raw form.
  @Test(arguments: ["%zz", "%", "a%2", "Fix CI chat"])
  func strictURLParsingRefusesAnInvalidEscapeOrARawSpace(_ written: String) {
    #expect(URL(string: "switchboard://session/\(written)", encodingInvalidCharacters: false) == nil)
  }

  // MARK: url(forName:)

  /// Decision 3: only unreserved characters stay as written.
  @Test(
    arguments: [
      ("fix-cache", "fix-cache"),
      ("snake_case.name~1", "snake_case.name~1"),
      ("Fix CI chat", "Fix%20CI%20chat"),
      ("posthog-code/flag-evaluations-table", "posthog-code%2Fflag-evaluations-table"),
      ("a+b", "a%2Bb"),
      ("100%", "100%25"),
      ("a;b", "a%3Bb"),
      ("a?b#c", "a%3Fb%23c"),
      ("a&b=c", "a%26b%3Dc"),
      ("a:b@c", "a%3Ab%40c"),
      ("café", "caf%C3%A9"),
    ] as [(String, String)])
  func urlForANameEncodesEverythingButUnreservedCharacters(_ name: String, _ path: String) {
    #expect(SessionLink.url(forName: name).absoluteString == "switchboard://session/\(path)")
  }

  /// Names that are not id-shaped and not a dot segment, chosen to need every kind of encoding.
  private static let roundTripNames = [
    "fix-cache", "Fix CI chat", "posthog-code/flag-evaluations-table", "100%", "a+b", "a%2Fb", "café", "日本語",
    "naïve ümlaut", "Fix `sb ls` *now* <x>", "a]b[c\\d", "snake_case_name", "a;b", "a?b#c", "Manager", "session",
    "SEB4EC", "seb4e", "seb4ec ", " seb4ec", "~tilde", ".hidden", "emoji 🚀", "e\u{301}", "swb_", "swb_eb4e",
    "swb_eb4ec1", "SWB_eb4ec", "swb-eb4ec", "swb_eb4ec ",
    String(repeating: "é", count: 200),
  ]

  @Test(arguments: roundTripNames)
  func targetFromTheURLForANameIsThatName(_ name: String) {
    #expect(SessionLink.target(from: SessionLink.url(forName: name)) == .name(name))
  }

  /// Launch Services hands the app a URL parsed from text, so the round trip goes through the text.
  @Test(arguments: roundTripNames)
  func targetFromTheTextOfTheURLForANameIsThatName(_ name: String) throws {
    #expect(try target(SessionLink.url(forName: name).absoluteString) == .name(name))
  }

  @Test(arguments: roundTripNames)
  func theURLForANameHoldsOnlyUnreservedCharactersAndEscapes(_ name: String) {
    let path = SessionLink.url(forName: name).absoluteString.dropFirst("switchboard://session/".count)
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%")

    #expect(path.allSatisfy(allowed.contains), "\(path)")
  }

  /// Every id character is unreserved, so without an escape the name link of an id-shaped name would be the id
  /// link of the session that has that id.
  @Test(arguments: ids)
  func theURLForAnIdShapedNameIsNotTheIdLinkAndIsRefused(_ name: String) throws {
    let url = SessionLink.url(forName: name)

    #expect(url != SessionLink.url(for: name))
    #expect(url.absoluteString == "switchboard://session/%73\(name.dropFirst())")
    #expect(SessionLink.target(from: url) == nil)
    #expect(try target(url.absoluteString) == nil)
  }

  @Test(arguments: [".", ".."])
  func theURLForADotNameIsRefused(_ name: String) throws {
    let url = SessionLink.url(forName: name)

    #expect(SessionLink.target(from: url) == nil)
    #expect(try target(url.absoluteString) == nil)
  }

  // MARK: resolve

  private static let sessions: [(id: String, name: String)] = [
    (id: "seb4ec", name: "fix-cache"),
    (id: "sgcctv", name: "Fix CI chat"),
    (id: "s23456", name: "posthog-code/flag-evaluations-table"),
    (id: "swb_eb4ec", name: "new-id-form"),
  ]

  @Test func anIdTargetResolvesToTheSessionWithThatId() {
    #expect(SessionLink.resolve(.id("sgcctv"), in: Self.sessions) == .session("sgcctv"))
  }

  @Test func anIdTargetThatNoSessionHasIsUnknown() {
    #expect(SessionLink.resolve(.id("szzzzz"), in: Self.sessions) == .unknown)
  }

  @Test func anyTargetResolvesToUnknownInAnEmptyList() {
    #expect(SessionLink.resolve(.id("seb4ec"), in: []) == .unknown)
    #expect(SessionLink.resolve(.name("fix-cache"), in: []) == .unknown)
  }

  /// A session may have an id-shaped name. An id target still matches ids only.
  @Test func anIdTargetDoesNotMatchASessionWhoseNameIsThatId() {
    let sessions: [(id: String, name: String)] = [(id: "sgcctv", name: "seb4ec")]

    #expect(SessionLink.resolve(.id("seb4ec"), in: sessions) == .unknown)
  }

  @Test func anIdTargetPrefersTheIdOverAnotherSessionsMatchingName() {
    let sessions: [(id: String, name: String)] = [(id: "sgcctv", name: "seb4ec"), (id: "seb4ec", name: "fix-cache")]

    #expect(SessionLink.resolve(.id("seb4ec"), in: sessions) == .session("seb4ec"))
  }

  @Test(arguments: ["fix-cache", "Fix CI chat", "posthog-code/flag-evaluations-table"])
  func aNameTargetResolvesToTheOneSessionWithThatName(_ name: String) throws {
    let id = try #require(Self.sessions.first { $0.name == name }?.id)

    #expect(SessionLink.resolve(.name(name), in: Self.sessions) == .session(id))
  }

  @Test func aNameTargetThatNoSessionHasIsUnknown() {
    #expect(SessionLink.resolve(.name("docs-refresh"), in: Self.sessions) == .unknown)
  }

  @Test func aNameTargetThatTwoSessionsShareIsAmbiguous() {
    let sessions = Self.sessions + [(id: "sdcs7r", name: "fix-cache")]

    #expect(SessionLink.resolve(.name("fix-cache"), in: sessions) == .ambiguous(2))
  }

  /// The app's list can hold a session twice, which is still one session.
  @Test func aNameTargetListedTwiceForOneSessionResolvesToIt() {
    let sessions = Self.sessions + [(id: "seb4ec", name: "fix-cache")]

    #expect(SessionLink.resolve(.name("fix-cache"), in: sessions) == .session("seb4ec"))
  }

  @Test func aNameTargetThatThreeSessionsShareCountsAllThree() {
    let sessions = Self.sessions + [(id: "sdcs7r", name: "fix-cache"), (id: "smgr3a", name: "fix-cache")]

    #expect(SessionLink.resolve(.name("fix-cache"), in: sessions) == .ambiguous(3))
  }

  @Test(arguments: ["Fix-Cache", "FIX-CACHE", "fix-cache ", " fix-cache", "fix cache", "fix-cach", "fix-cache-v2"])
  func aNameTargetMatchesOnlyTheExactCaseSensitiveName(_ name: String) {
    #expect(SessionLink.resolve(.name(name), in: Self.sessions) == .unknown)
  }

  /// Q4: no id prefixes, and a name never matches an id.
  @Test(arguments: ["seb4e", "seb4", "s", "seb4ec", "SEB4EC", "sgcc", "swb_", "swb_eb4", "swb_eb4ec"])
  func aNameTargetNeverMatchesAnIdOrAnIdPrefix(_ name: String) {
    #expect(SessionLink.resolve(.name(name), in: Self.sessions) == .unknown)
  }

  @Test func anUpperCaseIdNameResolvesToASessionWithExactlyThatName() {
    let sessions = Self.sessions + [(id: "sdcs7r", name: "SEB4EC")]

    #expect(SessionLink.resolve(.name("SEB4EC"), in: sessions) == .session("sdcs7r"))
  }

  /// The two paths that select a session agree: a link that `target(from:)` reads from text resolves as the
  /// target built directly.
  @Test(
    arguments: [
      ("switchboard://session/seb4ec", "seb4ec"),
      ("switchboard://session/Fix%20CI%20chat", "sgcctv"),
      ("switchboard://session/posthog-code%2Fflag-evaluations-table", "s23456"),
      ("switchboard://session/swb_eb4ec", "swb_eb4ec"),
      ("switchboard://session/new-id-form", "swb_eb4ec"),
    ] as [(String, String)])
  func aParsedLinkResolvesToItsSession(_ string: String, _ id: String) throws {
    let parsed = try #require(try target(string))

    #expect(SessionLink.resolve(parsed, in: Self.sessions) == .session(id))
  }

  // MARK: markdown(name:id:)

  @Test func markdownForASlugNameIsALinkWithNoEscapes() {
    #expect(SessionLink.markdown(name: "fix-cache", id: "seb4ec") == "[fix-cache](switchboard://session/seb4ec)")
  }

  /// Decision 7 does not use `MarkdownText.escaped`, which escapes a line-start `-` and puts a word joiner before `@`.
  @Test(
    arguments: [
      ("-x", "[-x](switchboard://session/seb4ec)"),
      ("@haacked", "[@haacked](switchboard://session/seb4ec)"),
      ("Fix CI chat", "[Fix CI chat](switchboard://session/seb4ec)"),
    ] as [(String, String)])
  func markdownEscapesOnlyTheCharactersThatMarkdownReads(_ name: String, _ markdown: String) {
    #expect(SessionLink.markdown(name: name, id: "seb4ec") == markdown)
  }

  @Test func markdownReplacesANewlineInTheNameWithASpace() {
    #expect(!SessionLink.markdown(name: "line one\nline two", id: "seb4ec").contains("\n"))
  }

  /// The one paragraph that cmark reads from `markdown`.
  private func paragraph(_ markdown: String) throws -> MarkdownText {
    let blocks = MarkdownBlock.parse(markdown)
    try #require(blocks.count == 1, "\(markdown) parses to \(blocks)")
    guard case .paragraph(let text) = blocks[0] else {
      Issue.record("\(markdown) parses to \(blocks[0]), not a paragraph")
      return MarkdownText()
    }
    return text
  }

  /// Each name holds characters that cmark would read as code, emphasis, HTML, an entity, a link, or a line break.
  @Test(
    arguments: [
      ("fix-cache", "fix-cache"),
      ("a]b[c\\d", "a]b[c\\d"),
      ("Fix `sb ls` *now* <x>", "Fix `sb ls` *now* <x>"),
      ("snake_case_name", "snake_case_name"),
      ("line one\nline two", "line one line two"),
      ("R&amp;D notes", "R&amp;D notes"),
      ("a ~~b~~ | #c !d", "a ~~b~~ | #c !d"),
      ("[x](y)", "[x](y)"),
      ("<b>bold</b>", "<b>bold</b>"),
      ("ask @haacked", "ask @haacked"),
      ("- item", "- item"),
      ("trailing\\", "trailing\\"),
      ("a\r\nb", "a b"),
      ("see https://example.com now", "see https://example.com now"),
      ("www.example.com", "www.example.com"),
      ("mail a@b.com", "mail a@b.com"),
    ] as [(String, String)])
  func markdownReadsBackAsOneLinkRunWithTheNameAndTheIdURL(_ name: String, _ text: String) throws {
    let read = try paragraph(SessionLink.markdown(name: name, id: "seb4ec"))

    try #require(read.runs.count == 1, "\(read.runs)")
    #expect(read.runs[0].text == text)
    #expect(read.runs[0].link == "switchboard://session/seb4ec")
    #expect(read.runs[0].style == [])
  }

  /// The Copy Link URL selects the session by its id, whatever the name says.
  @Test(
    arguments: ["fix-cache", "a]b[c\\d", "Fix `sb ls` *now* <x>", "sgcctv", "snake_case_name", "swb_eb4ec"],
    ["seb4ec", "swb_eb4ec"])
  func theLinkThatMarkdownWritesParsesAsTheIdTarget(_ name: String, _ id: String) throws {
    let read = try paragraph(SessionLink.markdown(name: name, id: id))
    let link = try #require(read.runs.first?.link)

    #expect(try target(link) == .id(id))
  }

  // MARK: Guidance

  @Test func theGuidanceNamesTheURLField() {
    #expect(SessionLink.guidance.contains("`url`"), "\(SessionLink.guidance)")
  }

  @Test func theGuidanceShowsASessionLink() {
    #expect(SessionLink.guidance.contains("](switchboard://session/"), "\(SessionLink.guidance)")
  }

  /// An agent copies the example, so it shows the form that new sessions get.
  @Test func theGuidanceExampleLinksANewFormId() {
    #expect(SessionLink.guidance.contains("](switchboard://session/swb_eb4ec)"), "\(SessionLink.guidance)")
  }

  /// An agent copies the example, so each link in it must parse as an id target.
  @Test func everyLinkInTheGuidanceParsesAsAnIdTarget() throws {
    let pattern = try Regex(#"switchboard://session/[^)\s]*"#)
    let links = SessionLink.guidance.matches(of: pattern).map { String(SessionLink.guidance[$0.range]) }

    try #require(!links.isEmpty, "\(SessionLink.guidance)")
    for link in links {
      let parsed = try target(link)
      guard case .id = parsed else {
        Issue.record("\(link) parses to \(String(describing: parsed)), not an id target")
        continue
      }
    }
  }

  @Test func theManagerGuideHoldsTheGuidance() {
    #expect(Manager.guide.contains(SessionLink.guidance))
  }

  @Test func theChatGuideHoldsTheGuidance() {
    #expect(Chat.guide.contains(SessionLink.guidance))
  }

  @Test(arguments: [nil, "Ship the flags work."] as [String?])
  func theChatGuideForAGroupHoldsTheGuidance(_ description: String?) {
    #expect(Chat.guide(description: description).contains(SessionLink.guidance))
  }

  @Test func theDefaultSystemPromptHoldsTheGuidance() {
    #expect(TriageSettings().systemPrompt.contains(SessionLink.guidance))
  }

  // MARK: SessionSummary.url

  /// An older sbd sends no `url` key, and the app still decodes its summaries.
  @Test func aSummaryWithoutTheURLKeyDecodesWithNoURL() throws {
    let summary = SessionSummary(
      id: "seb4ec", name: "fix-cache", cwd: "/", repo: nil, branch: nil, claudeSessionId: "c", state: .working,
      reason: "", since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [],
      notes: [])
    var object = try #require(try JSON(encoding: summary).object)
    object["url"] = nil

    let decoded = try JSONCoding.decode(SessionSummary.self, from: JSON.object(object).text)

    #expect(decoded.url == nil)
  }
}
