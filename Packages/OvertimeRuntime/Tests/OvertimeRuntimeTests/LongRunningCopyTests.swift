import Foundation
import OvertimeAppSupport
import Testing

struct LongRunningCopyTests {
  static let allowedCapitalWords: Set<String> = ["Claude", "Mac", "Agent", "SDK"]

  static var labels: [String] {
    [
      LongRunningCopy.sectionTitle, LongRunningCopy.backgroundCommandsLabel, LongRunningCopy.printRunsLabel,
      LongRunningCopy.limitLabel, LongRunningCopy.limitFieldLabel,
    ]
  }

  static var captions: [String] {
    [
      LongRunningCopy.backgroundCommandsCaption, LongRunningCopy.printRunsCaption, LongRunningCopy.limitCaption,
      LongRunningCopy.entrypointsCaption,
    ]
  }

  @Test func theLongRunningCopyIsVerbatim() {
    #expect(LongRunningCopy.sectionTitle == "Long-running work")
    #expect(LongRunningCopy.backgroundCommandsLabel == "Keep awake while Claude waits on a background command")
    #expect(
      LongRunningCopy.backgroundCommandsCaption
        == "A command Claude Code started in the background, such as a build, a test run or a script, keeps the Mac awake until it ends, even after Claude's turn is over. A dev server Claude started also keeps the Mac awake for as long as it runs and its session is open: stop the server, turn this off, or set a time limit."
    )
    #expect(LongRunningCopy.printRunsLabel == "Keep awake while claude -p runs")
    #expect(
      LongRunningCopy.printRunsCaption
        == "A non-interactive Claude Code run (claude -p) keeps the Mac awake until it exits, whether a terminal, a script or a scheduled job started it. Agent SDK scripts are not counted."
    )
    #expect(LongRunningCopy.limitLabel == "Stop after a time limit")
    #expect(LongRunningCopy.limitFieldLabel == "Time limit")
    #expect(
      LongRunningCopy.limitCaption
        == "Off by default, so there is no limit. When it is on, a background command stops counting this long after Claude's last activity, and a claude -p run this long after it started. Battery and temperature protection, Pause and Sleep Now always apply."
    )
    #expect(
      LongRunningCopy.entrypointsCaption
        == "Transcripts whose entrypoint matches are not counted as Claude working. The default, sdk-*, ignores the transcripts of claude -p and Agent SDK automations. A claude -p run still keeps the Mac awake while it runs; see Long-running work."
    )
  }

  @Test func theCopyHasNoBannedWordsAndUsesSentenceCase() {
    for label in Self.labels {
      #expect(label.first?.isUppercase == true, "\(label)")
      #expect(!LabelCaseTests.titleCaseFindings(label).isEmpty, "\(label)")
      let laterWords = label.split(separator: " ").dropFirst().map(String.init)
      for word in laterWords where word.contains(where: \.isUppercase) {
        #expect(Self.allowedCapitalWords.contains(word), "\(label): \(word)")
      }
    }
    for text in Self.labels + Self.captions {
      #expect(!text.isEmpty)
      #expect(!text.lowercased().contains(RemovedToolGateTests.folderName), "\(text)")
      #expect(
        text.range(of: RemovedToolGateTests.namePattern, options: [.regularExpression, .caseInsensitive]) == nil,
        "\(text)")
    }
  }
}
