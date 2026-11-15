import Foundation
import Testing
import os

@testable import SwitchboardCore

/// A CI runner has 3 CPUs and runs threads several times slower than a laptop does.
private let scale: Double = ProcessInfo.processInfo.environment["CI"] == nil ? 1 : 3

/// How a call that ran on another thread ended.
private enum CallOutcome: Equatable, Sendable {
  case value(JSON)
  case cancelled
  case failed(String)
}

/// A `Client.call` on a global queue. Without a token, it calls the method as the callers that predate the token
/// do. `wait` returns its outcome, or nil while it still runs.
private final class BackgroundCall: Sendable {
  private let outcome = OSAllocatedUnfairLock<CallOutcome?>(initialState: nil)
  private let done = DispatchSemaphore(value: 0)

  init(_ client: Client, _ op: String, timeout: TimeInterval = 30, cancel: CallCancel?) {
    DispatchQueue.global().async { [outcome, done] in
      let result: CallOutcome
      do {
        if let cancel {
          result = .value(try client.call(op, [:], timeout: timeout, cancel: cancel))
        } else {
          result = .value(try client.call(op, [:], timeout: timeout))
        }
      } catch is CancellationError {
        result = .cancelled
      } catch {
        result = .failed("\(error)")
      }
      outcome.withLock { $0 = result }
      done.signal()
    }
  }

  /// The outcome once the call ends within the seconds, or nil.
  func wait(_ seconds: Double) -> CallOutcome? {
    guard done.wait(timeout: .now() + seconds * scale) == .success else { return nil }
    return outcome.withLock { $0 }
  }
}

/// The client of the socket at `path`. `Home.socket` is `<folder>/sbd.sock`, which `withListener` creates.
private func client(_ path: String) -> Client {
  Client(home: Home(path: (path as NSString).deletingLastPathComponent))
}

/// Reads and discards until the peer's end closes, and returns true then. It returns false when nothing closes the
/// connection within the seconds. `peerClosed` peeks at one byte, so it reads false while the request is unread.
private func readsToEnd(_ fd: Int32, within seconds: Int) -> Bool {
  var tv = timeval(tv_sec: seconds, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let n = recv(fd, &buffer, buffer.count, 0)
    if n == 0 { return true }
    if n < 0 { return false }
  }
}

/// sbd's success response with the result, as one line.
private func successLine(_ result: String) -> Data { Data((#"{"ok":true,"result":\#(result)}"# + "\n").utf8) }

/// Reads the request line that the client sent.
private func readRequest(_ fd: Int32) throws -> Request {
  var reader = UnixSocket.LineReader(fd: fd)
  let line = try #require(try reader.next())
  return try JSONCoding.decoder.decode(Request.self, from: line)
}

/// `CallCancel` ends a `Client.call` from another thread by shutting down the call's socket. The app's quick ask
/// panel cancels its call this way when it closes, and sbd sees the connection close and ends the claude run.
@Suite(.timeLimit(.minutes(1))) struct CallCancelTests {
  @Test func aCancelDuringACallThrowsCancellationErrorWithinOneSecond() throws {
    try withListener { listener, path in
      let token = CallCancel()
      let call = BackgroundCall(client(path), "quick-ask", cancel: token)
      let server = try acceptOne(listener)
      defer { close(server) }
      usleep(200_000)
      try #require(call.wait(0) == nil, "the call ended before the cancel")

      token.cancel()

      #expect(call.wait(1) == .cancelled)
    }
  }

  @Test func aCancelDuringACallMakesTheServerReadTheConnectionAsClosed() throws {
    try withListener { listener, path in
      let token = CallCancel()
      let call = BackgroundCall(client(path), "quick-ask", cancel: token)
      let server = try acceptOne(listener)
      defer { close(server) }
      usleep(200_000)

      token.cancel()

      #expect(readsToEnd(server, within: 2))
      #expect(UnixSocket.peerClosed(server))
      _ = call.wait(5)
    }
  }

  @Test func aCancelBeforeTheCallThrowsAtOnce() throws {
    try withListener { _, path in
      let token = CallCancel()
      token.cancel()
      let start = Date()

      #expect(throws: CancellationError.self) {
        try client(path).call("quick-ask", [:], timeout: 30, cancel: token)
      }
      #expect(Date().timeIntervalSince(start) < 1 * scale)
    }
  }

  @Test func aCancelledTokenReportsIsCancelled() {
    let token = CallCancel()
    #expect(!token.isCancelled)

    token.cancel()

    #expect(token.isCancelled)
  }

  @Test func aSecondCancelIsHarmless() throws {
    try withListener { listener, path in
      let token = CallCancel()
      let call = BackgroundCall(client(path), "quick-ask", cancel: token)
      let server = try acceptOne(listener)
      defer { close(server) }
      usleep(200_000)

      token.cancel()
      token.cancel()

      #expect(call.wait(1) == .cancelled)
    }
  }

  @Test func aCallThatCompletesReturnsItsResultAndIgnoresALaterCancel() throws {
    try withListener { listener, path in
      let token = CallCancel()
      let call = BackgroundCall(client(path), "quick-ask", cancel: token)
      let server = try acceptOne(listener)
      defer { close(server) }
      _ = try readRequest(server)
      try UnixSocket.write(server, successLine(#"{"answer":"Nothing needs you."}"#))
      let outcome = call.wait(5)

      token.cancel()

      #expect(outcome == .value(["answer": "Nothing needs you."]))
    }
  }

  /// The call closes its socket when it ends, and the next socket that opens can take the same descriptor number.
  /// A cancel after the call must not shut down that other socket. Other tests open descriptors in parallel and can
  /// take the freed number first, so the test opens many pairs to make one of them likely to get it.
  @Test func aCancelAfterTheCallEndedLeavesALaterSocketOnTheSameDescriptorWorking() throws {
    try withListener { listener, path in
      let token = CallCancel()
      let call = BackgroundCall(client(path), "quick-ask", cancel: token)
      let server = try acceptOne(listener)
      defer { close(server) }
      _ = try readRequest(server)
      try UnixSocket.write(server, successLine("null"))
      try #require(call.wait(5) == .value(.null))
      var pairs: [[Int32]] = []
      defer { pairs.joined().forEach { close($0) } }
      for _ in 0..<32 {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        pairs.append(pair)
      }

      token.cancel()

      for pair in pairs {
        try UnixSocket.write(pair[0], Data("still open\n".utf8))
        var reader = UnixSocket.LineReader(fd: pair[1])
        #expect(try reader.next() == Data("still open".utf8))
      }
    }
  }

  /// sbd ends a quick ask's claude when its side of the socket reads closed. A normal call must not half-close the
  /// socket after it writes the request, or every quick ask would end at once.
  @Test(arguments: [true, false])
  func aCallThatWaitsForItsAnswerDoesNotCloseItsEnd(_ withToken: Bool) throws {
    try withListener { listener, path in
      let call = BackgroundCall(client(path), "quick-ask", cancel: withToken ? CallCancel() : nil)
      let server = try acceptOne(listener)
      defer { close(server) }
      let request = try readRequest(server)
      usleep(300_000)

      let closed = UnixSocket.peerClosed(server)
      try UnixSocket.write(server, successLine("null"))

      #expect(request.op == "quick-ask")
      #expect(!closed)
      #expect(call.wait(5) == .value(.null))
    }
  }
}
