# Behavior scenarios (acceptance criteria)

The 34 scenarios below are Overtime's own acceptance criteria. Each one is an automated test against simulated system state in `Packages/OvertimeCore/Tests/OvertimeCoreTests/Scenarios/` (requirement OPS-08). The Req column names the requirement each scenario checks.

## Busy detection (8)

| # | Given | Expected | Req |
|---|---|---|---|
| 1 | Only a recently modified transcript whose entrypoint is `sdk-cli` (a `claude -p` automation) | Not busy | DET-03 |
| 2 | A recent interactive transcript (`"entrypoint":"cli"`) whose message text contains the JSON-escaped string `\"entrypoint\":\"sdk-cli\"` | Busy | DET-03 |
| 3 | The only interactive transcript was last modified 10 min ago | Not busy | DET-02 |
| 4 | A recently modified subagent transcript (`<session>/subagents/agent-*.jsonl`) | Busy | DET-02, DET-08 |
| 5 | A recent transcript with no entrypoint field (e.g. a summary line) | Busy (conservative) | DET-03 |
| 6 | Claude's caffeinate is present and the newest transcript is 10 min old (long silent command) | Busy | DET-01, DET-05 |
| 7 | Claude's caffeinate is present but no transcript has been written for 40 min | Not busy (stuck); logged once | DET-05 |
| 8 | No caffeinate and no recent transcript | Not busy | DET-01, DET-02 |

## Battery hysteresis (7)

Run as one sequence, starting unblocked. `LOW = 10`, `RESUME = 20`.

| # | Power state | Expected block | Req |
|---|---|---|---|
| 9 | Battery 50% | Not blocked | BAT-01 |
| 10 | Battery 10% | Blocked | BAT-01 |
| 11 | Battery 19% | Still blocked (hysteresis) | BAT-01 |
| 12 | Battery 20% | Unblocked | BAT-01 |
| 13 | Battery 8% | Blocked | BAT-01 |
| 14 | AC power at 8% | Unblocked | BAT-01 |
| 15 | No battery present (desktop Mac), previously blocked | Unblocked | BAT-01 |

## Persisted state (2)

| # | Given | Expected | Req |
|---|---|---|---|
| 16 | A state file with one valid value, one invalid value, and an unknown key whose value is a shell command substitution | Valid value loaded, invalid one reset to its default, unknown key ignored, **nothing executed** | HOLD-04 |
| 17 | State saved, then loaded again | Round trip preserves every field | HOLD-04 |

## Keep-awake ownership (7)

Overtime drives the IOKit clamshell hold.

| # | Given | Expected | Req |
|---|---|---|---|
| 18 | Claude becomes busy and no hold is active | Hold acquired (lid-close sleep disabled) and owned by the app | HOLD-01 |
| 19 | While busy and owning, the hold is removed externally while its provider is still running (the user's "Release Until Idle") | Override set; hold not re-acquired until Claude goes idle | HOLD-06 |
| 20 | While busy and owning, the hold disappears because its provider died (powerd cleared the bit) | Hold re-acquired, no override | HOLD-09 (re-assert), HOLD-01 |
| 21 | Claude is busy and another tool's keep-awake session is active without lid-close protection | Lid-close protection added by acquiring Overtime's own hold, never clearing the other tool's | HOLD-07 |
| 22 | Claude goes idle after scenario 21 | Only our change is undone; the other session keeps running | HOLD-07 |
| 23 | Claude goes idle while the app owns the hold | Hold released | HOLD-09 |
| 24 | Acquiring the hold fails | Not owned; failure count 1; next attempt scheduled after a backoff delay | HOLD-08 |

## Lid and display (4)

| # | Given | Expected | Req |
|---|---|---|---|
| 25 | Keep-awake wanted, the lid goes from open to closed, no external display | Display turned off | LID-01 |
| 26 | Same, but an external display is connected | Display untouched | LID-03 |
| 27 | Lid has stayed closed, display re-sleep check due, last keyboard/mouse input 5 s ago | Display not turned off again | LID-02 |
| 28 | Same, last input 120 s ago | Display turned off again | LID-02 |

## Network failover (6)

Lid closed and stable, keep-awake wanted, hotspot configured, a connectivity check every 10 s.

| # | Given | Expected | Req |
|---|---|---|---|
| 29 | 2 consecutive failed connectivity checks | No network change | NET-03 |
| 30 | 3 consecutive failed checks and the hotspot join succeeds | Joined the hotspot; "switched by app" flag set and persisted | NET-03, NET-06 |
| 31 | 3 consecutive failed checks and the hotspot join fails | Wi-Fi power-cycled; flag not set | NET-03 |
| 32 | Connectivity checks keep succeeding | Network never touched | NET-02 |
| 33 | Hotspot setting is empty | Failover disabled; network never touched | NET-08 |
| 34 | The app had switched to the hotspot, the lid opens and stays open, the Mac is still on the hotspot | Wi-Fi power-cycled to return to the best network; flag cleared | NET-06 |
