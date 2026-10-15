import Foundation

public enum UIDateText {
  public static func englishLocale(keeping locale: Locale) -> Locale {
    var components = Locale.Components(locale: locale)
    components.languageComponents = Locale.Language.Components(
      languageCode: .english, script: nil, region: locale.region)
    return Locale(components: components)
  }

  public static func string(
    _ date: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    let english = englishLocale(keeping: locale)
    let style = Date.FormatStyle(
      date: .abbreviated, time: .shortened, locale: english, calendar: english.calendar, timeZone: timeZone)
    return date.formatted(style)
  }
}
