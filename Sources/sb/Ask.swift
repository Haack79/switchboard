import Foundation
import SwitchboardCore

func askCommand(_ a: Args) {
  let question = a.positional.joined(separator: " ")
  if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { die("usage: sb ask <question>") }
  let result = call("quick-ask", ["question": .string(question)], timeout: QuickAsk.clientTimeout)
  if a.json { return printJSON(result) }
  print(decode(result, as: QuickAskAnswer.self).answer)
}
