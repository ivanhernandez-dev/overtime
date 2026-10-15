import Foundation
import Testing

@testable import OvertimeCore

struct TranscriptHeaderTests {
  static let automationLine = #"{"type":"user","entrypoint":"sdk-cli"}"#
  static let interactiveLine =
    #"{"type":"user","entrypoint":"cli","message":"text with \"entrypoint\":\"sdk-cli\" inside"}"#
  static let summaryLine = #"{"type":"summary"}"#

  func line(_ text: String) -> [UInt8] {
    Array((text + "\n").utf8)
  }

  func padded(_ count: Int, then text: String, trailing: Int = 1024) -> [UInt8] {
    [UInt8](repeating: UInt8(ascii: "a"), count: count) + Array(text.utf8)
      + [UInt8](repeating: UInt8(ascii: "b"), count: trailing)
  }

  @Test func theFixtureLinesGiveTheirEntrypoints() {
    #expect(TranscriptHeader.entrypoint(in: line(Self.automationLine)) == "sdk-cli")
    #expect(TranscriptHeader.entrypoint(in: line(Self.interactiveLine)) == "cli")
    #expect(TranscriptHeader.entrypoint(in: line(Self.summaryLine)) == nil)
  }

  @Test func capIsSixtyFourKibibytes() {
    #expect(TranscriptHeader.maxBytes == 65_536)
  }

  @Test func emptyBufferHasNoEntrypoint() {
    #expect(TranscriptHeader.entrypoint(in: []) == nil)
  }

  @Test func emptyValueIsTheEmptyString() {
    #expect(TranscriptHeader.entrypoint(in: line(#"{"entrypoint":""}"#)) == "")
  }

  @Test func closingQuoteAtTheLastAllowedByteIsFound() {
    let match = #""entrypoint":"cli""#
    let bytes = padded(65_536 - match.utf8.count, then: match)
    #expect(bytes[65_535] == UInt8(ascii: "\""))
    #expect(TranscriptHeader.entrypoint(in: bytes) == "cli")
  }

  @Test func anEntrypointOfUpTo128BytesIsRead() {
    let value = String(repeating: "a", count: TranscriptHeader.maxEntrypointBytes)
    #expect(TranscriptHeader.entrypoint(in: line(#"{"entrypoint":""# + value + #""}"#)) == value)
  }

  @Test func anOverlongEntrypointCountsAsNone() {
    let value = "sdk-" + String(repeating: "a", count: 60_000)
    #expect(TranscriptHeader.entrypoint(in: line(#"{"entrypoint":""# + value + #""}"#)) == nil)
  }

  @Test func closingQuotePastTheCapIsNotFound() {
    let match = #""entrypoint":"cli""#
    let bytes = padded(65_536 - match.utf8.count + 1, then: match)
    #expect(bytes[65_536] == UInt8(ascii: "\""))
    #expect(TranscriptHeader.entrypoint(in: bytes) == nil)
  }

