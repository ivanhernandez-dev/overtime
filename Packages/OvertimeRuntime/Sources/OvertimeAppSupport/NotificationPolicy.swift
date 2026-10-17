import Foundation
import OvertimeCore
import OvertimeEngine

public struct NotificationPolicyState: Sendable, Equatable {
  public var counters: EventCounters
  public var lastPosted: [NotificationCategory: Instant]
  public var batteryFloorCycleUsed: Bool
  public var belowFloorCycleUsed: Bool
  public var journal: LidClosedJournal?
  public var lastEvents: EventCounters?
  public var sentinelClearPending: Bool
  public var reminderAnchor: Instant?
  public var reminderPostedAnchor: Instant?
  public var selfTestFailures: UInt64
  public var selfTestStreakNotified: Bool
  public var temperatureCycleUsed: Bool

  public init(
    counters: EventCounters = EventCounters(), lastPosted: [NotificationCategory: Instant] = [:],
    batteryFloorCycleUsed: Bool = false, belowFloorCycleUsed: Bool = false, sentinelClearPending: Bool = false,
    temperatureCycleUsed: Bool = false
  ) {
    self.temperatureCycleUsed = temperatureCycleUsed
    self.counters = counters
    self.lastPosted = lastPosted
    self.batteryFloorCycleUsed = batteryFloorCycleUsed
    self.belowFloorCycleUsed = belowFloorCycleUsed
    self.journal = nil
    self.lastEvents = nil
    self.sentinelClearPending = sentinelClearPending
    self.reminderAnchor = nil
    self.reminderPostedAnchor = nil
    self.selfTestFailures = 0
    self.selfTestStreakNotified = false
  }
}

extension NotificationPolicyState {
  public func carriedToNewEngine() -> NotificationPolicyState {
    var next = NotificationPolicyState(
      lastPosted: lastPosted, batteryFloorCycleUsed: batteryFloorCycleUsed, belowFloorCycleUsed: belowFloorCycleUsed,
      sentinelClearPending: sentinelClearPending, temperatureCycleUsed: temperatureCycleUsed)
    next.selfTestStreakNotified = selfTestStreakNotified
    return next
  }
}

public enum NotificationPolicy {
  public static let capSeconds: Double = 600

  public static func step(
    _ state: inout NotificationPolicyState, snapshot: EngineSnapshot, preferences: AppPreferences,
    authorization: NotificationAuthorization, now: Instant
  ) -> [NotificationIntent] {
    candidates(&state, snapshot: snapshot, now: now, reminderHours: preferences.forceReminderHours).filter { intent in
      admit(intent, state: &state, preferences: preferences, authorization: authorization, now: now)
    }
  }

  public static let secondsPerHour: Double = 3_600

  static func candidates(
    _ state: inout NotificationPolicyState, snapshot: EngineSnapshot, now: Instant, reminderHours: Int
  ) -> [NotificationIntent] {
    var intents: [NotificationIntent] = []
    let holdFailed = rose(\.holdErrorsWhileBusy, state: &state, snapshot: snapshot)
    let released = rose(\.batteryReleases, state: &state, snapshot: snapshot)
    let startedBelow = rose(\.busyStartsBelowFloor, state: &state, snapshot: snapshot)
    let hot = rose(\.temperatureReleases, state: &state, snapshot: snapshot)
    let resets = endsDischargeCycle(snapshot)
    if holdFailed {
      intents.append(NotificationContent.keepAwakeFailed())
    }
    if let selfTest = selfTestFailed(&state, snapshot: snapshot) {
      intents.append(selfTest)
    }
    if released, !resets, snapshot.lidClosed != true, !state.batteryFloorCycleUsed {
      state.batteryFloorCycleUsed = true
      intents.append(NotificationContent.batteryFloor(floorPercent: snapshot.batteryLowPercent))
    }
    if startedBelow, !resets, !state.belowFloorCycleUsed {
      state.belowFloorCycleUsed = true
      intents.append(
        NotificationContent.belowFloorAtStart(
          percent: batteryPercent(snapshot.power), floorPercent: snapshot.batteryLowPercent))
    }
    if resets {
      state.batteryFloorCycleUsed = false
      state.belowFloorCycleUsed = false
    }
    if hot, snapshot.lidClosed != true, !state.temperatureCycleUsed {
      state.temperatureCycleUsed = true
      intents.append(NotificationContent.batteryTemperature(releaseCelsius: snapshot.temperatureReleaseCelsius))
    }
    if !snapshot.temperatureBlocked {
      state.temperatureCycleUsed = false
    }
    if let summary = lidClosedSummary(&state, snapshot: snapshot) {
      intents.append(summary)
    }
    if let reminder = forceReminder(&state, snapshot: snapshot, now: now, hours: reminderHours) {
      intents.append(reminder)
    }
    return intents
  }

