import Foundation
import Security

enum OwnRequirement {
  static func string() -> String {
    var running: SecCode?
    guard SecCodeCopySelf([], &running) == errSecSuccess, let running else { return "" }
    var onDisk: SecStaticCode?
    guard SecCodeCopyStaticCode(running, [], &onDisk) == errSecSuccess, let onDisk else { return "" }
    var requirement: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(onDisk, [], &requirement) == errSecSuccess, let requirement else {
      return ""
    }
    var text: CFString?
    guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return "" }
    return text as String
  }
}
