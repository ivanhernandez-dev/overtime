import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

@testable import Overtime

@MainActor
struct DetectionPaneTests {
  typealias Fixture = GeneralPaneTests.Fixture

  static let limitMessage = "Enter a whole number of minutes from 15 to 720."

  @Test func theLongRunningDefaultsShowOnOnAndNoLimit() throws {
    let fixture = try Fixture()
    #expect(fixture.fileSettings == nil)
    #expect(fixture.model.backgroundCommandsKeepAwake)
    #expect(fixture.model.printRunsKeepAwake)
    #expect(!fixture.model.longRunningLimitEnabled)
    #expect(fixture.model.text(for: .longRunningLimitMinutes) == "120")
  }

  @Test func eachSwitchSavesAndApplies() async throws {
    let fixture = try Fixture()
    let model = fixture.model
    #expect(await model.setBackgroundCommandsKeepAwake(false) == .applied)
    #expect(fixture.fileSettings?.backgroundCommandsKeepAwake == false)
    #expect(fixture.host.appliedSettings.last?.backgroundCommandsKeepAwake == false)
    #expect(!model.backgroundCommandsKeepAwake)
    #expect(await model.setBackgroundCommandsKeepAwake(false) == nil)

    #expect(await model.setPrintRunsKeepAwake(false) == .applied)
    #expect(fixture.fileSettings?.printRunsKeepAwake == false)
    #expect(fixture.host.appliedSettings.last?.printRunsKeepAwake == false)
    #expect(!model.printRunsKeepAwake)
    #expect(await model.setPrintRunsKeepAwake(false) == nil)

    #expect(await model.setLongRunningLimitEnabled(true) == .applied)
    #expect(fixture.fileSettings?.longRunningLimitEnabled == true)
    #expect(fixture.host.appliedSettings.last?.longRunningLimitEnabled == true)
    #expect(model.longRunningLimitEnabled)
    #expect(await model.setLongRunningLimitEnabled(true) == nil)
    #expect(fixture.host.appliedSettings.count == 3)

    #expect(await model.setBackgroundCommandsKeepAwake(true) == .applied)
    #expect(await model.setPrintRunsKeepAwake(true) == .applied)
    #expect(await model.setLongRunningLimitEnabled(false) == .applied)
    #expect(fixture.fileSettings == Settings())
    #expect(fixture.host.appliedSettings.count == 6)
  }

  @Test func enablingTheLimitStartsAtTwoHours() async throws {
    let fixture = try Fixture()
    #expect(await fixture.model.setLongRunningLimitEnabled(true) == .applied)
    let saved = try #require(fixture.fileSettings)
    #expect(saved.longRunningLimitEnabled)
    #expect(saved.longRunningLimitMinutes == 120)
    #expect(saved.longRunningLimitSeconds == 7200)
    #expect(fixture.model.text(for: .longRunningLimitMinutes) == "120")
  }

  @Test func theTimeLimitRowCommitsFifteenToSevenHundredTwenty() async throws {
    let fixture = try Fixture()
    let model = fixture.model
    for value in [15, 720, 45] {
      #expect(await model.commit(.longRunningLimitMinutes, text: "\(value)") == .applied)
      #expect(model.settings.longRunningLimitMinutes == value)
      #expect(fixture.fileSettings?.longRunningLimitMinutes == value)
      #expect(fixture.host.appliedSettings.last?.longRunningLimitMinutes == value)
    }
    for text in ["14", "721", "abc"] {
      let rejected = await model.commit(.longRunningLimitMinutes, text: text)
      #expect(rejected == .invalid(SettingsValidationError(message: Self.limitMessage)), "\(text)")
      #expect(model.message(for: .longRunningLimitMinutes) == Self.limitMessage)
      #expect(model.settings.longRunningLimitMinutes == 45)
      #expect(fixture.fileSettings?.longRunningLimitMinutes == 45)
    }
    model.revert(.longRunningLimitMinutes)
    #expect(model.text(for: .longRunningLimitMinutes) == "45")
    #expect(SettingsModel.stepSize(for: .longRunningLimitMinutes) == 15)
    #expect(SettingsModel.stepBounds(for: .longRunningLimitMinutes, in: Settings()) == 15...720)
  }

  @Test func thePaneReadsItsCopyFromLongRunningCopy() {
    #expect(DetectionPane.entrypointsCaption == LongRunningCopy.entrypointsCaption)
    #expect(LongRunningCopy.sectionTitle == "Long-running work")
    #expect(LongRunningCopy.limitFieldLabel == "Time limit")
  }
}
