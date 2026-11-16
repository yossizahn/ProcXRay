# Plan: group the menu bar dropdown by who the work is for

Status: implemented 2026-11-16 (`AmbientGroups.swift`, `AmbientMonitor.swift`, `Popover.swift`, `MenuBarViews.swift`), with the defaults of section 9. Differences from the plan:

- Leaders and the merge are recomputed every tick rather than cached per group: the whole grouping measures ~0.5 ms on ~800 processes once paths are searched as bytes, so a cache would save little and add a membership check of similar cost.
- A member that rule 1 or 2 matched alone falls through to the later rules (as the idle-shell example in section 5 already assumed), instead of becoming a plain row.
- A responsibility sub-group's row shows its responsible process's pid, since several can share a name (four `claude` sessions).
- Checks: `--groups` placed each of ~800 processes in exactly one group. `--ambient 30` CPU per tick, run twice each on a busy machine: before 10.7 and 11.0 ms, after 12.9 and 10.8 ms (within run-to-run noise). Rule 2 with a command running in a terminal was not exercised.

## 1. Goal

The menu bar dropdown and the Triage lists rank single processes. An app that spreads its work over many processes never tops the list, and a system process that does its work in one place always does. The dropdown should answer "what is using my CPU" with "Firefox, 22 %", not with whichever single process happens to be largest.

