# 0021. Own the status item and its panel instead of the SwiftUI menu bar scene

- **Status:** Accepted
- **Accepted:** 2026-10-13. The project author reported the defect and decided that a right click does the same as a left click. The design below was delegated to Claude; the author may revisit it.
- **Date:** 2026-10-13
- **Deciders:** Project author
- **Related requirements:** **APP-01**, **APP-15**, **APP-13**
- **Related ADRs:** [0019](0019-detection-loop-energy-design.md)

## Context

Until build 0.1.0 (100) the menu bar interface was the SwiftUI menu bar scene (`MenuBarExtra`) with the window style. SwiftUI owned the status item and the window that holds the panel; the app only supplied the label and the panel view.

The author reported that the panel sometimes does not open, and that it must open with the left and with the right mouse button. Measured on that build with real clicks, on macOS 27.0.1 with two displays:

- 8 of 8 cold left clicks on the status item, made while another app was in front, never brought the panel on screen. The panel's window existed the whole time, at the right frame just under the item, but stayed hidden. The item looked highlighted, as if the panel were open.
- A right click on the item did nothing.
- After a click on another app's status item, a left click on the Overtime item showed the panel within 0.1 s. It then toggled on every click until the pointer left the menu bar and the panel was dismissed.
- The main thread was idle for the whole of a 6 s sample, so no blocked run loop explains it.
- The app has no activation-policy code. It is an agent app (`LSUIElement`) and nothing more.

The reading of these facts: the scene shows its window only when the app manages to activate on the click. A cold click on the status item does not give the app activation on this system, so the window stays hidden, while a click made while another status item's menu is tracking does. The scene also has no handling for the right mouse button. This reading is an inference from the measurements; no system source was read to confirm it.

## Decision

**The app owns its status item and its panel.**

- **Status item.** `AppDelegate` builds one `NSStatusItem` with a variable length. Its button sends its action on the left and on the right mouse-down, and both go to the same toggle, so a right click does exactly what a left click does. The button shows a template symbol with no title text, and its symbol and accessibility label follow the panel model through Observation tracking, with no polling.
- **Panel.** A borderless, non-activating `NSPanel` at the pop-up menu level hosts the same panel view as before. It does not hide when the app is inactive, it is ordered front regardless of activation and made key, and the app is never asked to activate in order to show it. It can become key, because the footer shortcuts need a key window, and it never becomes main.
- **Decision core.** Whether a click shows the panel, closes it or is ignored is decided by a pure reducer in `OvertimeAppSupport`, and the panel's origin by a pure function next to it. The AppKit code only performs the effects the reducer returns. Two guards keep one physical click from flipping the panel twice when it is delivered twice: an outside click stamped at or before the click that opened the panel is ignored, and an item click within 0.3 s of a close that was not itself an item click is ignored.
- **Placement.** The panel hangs under the item with its leading edge aligned, 4 pt below the menu bar, and is kept 8 pt inside the visible frame of the display that holds the item. The bottom is never clamped. When the reported item frame is missing, empty, or more than 8 pt away from the click, the pointer is used instead.
- **Close triggers.** A click on the item, a click outside, Esc, the panel resigning key, the app resigning active, a Space change, and another Overtime window becoming key.
  - Esc is the panel's `cancelOperation`, not a key event monitor. The Sleep Now confirmation inside the panel binds the cancel action, and it must keep Esc as "Keep Working"; the cancel operation is meant to reach the panel only after the views have declined the key.
  - A local click counts as outside only when its window is below the panel's level. The panel holds two pop-up menus, and their menus open in windows at the pop-up menu level.
  - The panel resigning key is a trigger because a non-activating panel never makes the app active, so the app resigning active does not fire when the user switches apps from the keyboard.
- **Modes.** The item is built in the live mode and in the blocked mode, and never in the test host. The blocked mode exists to show a failure and the emergency control, so it needs the interface as much as the live mode does.
- **Lifecycle.** The SwiftUI app lifecycle stays, with one inert scene shared by the app and the test host, and with the application-settings command removed. The lifecycle supplies the standard main menu, whose key equivalents (Cmd-Q, Cmd-W, copy and paste) the Settings and onboarding windows use; the removed command would have opened an empty window on Cmd-comma. The app also answers explicitly that closing the last window does not quit it.
- **Input monitoring.** No key event is monitored anywhere in the app. One global and one local mouse-down monitor exist only while the panel is shown; they use the event's time stamp and, for local clicks, its window, and nothing is logged.

