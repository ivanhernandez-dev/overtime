import Foundation
import OvertimeAppSupport
import OvertimeHelperCore
import OvertimeSystem
import Testing

struct PurgeTableTests {
  static func directoryPath(_ url: URL) -> String {
    var path = url.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  @Test func theReleaseUserItemsAreTheSevenListedPathsInOrder() {
    let id = "io.github.ivanhernandez-dev.overtime"
    #expect(PurgeTable.release.appIdentifier == id)
    #expect(PurgeTable.release.folderName == "Overtime")
    #expect(
      PurgeTable.release.userItems.map(\.relativePath) == [
        "Library/Application Support/Overtime",
        "Library/Logs/Overtime",
        "Library/Preferences/\(id).plist",
        "Library/Caches/\(id)",
        "Library/HTTPStorages/\(id)",
        "Library/HTTPStorages/\(id).binarycookies",
        "Library/Saved Application State/\(id).savedState",
      ])
    #expect(PurgeTable.release.userItems.allSatisfy { $0.scope == .user })
  }

  @Test func theDevUserItemsUseTheDevIdentifierAndFolder() {
    let id = "io.github.ivanhernandez-dev.overtime.dev"
    #expect(PurgeTable.dev.appIdentifier == id)
    #expect(PurgeTable.dev.folderName == "Overtime Dev")
    #expect(
      PurgeTable.dev.userItems.map(\.relativePath) == [
        "Library/Application Support/Overtime Dev",
        "Library/Logs/Overtime Dev",
        "Library/Preferences/\(id).plist",
        "Library/Caches/\(id)",
        "Library/HTTPStorages/\(id)",
        "Library/HTTPStorages/\(id).binarycookies",
        "Library/Saved Application State/\(id).savedState",
      ])
  }

  @Test func theRootItemsAreTheHelperFolders() {
    for (table, identity) in [(PurgeTable.release, HelperIdentity.release), (PurgeTable.dev, HelperIdentity.dev)] {
      #expect(table.appIdentifier == identity.appIdentifier)
      #expect(table.rootItems.allSatisfy { $0.scope == .root })
      #expect(
        table.rootItems.map { $0.absolutePath(homeDirectory: "/Users/someone") } == [
          identity.supportDirectory, identity.logDirectory,
        ])
    }
  }

  @Test func theFirstTwoUserItemsAreTheAppsOwnSupportAndLogFolders() {
    let home = "/Users/someone"
    for (table, name) in [(PurgeTable.release, Paths.releaseAppName), (PurgeTable.dev, "Overtime Dev")] {
      let paths = Paths.resolve(environment: [:], homeDirectory: home, appName: name)
      #expect(table.userItems[0].absolutePath(homeDirectory: home) == Self.directoryPath(paths.supportDirectory))
      #expect(table.userItems[1].absolutePath(homeDirectory: home) == Self.directoryPath(paths.logsDirectory))
    }
    #expect(
      PurgeTable.release.userItems[0].absolutePath(homeDirectory: home + "/")
        == "/Users/someone/Library/Application Support/Overtime")
  }

  @Test func caskPathsStartWithTildeForUserItemsAndSlashForRootItems() {
    for table in [PurgeTable.release, .dev] {
      #expect(table.userItems.allSatisfy { $0.caskPath == "~/" + $0.relativePath })
      #expect(table.rootItems.allSatisfy { $0.caskPath == "/" + $0.relativePath })
      #expect(table.sparkleCache.caskPath.hasPrefix("~/"))
    }
    let rootCaskPaths = ["/Library/Application Support/Overtime", "/Library/Logs/Overtime"]
    #expect(PurgeTable.release.rootItems.map(\.caskPath) == rootCaskPaths)
  }

  @Test func noItemTouchesAnotherToolsFilesOrLaunchAgents() {
    for table in [PurgeTable.release, .dev] {
      let all = table.userItems + table.rootItems + [table.sparkleCache]
      for item in all {
        for banned in [".config", ".local/bin", "LaunchAgents", "LaunchDaemons", "TCC"] {
          #expect(!item.relativePath.contains(banned), "\(item.relativePath)")
        }
        #expect(!item.relativePath.hasPrefix("/"))
        #expect(!item.relativePath.contains(".."))
      }
    }
  }

  @Test func theSparkleLabelsAndCacheFollowTheIdentifier() {
    for table in [PurgeTable.release, .dev] {
      let id = table.appIdentifier
      #expect(table.sparkleJobLabels == [id + "-sparkle-updater", id + "-sparkle-progress"])
      let cache = PurgeItem(scope: .user, relativePath: "Library/Caches/\(id)/org.sparkle-project.Sparkle")
      #expect(table.sparkleCache == cache)
      let absolute = table.sparkleCache.absolutePath(homeDirectory: "/Users/someone")
      #expect(absolute?.hasPrefix("/Users/someone/Library/Caches/\(id)/") == true)
    }
  }

  @Test(arguments: ["", "/", "//", "///", "/.", "/./", "/..", "/Users/../..", "rel", "rel/home", "~", "./home"])
  func aHomeThatIsEmptyRelativeOrResolvesToTheRootGivesNoUserPath(_ home: String) {
    for table in [PurgeTable.release, .dev] {
      for item in table.userItems + [table.sparkleCache] {
        #expect(item.absolutePath(homeDirectory: home) == nil, "\(home) \(item.relativePath)")
      }
      #expect(table.rootItems.map { $0.absolutePath(homeDirectory: home) } == table.rootItems.map(\.caskPath))
    }
    #expect(PurgeItem.usableHome(home) == nil)
  }

  @Test(arguments: [
    ("/Users/someone", "/Users/someone"), ("/Users/someone/", "/Users/someone"), ("/Users//someone", "/Users/someone"),
    ("/Users/someone/.", "/Users/someone"),
  ])
  func aUsableHomeIsNormalisedBeforeTheItemIsAppended(_ home: String, _ expected: String) {
    #expect(PurgeItem.usableHome(home) == expected)
    #expect(
      PurgeTable.release.userItems[1].absolutePath(homeDirectory: home) == expected + "/Library/Logs/Overtime")
  }
}
