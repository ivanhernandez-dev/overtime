import Foundation

public enum Timing {
  public static let tickSeconds: Double = 2
  public static let lidStableSeconds: Double = 4
  public static let displayRecheckSeconds: Double = 30
  public static let resleepEverySeconds: Double = 10
  public static let hidIdleResleepSeconds: Double = 60
  public static let netEverySeconds: Double = 10
  public static let netFailsNeeded = 3
  public static let netWaitMinSeconds: Double = 90
  public static let netWaitMaxSeconds: Double = 300
  public static let batteryPollSeconds: Double = 30
  public static let reassertEverySeconds: Double = 10
  public static let freshCaffeinateSeconds: Double = 2
  public static let assertionTimeoutSeconds: Double = 300
  public static let backoffBaseSeconds: Double = 20
  public static let backoffCapSeconds: Double = 300
  public static let releaseVerificationSeconds: Double = 30
  public static let healthSilenceSeconds: Double = 600
  public static let healthCheckSeconds: Double = 30
  public static let learnedRootLingerSeconds: Double = 600
  public static let sessionWorkingGraceSeconds: Double = 90
  public static let coexistenceCheckSeconds: Double = 30
  public static let hotspotJoinWaitSeconds: Double = 16
  public static let hotspotJoinLandSeconds: Double = 30
  public static let sentinelTimeoutSeconds: Double = 45
  public static let sentinelRespawnRetryBaseSeconds: Double = tickSeconds
  public static let sentinelRespawnRetryCapSeconds: Double = 60
  public static let systemCallTimeoutSeconds: Double = 5
  public static let releaseRetrySeconds: Double = systemCallTimeoutSeconds * 2
  public static let releaseFailuresBeforeEscalation = 2
  public static let lateWriteQuarantineSeconds: Double = 300
  public static let lateWriteClearSeconds: Double = 30
  public static let logRotateBytes = 524_288
}
