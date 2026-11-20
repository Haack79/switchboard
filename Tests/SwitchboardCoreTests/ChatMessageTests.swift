import Testing

@testable import SwitchboardCore

@Suite struct ChatMessageTests {
  // MARK: isNotice

  @Test(
    arguments: [
      (ChatMessage.Role.user, "Switchboard: posthog-123 needs you.", true),
      (.user, "Switchboard:", true),
      (.user, "Note from Switchboard: posthog-123 needs you.", false),
      (.user, "switchboard: posthog-123 needs you.", false),
      (.user, "Switchboard posthog-123 needs you.", false),
      (.assistant, "Switchboard: posthog-123 needs you.", false),
    ] as [(ChatMessage.Role, String, Bool)])
  func aNoticeIsAUserMessageThatStartsWithTheSwitchboardPrefix(_ role: ChatMessage.Role, _ text: String, _ notice: Bool)
  {
    #expect(ChatMessage(role: role, text: text).isNotice == notice)
  }

  // MARK: commandOutput

  @Test(
    arguments: [
      ("<local-command-stdout>Set model to opus</local-command-stdout>", "Set model to opus"),
      ("<local-command-stdout>(no content)</local-command-stdout>", "(no content)"),
      ("<local-command-stdout></local-command-stdout>", ""),
      ("\n<local-command-stdout>\n Login successful \n</local-command-stdout>\n", "Login successful"),
      ("<local-command-stderr>Unknown model</local-command-stderr>", "Unknown model"),
    ])
  func aBuiltInCommandsOutputLineGivesItsText(_ text: String, _ output: String) {
    #expect(ChatMessage(role: .user, text: text).commandOutput == output)
  }

  @Test(
    arguments: [
      (ChatMessage.Role.assistant, "<local-command-stdout>Set model to opus</local-command-stdout>"),
      (.user, "<local-command-stdout>Set model to opus"),
      (.user, "Why does <local-command-stdout>x</local-command-stdout> show?"),
      (.user, "<local-command-stdout>x</local-command-stdout> and more"),
      (.user, "<command-name>/clear</command-name>"),
      (.user, ""),
    ] as [(ChatMessage.Role, String)])
  func aMessageThatIsNotACommandsOutputHasNone(_ role: ChatMessage.Role, _ text: String) {
    #expect(ChatMessage(role: role, text: text).commandOutput == nil)
  }
}