  static func selfTestFailed(_ state: inout NotificationPolicyState, snapshot: EngineSnapshot) -> NotificationIntent? {
    if snapshot.selfTest == .passed {
      state.selfTestStreakNotified = false
    }
    guard snapshot.selfTestFailures > state.selfTestFailures else { return nil }
    state.selfTestFailures = snapshot.selfTestFailures
    guard !state.selfTestStreakNotified, snapshot.selfTestErrorActive else { return nil }
    state.selfTestStreakNotified = true
    return NotificationContent.selfTestFailed()
  }

  static func forceReminder(_ state: inout NotificationPolicyState, snapshot: EngineSnapshot, now: Instant, hours: Int)
    -> NotificationIntent?
  {
    state.reminderAnchor = quietStretchStart(snapshot)
    guard let deadline = nextDeadline(state, hours: hours), now >= deadline else { return nil }
    state.reminderPostedAnchor = state.reminderAnchor
    return NotificationContent.forceReminder(hours: reminderHours(hours))
  }

  static func quietStretchStart(_ snapshot: EngineSnapshot) -> Instant? {
    guard snapshot.force != nil, snapshot.busy != true, let forceSince = snapshot.events.forceSince else { return nil }
    guard let busyEndedAt = snapshot.busyEndedAt else { return forceSince }
    return max(forceSince, busyEndedAt)
  }

  static func reminderHours(_ hours: Int) -> Int {
    let range = AppPreferences.forceReminderHoursRange
    return min(max(hours, range.lowerBound), range.upperBound)
  }

  public static func nextDeadline(_ state: NotificationPolicyState, hours: Int) -> Instant? {
    guard let anchor = state.reminderAnchor, state.reminderPostedAnchor != anchor else { return nil }
    return anchor.adding(seconds: Double(reminderHours(hours)) * secondsPerHour)
  }

  static func lidClosedSummary(_ state: inout NotificationPolicyState, snapshot: EngineSnapshot)
    -> NotificationIntent?
  {
    let baseline = state.lastEvents ?? snapshot.events
    state.lastEvents = snapshot.events
    if state.sentinelClearPending, let closed = snapshot.lidClosed {
      state.sentinelClearPending = false
      if closed {
        var journal = LidClosedJournal.start(baseline: baseline)
        journal.record(.sentinelClear)
        state.journal = journal
      }
    }
    switch snapshot.lidClosed {
    case true?:
      var journal = state.journal ?? LidClosedJournal.start(baseline: baseline)
      journal.append(from: snapshot)
      state.journal = journal
      return nil
    case false?:
      guard var journal = state.journal else { return nil }
      state.journal = nil
      journal.append(from: snapshot)
      return journal.summary()
    case nil:
      state.journal?.append(from: snapshot)
      return nil
    }
  }

  static func endsDischargeCycle(_ snapshot: EngineSnapshot) -> Bool {
    switch snapshot.power {
    case .ac, .noBattery:
      true
    case .battery(let percent?):
      percent >= snapshot.batteryResumePercent
    case .battery(nil), nil:
      false
    }
  }

  static func batteryPercent(_ power: PowerReading?) -> Int? {
    if case .battery(let percent) = power { return percent }
    return nil
  }

  static func rose(
    _ counter: WritableKeyPath<EventCounters, UInt64>, state: inout NotificationPolicyState, snapshot: EngineSnapshot
  ) -> Bool {
    let current = snapshot.events[keyPath: counter]
    guard current > state.counters[keyPath: counter] else { return false }
    state.counters[keyPath: counter] = current
    return true
  }

  static func admit(
    _ intent: NotificationIntent, state: inout NotificationPolicyState, preferences: AppPreferences,
    authorization: NotificationAuthorization, now: Instant
  ) -> Bool {
    guard preferences.isEnabled(intent.category.preferenceKey), authorization.allowsPosting else { return false }
    if let last = state.lastPosted[intent.category], now.seconds(since: last) < capSeconds {
      return false
    }
    state.lastPosted[intent.category] = now
    return true
  }
}
