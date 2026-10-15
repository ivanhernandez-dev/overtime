import Foundation

final class BundleAnchor {}

enum ExecutableLocator {
  static func url(named name: String) -> URL {
    Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent(name)
  }
}
