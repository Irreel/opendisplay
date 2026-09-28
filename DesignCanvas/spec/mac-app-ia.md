# Design Canvas Mac app: information architecture

**Status:** Draft v0.2, 2026-09-23. Handoff for the menu-bar app redesign, implemented the same day (v0.1 was the pre-implementation handoff). Scope is the MVP as the PRD defines it: Claude Code only, no agent picker. Section 9 lists what the implementation touched.
**Owner:** AntheaZ
**Sources:** [FigJam board "Design Canvas", IA for Mac App](https://www.figma.com/board/eMxEcxvPAeNtaoWbsKaa6S/Design-Canvas?node-id=32-406); `PRD-DesignCanvas.md` v0.7 section 6 and requirements D2, D3, D7; `DesignCanvas/Mac/App/MenuBarView.swift`, `DisplayStateCopy.swift`, `SessionStateClassifier.swift` as of 2026-09-23.

## 1. Current IA, as built

The app is a `MenuBarExtra` with a fixed `scribble.variable` icon and a 320 pt window-style popover. Top to bottom:

```
Menu bar icon           static glyph, no state
Popover
 ├─ Status
 │    ├─ daemon line       "Daemon: down" | "Port 47100 is in use by an unknown process" | "Daemon: running"
 │    ├─ retry line        "Daemon stopped retrying — port may be in use"          (when daemonGaveUp)
 │    ├─ session line      one of eight DisplayState strings (section 4)
 │    └─ warning           "⚠ Two channel connections detected"                    (when secondSubscriber)
 ├─ iPads
 │    ├─ empty             "No iPad connected — open Design Canvas on the iPad"
 │    ├─ connected rows    name, engine status, USB|WiFi, [Disconnect]
 │    ├─ discovered rows   name, transport, [Connect]
 │    └─ pending line      "N sketches waiting for the daemon"
 ├─ Reset (only in existingSessionDetected, foreignDaemon, portOccupiedUnknown)
 │    ├─ [Reset Design Canvas Processes] + caption
 │    ├─ [Start New After Reset]                                                (existingSessionDetected only)
 │    └─ outcome line
 ├─ ── divider ──
 ├─ Screen Recording      "granted" | "not granted" [Grant] + caption
 ├─ ── divider ──
 ├─ Server build          "unset" | "set" [Set…] + path
 ├─ ── divider ──
 ├─ Recent projects       header, one link per recent, [Open Project…], "Selected: <name>" + directory
 ├─ ── divider ──
 ├─ Session               [Start session] (disabled: "No project selected" | "No server build set")
 │    ├─ ".mcp.json has an outdated entry" [Update .mcp.json entry]
 │    ├─ config warning
 │    └─ [Disconnect] + caption                                                  (when sessionStarted)
 ├─ ── divider ──
 └─ [Quit]
```

### What is wrong with it

1. **It speaks the system's language.** Daemon, port 47100, channel connections, server build, `.mcp.json`. The board's two status items are "connection with iPad" and "connection with coding agents". Amy knows those two things and nothing else on the list.
2. **Two hops, four vocabularies.** The Claude Code hop is spread over the daemon line, the session line, the retry line and the warning, each with its own phrasing and tint. The iPad hop is a list plus a pending-uploads line. Nothing says "both hops are fine" in one glance, which is PRD goal 6.
3. **The primary action is at the bottom.** Start session sits under two developer settings and a divider. Every first-run user scrolls past Screen Recording and Server build to find it.
4. **Developer settings are peers of user items.** Server build is a build-time setting; it has the same weight as the project.
5. **Recents before the selection.** The list of recent projects is drawn above the project that is actually selected.
6. **The icon carries no state.** The one thing a menu-bar app can show without a click is unused.
7. **Screen Recording is filed as a setting, but it is a blocker.** Without it nothing mirrors, so it belongs in the iPad hop's state, not in a settings row.

## 2. Principles for the redesign

- **The board's order.** Connection status, then project. The third board item, the agent client name, is out of scope and gets no placeholder.
- **Name what the user knows.** Two rows, "iPad" and "Claude Code", each with one state word. Daemon, port and channel wording move to a Details window, where the person debugging wants it.
- **Keep D7 exactly.** Every `DisplayState` still maps to a distinct, honest state; only the words and the placement change. Section 4 is the mapping and is the contract for the implementation.
- **The next action sits under the status that needs it.** Start, Retry, Reset, Grant and Connect appear as the trailing action of the row whose state calls for them; there is no separate Session section.
- **One surface for people, one for developers.** The popover is for Amy; Settings and Details are for whoever is debugging.

## 3. Proposed IA

```
Menu bar icon
 ├─ scribble glyph, outline      no session running
 ├─ scribble glyph, filled       Claude Code connected, iPad connected  ("ready")
 ├─ filled with a dot            one hop connected, the other not
 └─ filled with a badge          attention: a state with a red tint in section 4, or a pending sketch

Popover (320 pt)
 ├─ Summary line                one sentence for the whole app, section 6
 ├─ Connection status
 │    ├─ iPad row              [icon] <device name or "iPad">   USB|WiFi   <state>   [action]
 │    │    └─ more iPads       one row per further connected or discovered device
 │    └─ Claude Code row       [icon] Claude Code                         <state>   [action]
 │         └─ sub-line         pending sketches, or a warning (section 4)
 ├─ ── divider ──
 ├─ Project
 │    ├─ folder name            primary, or "No project selected"
 │    ├─ directory              secondary
 │    └─ [Change…]             pop-up: recents (max 3), then "Open Folder…"
 ├─ ── divider ──
 └─ Footer                      [Details…]   [Settings…]   [Quit]

Details window (opens from Details… or from a red state's action)
 ├─ Daemon: pid, port, instance id, started at, health probe result
 ├─ Channel: count, attached at, owned by this app: yes/no
 ├─ iPads: id, name, transport, engine status, pending uploads
 ├─ Last error: the raw message
 ├─ [Reset Design Canvas Processes] + the existing caption   [Start New After Reset]
 └─ [Open Logs]

Settings window
 ├─ Screen Recording: state + [Open System Settings]
 ├─ Server build: path + [Choose…]                        (developer setting, hidden in release builds once the server is bundled)
 └─ Project config: ".mcp.json entry is current" | "outdated" [Update]
```

### Three states, drawn

```
No session                             Ready                                   Attention
┌──────────────────────────────┐       ┌──────────────────────────────┐        ┌──────────────────────────────┐
│ Waiting for an iPad          │       │ Ready — sketches go to       │        │ Claude Code didn't connect   │
│                              │       │ Claude Code                  │        │                              │
│ ▢ iPad          Not connected│       │ ▣ Amy's iPad    USB Connected│        │ ▣ Amy's iPad    USB Connected│
│   Open Design Canvas on iPad │       │ ▣ Claude Code       Connected│        │ ▢ Claude Code   Not connected│
│ ▢ Claude Code   Not started  │       │   1 sketch waiting to send   │        │   Check the Terminal  [Retry]│
│                     [Start]  │       │                  [Disconnect]│        │                              │
│ ───────────────────────────  │       │ ───────────────────────────  │        │ ───────────────────────────  │
│ myapp                        │       │ myapp                        │        │ myapp                        │
│ ~/Projects              Change…│     │ ~/Projects              Change…│      │ ~/Projects              Change…│
│ ───────────────────────────  │       │ ───────────────────────────  │        │ ───────────────────────────  │
│ Details…  Settings…    Quit  │       │ Details…  Settings…    Quit  │        │ Details…  Settings…    Quit  │
└──────────────────────────────┘       └──────────────────────────────┘        └──────────────────────────────┘
```

## 4. Claude Code row: state mapping

This table is the D7 contract. Left column is the classifier's output today; nothing in the classifier changes.

| `DisplayState` / flag | State word | Tint | Sub-line | Trailing action |
|---|---|---|---|---|
| `noDaemon` | Not started | secondary | — | **Start** (disabled with reason if no project or no server build) |
| `daemonOnly` | Not started | secondary | — | **Start** |
| `launchPending` | Starting… | orange | "Waiting for Claude Code in the Terminal" | — |
| `launchTimedOut` | Not connected | red | "Check the Terminal window" | **Retry** |
| `ownedAttached` | Connected | green | pending sketches if any | **Disconnect** |
| `existingSessionDetected` | Another session | orange | "A Claude Code session this app didn't start is attached" | **Details…** |
| `foreignDaemon` | Another instance | orange | "Design Canvas is already running elsewhere" | **Details…** |
| `portOccupiedUnknown` | Blocked | red | "Another app is using Design Canvas's port" | **Details…** |
| + `daemonGaveUp` | Stopped | red | "Stopped retrying" | **Retry** |
| + `secondSubscriber` | (unchanged) | orange sub-line | "Two sessions are attached; sketches may go to either" | (unchanged) |
| + `pendingUploads > 0` | (unchanged) | orange sub-line | "1 sketch waiting to send" / "N sketches waiting to send" | — |

Reset moves to the Details window in full (button, caption, Start New After Reset, outcome lines). The three states that offered it inline now offer **Details…**, which is one more click for a rare situation and keeps a destructive-looking button out of the main surface.

Disabled Start reasons, shown as the sub-line in secondary tint: "Choose a project first" / "Set the server build in Settings".

## 5. iPad row: state mapping

| Condition | Row | State | Action |
|---|---|---|---|
| Screen Recording not granted | "iPad" | Needs permission, red | **Grant** (opens System Settings; sub-line: "Design Canvas mirrors the screen. Takes effect after relaunch") |
| No devices connected or discovered | "iPad" | Not connected, secondary; sub-line "Open Design Canvas on the iPad" | — |
| Connected device | device name + USB/WiFi | engine status as today (Connected, Streaming…), green | **Disconnect** |
| Discovered, not connected (WiFi) | device name + WiFi | Available, secondary | **Connect** |

The permission row replaces the device rows while ungranted, because nothing can connect until it is.

## 6. Summary line

One sentence at the top, derived, never a fourth state machine:

| iPad | Claude Code | Sentence |
|---|---|---|
| connected | Connected | "Ready — sketches go to Claude Code" |
| connected | anything else | "Claude Code — <state word>", e.g. "Claude Code — Not started" |
| not connected | Connected | "Waiting for an iPad" |
| not connected | not started | "Waiting for an iPad" |
| permission missing | any | "Screen Recording needed" |
| any red state | | that row's sub-line |

Priority when several apply: permission, then red states, then Claude Code, then iPad.

## 7. Copy

All user-facing strings in one place so they can be reviewed together. Sentence case, no trailing periods on labels, periods on sentences.

| Where | Copy |
|---|---|
| Row labels | iPad · Claude Code |
| State words | Not connected · Not started · Starting… · Connected · Available · Another session · Another instance · Blocked · Stopped · Needs permission |
| Actions | Start · Retry · Disconnect · Connect · Grant · Details… · Change… · Open Folder… · Settings… · Quit |
| Project empty | No project selected |
| Start disabled | Choose a project first · Set the server build in Settings |
| Pending | 1 sketch waiting to send · N sketches waiting to send |
| Disconnect caption (Details) | Disconnect only stops this app tracking the session. Claude Code keeps running; quit it in its Terminal to end the session. |
| Reset caption (Details) | Stops Design Canvas helper processes. May detach an existing Claude Code channel. Never quits Claude Code or edits your files. |

## 8. Traceability

| Board / PRD | Where it lands |
|---|---|
| Board: Connection status (iPad, coding agents) | Section 3, Connection status block; sections 4 to 6 |
| Board: Current project folder name + directory | Section 3, Project block |
| Board: Coding agents client name | Out of scope (MVP only). The Claude Code row label is where it would become a picker |
| D2 keep the service running while open | Unchanged behaviour; surfaced as the Claude Code row |
| D3 pick project, configure, launch, never force-kill | Project block, Start action, Reset in Details with the existing caption |
| D7 honest session state | Section 4, one row per `DisplayState` |
| PRD goal 6, both hops at a glance | Two rows plus the summary line and the icon state |
| iPad P1 mirror, "project folder name or unselected" | Project block uses the same folder name the iPad shows |

## 9. Implementing it

Everything is view-layer; the classifier, engine and daemon are untouched. Implemented 2026-09-23 as listed, with the pure mapping in `MenuPresentation.swift` (22 tests) rather than inside `DisplayStateCopy.swift`, whose raw strings now feed the Details window.

| Change | File | Note |
|---|---|---|
| Row copy, tint, action per state (section 4) | `DisplayStateCopy.swift` | Extend the existing pure mapping with `stateWord`, `subline`, `action`; unit-test it in `DesignCanvasTests` the way `statusText` could be today |
| Popover layout (section 3) | `MenuBarView.swift` | Rewrite; keep `AppModel` bindings as they are |
| Summary line (section 6) | new `SummaryLine.swift` | Pure function of the two hops, tested |
| Icon state | `DesignCanvasMacApp.swift` | `MenuBarExtra` label switches SF Symbol variant on the same derived state |
| Details window | new `DetailsView.swift` | Hosts Reset and the raw fields; opened with `openWindow` since a window-style `MenuBarExtra` cannot present a sheet |
| Settings window | new `SettingsView.swift` | Screen Recording, Server build, `.mcp.json` repair |
| Recents pop-up | `MenuBarView.swift` | `Menu` over `model.recentProjects`, capped at 3 |

Order: 1 and 3 first (pure, tested), then the popover, then the two windows. Roughly one to two days.

## 10. Open questions

- **Icon glyph.** Resolved: `pencil.tip.crop.circle` and its `.fill`, `.badge.plus`, `.badge.minus` variants carry the four states. `scribble.variable` had no variants.
- **Recents cap.** Three (owner, 2026-09-23); `ProjectRecents` keeps eight.
- **Details as a window.** Two windows (Details, Settings) for a menu-bar app is one more than most have. Merging them into one window with two tabs is the fallback if it feels heavy.
- **Server build row in release builds.** Hidden once the server ships inside the bundle; until then it stays in Settings and the Start reason points there.
