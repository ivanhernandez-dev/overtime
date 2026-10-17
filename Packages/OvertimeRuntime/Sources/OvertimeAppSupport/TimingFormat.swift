import Foundation
import OvertimeCore
import OvertimeEngine

public enum TimingFormat {
  public static func countdown(_ seconds: Double) -> String {
    clock(wholeSeconds(seconds, roundingUp: true))
  }

  public static func duration(_ seconds: Double) -> String {
    clock(wholeSeconds(seconds, roundingUp: false))
  }

  public static func spokenCountdown(_ seconds: Double) -> String {
    let minutes = wholeMinutes(seconds)
    return minutes < 1 ? "less than a minute left" : "about \(spokenHoursAndMinutes(minutes)) left"
  }

  public static func spokenDuration(_ seconds: Double) -> String {
    let minutes = wholeMinutes(seconds)
    return minutes < 1 ? "held for less than a minute" : "held for \(spokenHoursAndMinutes(minutes))"
  }

  public static func spokenAbout(_ seconds: Double) -> String {
    let minutes = wholeMinutes(seconds)
    return minutes < 1 ? "less than a minute" : "about \(spokenHoursAndMinutes(minutes))"
  }

  public static func elapsed(_ seconds: Double) -> String {
    let minutes = wholeMinutes(seconds)
    if minutes < 1 { return "<1m" }
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(minutes % 60)m"
  }

  public static func spokenElapsed(_ seconds: Double) -> String {
    let minutes = wholeMinutes(seconds)
    if minutes < 1 { return "less than a minute" }
    return spokenHoursAndMinutes(minutes)
  }

  static func wholeSeconds(_ seconds: Double, roundingUp: Bool) -> Int {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    let rounded = roundingUp ? seconds.rounded(.up) : seconds.rounded(.down)
    return Int(min(rounded, Double(Int.max / 2)))
  }

  static func clock(_ total: Int) -> String {
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    guard hours > 0 else { return "\(minutes):\(twoDigits(seconds))" }
    return "\(hours):\(twoDigits(minutes)):\(twoDigits(seconds))"
  }

  static func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }

  static func wholeMinutes(_ seconds: Double) -> Int {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return Int(min(seconds, Double(Int.max / 2)) / 60)
  }

  static func spokenHoursAndMinutes(_ minutes: Int) -> String {
    let hours = minutes / 60
    let rest = minutes % 60
    var parts: [String] = []
    if hours > 0 { parts.append(unit(hours, "hour")) }
    if rest > 0 || hours == 0 { parts.append(unit(rest, "minute")) }
    return parts.joined(separator: " ")
  }

  static func unit(_ value: Int, _ name: String) -> String {
    value == 1 ? "1 \(name)" : "\(value) \(name)s"
  }
}

public struct TimingParts: Sendable, Equatable {
  public var lead: TimingLine?
  public var held: TimingLine?

  public init(lead: TimingLine?, held: TimingLine?) {
    self.lead = lead
    self.held = held
  }
}

public struct TimingLine: Sendable, Equatable {
  public var text: String
  public var spoken: String

  public init(text: String, spoken: String) {
    self.text = text
    self.spoken = spoken
  }

  public static func parts(
    for presentation: StatusPresentation, snapshot: EngineSnapshot?, nowMono: Instant, nowWall: Date,
    calendar: Calendar = .current
  ) -> TimingParts? {
    guard let kind = StatusPresentation.timingKind(state: presentation.state, snapshot: snapshot) else { return nil }
    func remaining(_ deadline: Instant) -> Double { deadline.seconds(since: nowMono) }
    func held(_ since: Instant?) -> TimingLine? {
      since.map { start in
        let seconds = nowMono.seconds(since: start)
        return TimingLine(text: TimingFormat.duration(seconds), spoken: TimingFormat.spokenDuration(seconds))
      }
    }
    switch kind {
    case .held(let since):
      return TimingParts(lead: nil, held: held(since))
    case .grace(let deadline, let since):
      let lead = deadline.map { deadline in
        let left = remaining(deadline)
        return TimingLine(
          text: "Releasing in \(TimingFormat.countdown(left))",
          spoken: "releasing in \(TimingFormat.spokenAbout(left))")
      }
      return TimingParts(lead: lead, held: held(since))
    case .pauseUntilMono(let deadline):
      let left = remaining(deadline)
      let lead = TimingLine(
        text: "Resumes in \(TimingFormat.countdown(left))", spoken: "resumes in \(TimingFormat.spokenAbout(left))")
      return TimingParts(lead: lead, held: nil)
    case .pauseUntilWall(let date):
      let left = max(0, date.timeIntervalSince(nowWall))
      guard isMidnight(date, calendar: calendar) else {
        let lead = TimingLine(
          text: "Resumes in \(TimingFormat.countdown(left))", spoken: "resumes in \(TimingFormat.spokenAbout(left))")
        return TimingParts(lead: lead, held: nil)
      }
      let lead = TimingLine(
        text: "Resumes at midnight (\(TimingFormat.countdown(left)))",
        spoken: "resumes at midnight, \(TimingFormat.spokenCountdown(left))")
      return TimingParts(lead: lead, held: nil)
    case .pauseIndefinite:
      let lead = TimingLine(text: "Paused until you resume", spoken: "paused until you resume")
      return TimingParts(lead: lead, held: nil)
    case .releaseUntilIdle:
      let lead = TimingLine(text: "Resumes when Claude goes idle", spoken: "resumes when Claude goes idle")
      return TimingParts(lead: lead, held: nil)
    case .forceUntilMono(let deadline, let since):
      let left = remaining(deadline)
      let lead = TimingLine(
        text: "Stops in \(TimingFormat.countdown(left))", spoken: "stops in \(TimingFormat.spokenAbout(left))")
      return TimingParts(lead: lead, held: held(since))
    case .forceIndefinite(let since):
      return TimingParts(lead: TimingLine(text: "Until you stop it", spoken: "until you stop it"), held: held(since))
    case .batteryFloor(let percent):
      let lead = TimingLine(
        text: "Resumes on power or at \(percent)%", spoken: "resumes on power or at \(percent) percent")
      return TimingParts(lead: lead, held: nil)
    case .batteryHot(let celsius):
      let lead = TimingLine(
        text: "Resumes below \(celsius)°C", spoken: "resumes below \(celsius) degrees Celsius")
      return TimingParts(lead: lead, held: nil)
    }
  }

  public static func line(
    for presentation: StatusPresentation, snapshot: EngineSnapshot?, nowMono: Instant, nowWall: Date,
    calendar: Calendar = .current
  ) -> TimingLine? {
    guard
      let parts = parts(
        for: presentation, snapshot: snapshot, nowMono: nowMono, nowWall: nowWall, calendar: calendar)
    else { return nil }
    switch (parts.lead, parts.held) {
    case (let lead?, let held?):
      return TimingLine(text: "\(lead.text) · held for \(held.text)", spoken: "\(lead.spoken), \(held.spoken)")
    case (let lead?, nil):
      return lead
    case (nil, let held?):
      return TimingLine(text: "Held for \(held.text)", spoken: held.spoken)
    case (nil, nil):
      return nil
    }
  }

  static func isMidnight(_ date: Date, calendar: Calendar) -> Bool {
    let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
    return parts.hour == 0 && parts.minute == 0 && parts.second == 0 && (parts.nanosecond ?? 0) < 1_000_000
  }
}
