import Foundation
import Testing

@testable import OvertimeCore

struct LearnedConfigDirectoriesTests {
  static func at(_ seconds: Double) -> Instant {
    Instant(nanoseconds: 0).adding(seconds: seconds)
  }

  static func learned(_ root: String) -> Decision {
    Decision(keyword: .check, verb: "transcriptRoot learned", fields: [DecisionField(key: "root", value: root)])
  }

  static func forgotten(_ root: String) -> Decision {
    Decision(keyword: .check, verb: "transcriptRoot forgotten", fields: [DecisionField(key: "root", value: root)])
  }

  @Test func aDirectoryIsLearnedOnItsFirstSighting() {
    var learned = LearnedConfigDirectories()
    #expect(learned.observe(["/cfg"], at: Self.at(0)) == [Self.learned("/cfg/projects")])
    #expect(learned.active() == ["/cfg"])
    #expect(learned.observe(["/cfg"], at: Self.at(2)) == [])
    #expect(learned.active() == ["/cfg"])
  }

  @Test func aDirectoryStaysForTheLingerAndIsForgottenAtItsEnd() {
    var learned = LearnedConfigDirectories()
    _ = learned.observe(["/cfg"], at: Self.at(0))
    #expect(learned.observe([], at: Self.at(599.999)) == [])
    #expect(learned.active() == ["/cfg"])
    #expect(learned.observe([], at: Self.at(600)) == [Self.forgotten("/cfg/projects")])
    #expect(learned.active().isEmpty)
  }

  @Test func aDirectorySeenAgainBeforeTheEndStartsANewLinger() {
    var learned = LearnedConfigDirectories()
    _ = learned.observe(["/cfg"], at: Self.at(0))
    #expect(learned.observe(["/cfg"], at: Self.at(500)) == [])
    #expect(learned.observe([], at: Self.at(1000)) == [])
    #expect(learned.active() == ["/cfg"])
    #expect(learned.observe([], at: Self.at(1100)) == [Self.forgotten("/cfg/projects")])
    #expect(learned.active().isEmpty)
  }

  @Test func aForgottenDirectoryIsLearnedAgainWhenSeenAgain() {
    var learned = LearnedConfigDirectories()
    _ = learned.observe(["/cfg"], at: Self.at(0))
    #expect(learned.observe([], at: Self.at(600)) == [Self.forgotten("/cfg/projects")])
    #expect(learned.observe(["/cfg"], at: Self.at(602)) == [Self.learned("/cfg/projects")])
    #expect(learned.active() == ["/cfg"])
  }

  @Test func equivalentSpellingsAreOneDirectoryAndRelativeOnesAreIgnored() {
    var learned = LearnedConfigDirectories()
    let decisions = learned.observe(["/cfg", "/cfg/", "/cfg//.", "cfg", "~/cfg", ""], at: Self.at(0))
    #expect(decisions == [Self.learned("/cfg/projects")])
    #expect(learned.active() == ["/cfg"])
    #expect(Array(learned.lastSeen.keys) == ["/cfg/projects"])
  }

  @Test func atMostEightDirectoriesAreActive() {
    var learned = LearnedConfigDirectories()
    let all = (1...9).map { "/d\($0)" }
    #expect(learned.observe(all, at: Self.at(0)) == (1...8).map { Self.learned("/d\($0)/projects") })
    #expect(learned.active() == Array(all.prefix(8)))
    #expect(
      learned.observe(Array(all.dropFirst()), at: Self.at(600)) == [
        Self.forgotten("/d1/projects"), Self.learned("/d9/projects"),
      ])
    #expect(learned.active() == Array(all.dropFirst()))
  }

  @Test func theLoggedRootIsSanitized() {
    var learned = LearnedConfigDirectories()
    #expect(learned.observe(["/tmp/evil\nWANT on"], at: Self.at(0)) == [Self.learned("/tmp/evil?WANT on/projects")])
  }

  @Test func aLargeClockJumpKeepsTheFoldersSeenOnTheFirstTickAfterItAndForgetsTheRest() {
    var learned = LearnedConfigDirectories()
    _ = learned.observe(["/kept", "/gone"], at: Self.at(0))
    #expect(learned.observe(["/kept"], at: Self.at(86_400)) == [Self.forgotten("/gone/projects")])
    #expect(learned.active() == ["/kept"])
    #expect(learned.observe([], at: Self.at(86_400 + 599)) == [])
    #expect(learned.active() == ["/kept"])
  }
}