## Consequences

- A source gate in the package tests fails when the SwiftUI menu bar scene or its style modifier returns, when the action mask loses the right mouse button, when the panel loses the non-activating style, hides while the app is inactive or is no longer ordered front regardless of activation, when the menu bar code asks the application to activate, when a key event type is named in the app sources, when a second status item is built, when the cancel operation override goes away, or when the number of mouse monitors changes.
- The item may sit at a new position in the menu bar once after the update, because the item now has its own saved-position name.
- The panel draws the popover material and its rounded corners itself, where the scene's window used to supply them.
- The panel's height follows its content through layout constraints, and the panel is placed again when it resizes. The 1 s timing line still runs only while the panel is on screen, through the same occlusion probe as before ([0019](0019-detection-loop-energy-design.md)).
- The hosted tests build no status item and no panel. They cover the mode policy, the label, its observer and the panel's constants; the reducer and the placement are covered by package tests.

**Not verified:** the behaviour on a real menu bar had not been observed when this was written. It is a human check on the signed build: a cold left click, a right click, every close trigger, the shortcuts with the panel open, the pop-up menus inside the panel, the placement on each of two displays, the look, and VoiceOver on the item. Three assumptions carry the design and are part of that check: that a non-activating panel becomes key while the app is inactive, that opening a pop-up menu inside the panel does not make the panel resign key, and that the button's action arrives for a cold click at all. Nothing was verified on macOS 14, 15 or 26. The 23 MB shell footprint in [0019](0019-detection-loop-energy-design.md) was measured with the old scene and was not measured again.

## Alternatives considered

None of these was built or measured.

- **Keep the scene and ask the app to activate on the click.** The panel would still depend on activation being granted, which is the thing that failed, and the scene has no handling for the right mouse button.
- **The scene's menu style.** A menu holds menu items, not the panel's status block and controls.
- **A plain AppKit entry point.** It would lose the standard main menu that the auxiliary windows use, unless a main menu were built by hand.
- **A popover.** Not tried. The panel needs no arrow and no popover behaviour.

## Evidence

Measured on 2026-10-13 on the installed build 0.1.0 (100), macOS 27.0.1, two displays, with real clicks by the author:

- 8 of 8 cold left clicks showed nothing, while the panel's window existed at the right frame.
- A right click did nothing.
- The same left click worked after another app's status item had been clicked first.
- The main thread was idle during a 6 s sample.

Synthetic clicks do not open status items on this system, not even other apps' items, so the fix cannot be verified by automation.

Checked while implementing, on the same machine, with a panel that was built by a small script and never shown:

- The panel's style, level and Space behaviour build without an error.
- Key-value observation of the hosting controller's preferred content size was called 0 times while that size changed from 96 pt to 236 pt, so it cannot drive the panel's height.
- A hosting view pinned to the panel's content by layout constraints resized the panel with its top edge fixed, and the panel posted a resize notification each time.

This check says nothing about clicks, key status or what is drawn on screen.

## Amendment (2026-10-13)

A design audit of the interface changed the panel on the same day. The decision above stands, and these points add to it.

- **Edge.** The panel draws a 0.5 pt edge in the separator colour inside its 12 pt corner radius. The reopen window, which hosts the same view, draws none.
- **Close fade.** A close fades the panel out over 0.15 s and then orders it out. With Reduce Motion on, the close is instant. Opening stays instant. A click on the item during the fade shows the panel again, because only the latest close may order the panel out.
- **Shortcuts.** The five panel actions have Control-Command key equivalents (P, K, I, S and R) on SwiftUI controls. They act only while the panel or the reopen window is key, and still no key event is monitored anywhere in the app.
- **Show request.** The same reducer takes a show request. It opens a hidden panel without the 0.3 s guard and leaves a shown one alone. Finishing onboarding sends it, one turn of the main queue after the onboarding window closes.
- **Not verified:** the list above grows by the five shortcuts and their hints, by the fade and a click on the item during it, and by the panel opening when onboarding finishes. None of them had been observed on a real menu bar when this was written.