Measured on this machine on 2026-11-16 (779 processes, uid 501, with a throwaway probe that read each process's coalition, responsible pid, parent, tty, CPU over 2 s and footprint):

| Ranking | Top entries |
|---|---|
| CPU, per process | BackgroundShortcutRunner 67.8 %, siriactionsd 26.3 %, Claude Helper 18.5 %, Claude Helper (Renderer) 11.6 % |
| CPU, grouped | siriactionsd (4 processes) 95.3 %, Claude (63) 39.9 % |
| Memory, per process | Claude Helper (Renderer) 1,013 MB, loginwindow 724 MB, Slack Helper (Renderer) 461 MB |
| Memory, grouped | Claude (63) 3,978 MB, Slack (8) 871 MB, loginwindow (2) 724 MB |

Firefox, started for the test: 20 processes in one group, 22.3 % CPU and 1,843 MB together; its largest single process was 447 MB.

## 2. Constraints

- **General rules only.** Every rule below uses a mechanism the system applies to all processes: the kernel's coalitions, the responsible pid, the controlling terminal, bundle layout on disk. No rule names an app, and none parses an app's arguments (so no "tab" from Firefox's argv and no `--type=renderer` from Chromium's). Terminal sessions qualify because the tty is a kernel field every process has.
- **The monitor stays light.** `AmbientMonitor` deliberately reads no LaunchServices, launchd, signatures or argv, and a tick costs about 9 ms of CPU. That rules out reusing the Smart tree's `unitRoots`, which needs all of those. Grouping must add nothing measurable per tick.

## 3. The grouping key

**A group is a resource coalition**: the set of processes the kernel itself accounts for together. `Native.coalition(_:)` already returns it.

Why this key, measured:

| Property | Result |
|---|---|
| Readable without privileges | 749 of 749 processes in the first run (before Firefox was started). The responsible pid was readable for only 514 (own user's). |
| Agrees with responsibility | Of 146 processes whose responsible process is another process, all 146 are in the same coalition as it. Zero responsibility links cross a coalition, so a coalition always contains whole responsibility chains. |
| Collects work done on an app's behalf | Firefox's coalition holds the 16 processes from its own bundle, 3 system XPC services launched for it (`VTDecoderXPCService`, `com.apple.SafariPlatformSupport`, `SetStoreUpdateService`) and the 1Password browser helper it started. |
| Size | 779 processes form 593 groups: 536 of one process, 57 of more. |
| Stable | A process's coalition is set when it is spawned and does not change, so it is read once per process. |

Rejected alternatives:

- **Jetsam coalition.** It merges every extension into its host: one jetsam coalition held 50 unrelated widget extensions, another 26 Settings extensions. Right for memory-kill decisions, wrong for "whose work is this".
- **Responsible pid alone.** Unreadable for other users' processes without the helper, and it splits what the kernel accounts together (see sub-groups, 5).
- **The Smart tree's units.** Needs LaunchServices, launchd and Background Items data the monitor does not read.

### One merge on top: bundle containment

App extensions each get a resource coalition of their own (112 `.appex` processes sat in 112 coalitions), and so do helpers that launchd starts from inside an app's bundle. They belong with their app.

Rule: a group merges into another when its leader's executable lies inside the other group's leader's app bundle (`<Leader>.app/…`), and that app is running. This is path prefix matching on paths the monitor already keeps. It is the same idea as rules 3 and 3d of `SmartTree.unitRoots`, without the LaunchServices lookup.

Measured: 7 merges on this machine (BetterTouchTool 2, OpenInTerminal 2, 1Password 1, Dock 1, WindowManager 1). Only one level: a merged group does not pull others in after it.

## 4. Naming a group: its leader

The group shows the name and icon of one member, its leader. The kernel does not tell an unprivileged caller which process leads a coalition, so:

1. **By responsibility.** The member that most members name as their responsible process. Measured: in all 46 multi-member groups where responsibility was readable this gave one answer, never a tie.
2. **Fallback, when no member's responsible pid is readable** (other users' processes without the helper; 11 of 57 groups): among members whose executable is not inside an `.xpc` bundle, the oldest. Measured: correct in 9 of the 11 (`WindowServer` over `MTLCompilerService`, `syspolicyd` over `XprotectService`, `coreaudiod` over its driver helper); the other two were ties between equals (`systemstats` twice; `launchd` and `kernel_task`), where either answer is acceptable.
3. A group of one is that process.

The leader's display name follows the monitor's existing rule: the `NSRunningApplication` name when the process is an app, otherwise the executable's file name.

If the leader exits while members live on, re-run the rule on the survivors. The group's identity is the coalition id, not the leader, so its history and expansion state carry over.

## 5. Sub-groups

Inside a group, members are sorted into sub-groups by the first rule that applies. One level only.

| # | Sub-group | Rule | Example measured |
|---|---|---|---|
| 1 | Responsibility sub-group | The member's responsible process is not the group leader. One sub-group per such responsible process, named after it. | Claude's group of 63: the app itself with 30 processes; four `claude` command-line sessions with 9, 8, 8 and 6, each responsible for itself; two helper processes responsible for themselves. Firefox's group: `1Password-BrowserSupport`, responsible for itself. |
| 2 | Terminal session | The member has a controlling terminal. One sub-group per tty that holds two or more members, titled with the tty's name and its members' names. | When measured, every tty held one idle shell (ghostty 2, the Claude app 8), so none formed a sub-group and the shells fell to rule 4 as "zsh ×8". A session becomes a row of its own once something runs in it. |
| 3 | XPC services | The executable is inside an `.xpc` bundle (`SmartTree.isXPCService`). One sub-group for all of them. | Raycast 7 of 9, MarkEdit 8 of 9, Firefox 3. |
| 4 | Same-name set | Two or more remaining members share a name: "name ×N", the convention the process list already uses. | Firefox: plugin-container ×13. Claude: Claude Helper ×7, Claude Helper (Renderer) ×4. |
| 5 | (none) | Everything else is a plain row under the leader. | |

Rule 4 is what makes browser content processes collapse, with no browser-specific rule. Where an app's child processes register their own names with LaunchServices, the monitor's existing naming already uses them, so the sets split along those names for free.

A sub-group is only made for two or more members. A lone process that rule 1 or 2 matched is a plain row. Rule 2 is not tested in the measurements above beyond the idle-shell case; step 2's check must include a terminal with a command running.

## 6. Figures for a group row

| Figure | Group value |
|---|---|
| CPU, GPU, disk, network | Sum over members |
| Memory | Sum of footprints. Footprint is what the kernel charges each process, so it adds up; resident size would not. |
| History graph | A ring per group kept by the monitor, not a sum of the members' rings: members exit, and their history would take the group's past with it |
| Not responding | True when the leader is |
| Count | Number of processes, shown after the name |

When some members' usage is unreadable (other users' processes without the helper), the sum covers the rest. Mark such a row, as the group inspector does ("sums cover N of M").

## 7. Implementation

All in `Sources/ProcXRay/Ambient/`.

### 7.1 Monitor (`AmbientMonitor.swift`)

