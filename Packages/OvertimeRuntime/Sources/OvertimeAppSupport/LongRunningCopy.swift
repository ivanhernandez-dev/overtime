import Foundation

public enum LongRunningCopy {
  public static let sectionTitle = "Long-running work"
  public static let backgroundCommandsLabel = "Keep awake while Claude waits on a background command"
  public static let backgroundCommandsCaption =
    "A command Claude Code started in the background, such as a build, a test run or a script, keeps the Mac awake until it ends, even after Claude's turn is over. A dev server Claude started also keeps the Mac awake for as long as it runs and its session is open: stop the server, turn this off, or set a time limit."
  public static let printRunsLabel = "Keep awake while claude -p runs"
  public static let printRunsCaption =
    "A non-interactive Claude Code run (claude -p) keeps the Mac awake until it exits, whether a terminal, a script or a scheduled job started it. Agent SDK scripts are not counted."
  public static let limitLabel = "Stop after a time limit"
  public static let limitFieldLabel = "Time limit"
  public static let limitCaption =
    "Off by default, so there is no limit. When it is on, a background command stops counting this long after Claude's last activity, and a claude -p run this long after it started. Battery and temperature protection, Pause and Sleep Now always apply."
  public static let entrypointsCaption =
    "Transcripts whose entrypoint matches are not counted as Claude working. The default, sdk-*, ignores the transcripts of claude -p and Agent SDK automations. A claude -p run still keeps the Mac awake while it runs; see Long-running work."
}