  @Test func firstOccurrenceWins() {
    #expect(
      TranscriptHeader.entrypoint(in: line(#"{"entrypoint":"cli"}"# + "\n" + #"{"entrypoint":"sdk-cli"}"#)) == "cli")
    #expect(
      TranscriptHeader.entrypoint(in: line(#"{"entrypoint":"sdk-cli"}"# + "\n" + #"{"entrypoint":"cli"}"#))
        == "sdk-cli")
  }

  @Test func unterminatedFirstOccurrenceIsNotRescued() {
    let bytes = padded(65_536 - 20, then: #""entrypoint":"sdk-cli""#) + line(#"{"entrypoint":"cli"}"#)
    #expect(TranscriptHeader.entrypoint(in: bytes) == nil)
  }

  @Test func spaceAfterTheColonIsNotRecognized() {
    #expect(TranscriptHeader.entrypoint(in: line(#"{"entrypoint": "cli"}"#)) == nil)
  }

  @Test func escapedMentionNeverMatches() {
    #expect(TranscriptHeader.entrypoint(in: line(#"{"message":"\"entrypoint\":\"sdk-cli\""}"#)) == nil)
  }

  @Test func binaryGarbageHasNoEntrypoint() {
    var generator = SeededGenerator(seed: 0x5EED)
    let bytes = (0..<200_000).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
    #expect(TranscriptHeader.entrypoint(in: bytes) == nil)
  }

  @Test func megabyteLineWithoutTheKeyInTheCapHasNoEntrypoint() {
    #expect(TranscriptHeader.entrypoint(in: [UInt8](repeating: UInt8(ascii: "x"), count: 1_048_576)) == nil)
    #expect(TranscriptHeader.entrypoint(in: padded(70_000, then: #""entrypoint":"cli""#)) == nil)
  }

  @Test func decodesMultibyteUTF8Values() {
    #expect(TranscriptHeader.entrypoint(in: line(#"{"entrypoint":"ñandú"}"#)) == "ñandú")
  }

  struct SeededGenerator {
    var state: UInt64

    init(seed: UInt64) {
      state = seed
    }

    mutating func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state >> 33
    }
  }

  struct Glob {
    @Test func sdkPrefixPattern() {
      for value in ["sdk-cli", "sdk-py", "sdk-ts", "sdk-"] {
        #expect(EntrypointGlob.matches(pattern: "sdk-*", value: value), "\(value)")
      }
      for value in ["cli", "SDK-cli", "xsdk-cli", "sdk", ""] {
        #expect(!EntrypointGlob.matches(pattern: "sdk-*", value: value), "\(value)")
      }
    }

    @Test func starMatchesEverythingIncludingTheEmptyString() {
      for value in ["", "cli", "sdk-cli", "ñ"] {
        #expect(EntrypointGlob.matches(pattern: "*", value: value), "\(value)")
      }
    }

    @Test func patternWithoutAStarIsExact() {
      #expect(EntrypointGlob.matches(pattern: "cli", value: "cli"))
      #expect(!EntrypointGlob.matches(pattern: "cli", value: "cli2"))
      #expect(!EntrypointGlob.matches(pattern: "cli", value: "cl"))
      #expect(!EntrypointGlob.matches(pattern: "cli", value: "CLI"))
      #expect(EntrypointGlob.matches(pattern: "", value: ""))
      #expect(!EntrypointGlob.matches(pattern: "", value: "cli"))
    }

    @Test func innerAndRepeatedStars() {
      #expect(EntrypointGlob.matches(pattern: "a*c", value: "abc"))
      #expect(EntrypointGlob.matches(pattern: "a*c", value: "ac"))
      #expect(!EntrypointGlob.matches(pattern: "a*c", value: "ab"))
      #expect(EntrypointGlob.matches(pattern: "*-cli", value: "sdk-cli"))
      #expect(EntrypointGlob.matches(pattern: "s*-*i", value: "sdk-cli"))
      #expect(EntrypointGlob.matches(pattern: "**", value: "x"))
      #expect(!EntrypointGlob.matches(pattern: "a*b*c", value: "acb"))
    }

    @Test func questionMarkAndBracketsAreLiterals() {
      #expect(!EntrypointGlob.matches(pattern: "cl?", value: "cli"))
      #expect(EntrypointGlob.matches(pattern: "cl?", value: "cl?"))
      #expect(!EntrypointGlob.matches(pattern: "[c]li", value: "cli"))
    }

    @Test func matchesAnyOverTheList() {
      #expect(!EntrypointGlob.matchesAny([], value: "sdk-cli"))
      #expect(EntrypointGlob.matchesAny(["cli", "sdk-*"], value: "sdk-py"))
      #expect(!EntrypointGlob.matchesAny(["cli", "sdk-*"], value: "desktop"))
    }
  }

  struct ReducerVerdicts {
    let t0 = Instant(nanoseconds: 10_000_000_000_000)

    func stamp(_ event: Event, at mono: Instant) -> Stamped<Event> {
      Stamped(mono: mono, wall: Date(timeIntervalSince1970: 1_800_000_000), event: event)
    }

    func entrypointLog(_ value: String, ignored: Bool) -> Effect {
      .log(
        Decision(
          keyword: .entrypoint,
          verb: "new",
          fields: [
            DecisionField(key: "value", value: value),
            DecisionField(key: "ignored", value: ignored ? "true" : "false"),
          ]
        ))
    }

    func busyAfter(_ entrypoint: String?, settings: Settings = Settings()) -> (AppState, [Effect]) {
      var state = AppState(mode: .shadow)
      let activity = TranscriptActivity(at: t0, entrypoint: entrypoint)
      let logged = Reducer.reduce(&state, stamp(.transcriptActivity(activity), at: t0), settings)
      _ = Reducer.reduce(&state, stamp(.tick(TickFacts()), at: t0), settings)
      return (state, logged)
    }

    @Test func ignoredEntrypointNeverSetsBusy() {
      let (state, logged) = busyAfter("sdk-py")
      #expect(logged == [entrypointLog("sdk-py", ignored: true)])
      #expect(state.busy.busy == false)
      #expect(state.busy.lastEligibleTranscript == nil)
      #expect(state.busy.lastTranscriptEventAt == t0)
      #expect(state.want.wanted == false)
    }

    @Test func cliAndMissingEntrypointsCount() {
      #expect(busyAfter("cli").0.busy.busy == true)
      #expect(busyAfter(nil).0.busy.busy == true)
      #expect(busyAfter(nil).1.isEmpty)
    }

    @Test func emptyEntrypointIsNotMatchedBySdkStar() {
      let (state, logged) = busyAfter("")
      #expect(state.busy.busy == true)
      #expect(logged == [entrypointLog("", ignored: false)])
    }

    @Test func emptyIgnoreListIgnoresNothing() {
      let (state, logged) = busyAfter("sdk-py", settings: Settings(ignoredEntrypoints: []))
      #expect(state.busy.busy == true)
      #expect(logged == [entrypointLog("sdk-py", ignored: false)])
    }

    @Test func eachNewEntrypointValueIsLoggedOnce() {
      var state = AppState(mode: .shadow)
      let settings = Settings()
      func send(_ entrypoint: String?) -> [Effect] {
        Reducer.reduce(
          &state, stamp(.transcriptActivity(TranscriptActivity(at: t0, entrypoint: entrypoint)), at: t0), settings)
      }
      #expect(send("cli") == [entrypointLog("cli", ignored: false)])
      #expect(send("cli") == [])
      #expect(send("sdk-py") == [entrypointLog("sdk-py", ignored: true)])
      #expect(send(nil) == [])
      #expect(send("sdk-py") == [])
      #expect(state.busy.seenEntrypoints == ["cli", "sdk-py"])
    }

    @Test func loggedValuesAreSanitizedAndBounded() {
      var state = AppState(mode: .shadow)
      let hostile = "cli\nWANT on reason=busy" + String(repeating: "z", count: 500)
      let effects = Reducer.reduce(
        &state, stamp(.transcriptActivity(TranscriptActivity(at: t0, entrypoint: hostile)), at: t0), Settings())
      guard case .log(let decision)? = effects.first else {
        Issue.record("expected an ENTRYPOINT log")
        return
      }
      let value = decision.fields.first { $0.key == "value" }?.value ?? ""
      #expect(!value.contains("\n"))
      #expect(value.unicodeScalars.count <= Reducer.maxLoggedEntrypointLength)
      #expect(state.busy.seenEntrypoints == [value])
    }

    @Test func seenEntrypointSetIsBounded() {
      var state = AppState(mode: .shadow)
      for index in 0..<(Reducer.maxSeenEntrypoints + 50) {
        _ = Reducer.reduce(
          &state, stamp(.transcriptActivity(TranscriptActivity(at: t0, entrypoint: "e\(index)")), at: t0), Settings())
      }
      #expect(state.busy.seenEntrypoints.count == Reducer.maxSeenEntrypoints)
    }
  }
}