- `Stable` (read once per process) gains `coalition: UInt64?` from `Native.coalition` and `responsible: pid_t?` from `Native.responsible`. Two calls per new process, none per tick.
- `AmbientProc` gains `coalition`, `responsible`, `ppid` and `tty`. The last two are already in each record `Native.listProcesses` returns.
- New `AmbientGroup`: `id` (coalition id; for a process with no readable coalition, a synthetic id from its pid), `leader: AmbientProc`, `members: [AmbientProc]`, `subgroups: [AmbientSubgroup]`, the five summed figures, `covered` (members with readable usage).
- `sample` builds the groups after the process loop: bucket by coalition, apply the bundle-containment merge, pick leaders, build sub-groups. Leader choice and the merge depend only on membership, so cache them per group and recompute only for a group whose member set changed since the last tick.
- `Output` gains `groups` and `topGroups: [AmbientMetric: [AmbientGroup]]` (same one-pass selection as `top`).
- `Tracker` gains `groupHistory: [UInt64: ProcHistory]`, appended each tick from the group's sums and dropped when the group is gone.
- Put the grouping in its own file (`AmbientGroups.swift`) as pure functions over `[AmbientProc]`, so it can be tested from the command line without the monitor.

### 7.2 Dropdown (`Popover.swift`)

- The list shows groups by default. A two-way control in the tab bar switches between Groups and Processes (`@AppStorage("popover.grouped")`, default on); the flat list stays exactly as it is.
- A group row looks like today's `PopoverRow`: leader's icon and name, process count in the tertiary inline style, the group's graph and value. A disclosure chevron expands it in place to its sub-group rows and plain member rows; a sub-group row expands to its members. Expansion is remembered per coalition id for the life of the popover.
- A group of one renders as today's process row, with no chevron.
- Sort is by the selected metric's group value. The 150-row cap applies to top-level rows.
- Filters apply to the leader: Apps (leader is a regular app), 3rd party (leader is not Apple's), Mine (leader runs as you). Sums always cover the whole group, including Apple services working for a third-party app.
- Click on a group row: show the leader in the process list. Context menu: Show in Process List, Inspect, Show in Finder, Copy PID, all for the leader; member rows keep today's menu.
- The footer count reads "groups shown / processes running".

### 7.3 Triage (`Popover.swift` triage body, `MenuBarViews.swift` `TriageView`)

- "Top consumers" ranks groups (`topGroups`), each row showing the leader and the process count, expandable to the members that contribute most.
- Launched, Ended and alert rows stay per process, and gain the group's name as secondary text when the process is not its group's leader ("plugin-container · Firefox").
- Alerts themselves stay per process (see decision G2).

## 8. Order of work

| # | Step | Check |
|---|---|---|
| 1 | Read coalition and responsible into `Stable`; carry `ppid` and `tty` on `AmbientProc` | `ProcXRay --ambient 30`: per-tick CPU within noise of the figure before the change. Record both. |
| 2 | `AmbientGroups.swift`: bucketing, bundle-containment merge, leader, sub-groups; a `--groups` CLI mode that prints each multi-member group with its leader, sub-groups and sums | Output on a machine running a browser and a terminal: one group per app; every process appears exactly once; leaders match section 4's examples |
| 3 | `Output.groups`, `topGroups`, `groupHistory` | `--ambient 30` again: per-tick CPU still within noise. Top CPU printed per group. |
| 4 | Dropdown: grouped list, expansion, Groups / Processes switch | Open the popover with a multi-process app busy: it ranks by its sum; expanding shows sub-groups; switching to Processes shows today's list unchanged |
| 5 | Triage: top consumers by group; group name on launched, ended and alert rows | Popover triage and the main window's Triage section show the same ranking |

## 9. Decisions, with defaults

| # | Decision | Default | Alternative |
|---|---|---|---|
| G1 | Default view of the dropdown | Groups | Processes, with Groups as the option |
| G2 | Alerts on group totals | No: alerts stay per process, since the thresholds were chosen for one process (80 % of one core) | Also raise an alert when a group's sum stays above a separate, higher threshold |
| G3 | Bundle-containment merge | On | Off: pure coalitions, extensions and bundled helpers show as their own groups |
| G4 | Order of sub-group rules | Responsibility before terminal session, so a command-line tool that disclaims responsibility is one row, not split across ttys | Terminal session first |
| G5 | What the grouped view is called | "Groups" on the control; the column manager and tooltips say "Accounting group (resource coalition)", per the gloss rule in `ui-regrouping-plan.md` | |

## 10. Out of scope

- Any rule tied to one app or one browser engine.
- Changing the Smart tree or the process list. The two groupings answer different questions and may disagree at the edges: the tree nests a launchd job under the app that registered it, which is a different coalition here.
- The menu bar widgets themselves, which show system totals.
