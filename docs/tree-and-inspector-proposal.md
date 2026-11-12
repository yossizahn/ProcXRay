# Proposal: a grouped process tree, pickable columns and a linked inspector

Status: proposal, written 2026-11-12. Steps 1–5, 13 and 14 of the order of work are implemented: Smart tree with roll-ups, launchd labels from all three domains, Extensions with extension points, role groups and terminal sessions inside units (see `SmartTree.swift`), process chips with back/forward in the current tabs (see `UI/InspectorNavigation.swift`), the header menu and View ▸ Columns, and the column catalogue's "have" columns as descriptors with group-row rules (see `UI/Columns.swift`). Deviations: the `.appex/` rule is checked before the LaunchServices `UIElement`/`BackgroundOnly` rules, because Finder Sync and Quick Look extensions register as `BackgroundOnly` and otherwise filled Background apps. The chip's hover card is a tooltip rather than a popover, so it never covers what the pointer is moving towards; chips also have a context menu (Show, Open in New Window, Copy PID, Copy Path, Reveal in Finder). Step 5 differs in four places, from measuring on 2026-11-12. The Firefox process type is the last argument of `plugin-container` (22 `tab`, 2 `utility`, 1 `rdd`, 1 `socket`), so content processes are `tab` only and the others go to Utility and Network. Electron's plain `… Helper` runs both the GPU process and utilities, so `--type=` from argv decides, read once per process and only for executables named like helpers; the bundle-name suffix is the fallback when argv can't be read. Terminal sessions are found anywhere in a unit, not only among the root's direct children: Claude's 11 shells hang off a pty-host utility helper. A terminal whose only process is its shell gets no tty row (the Context column and the search name the tty), and no role group is made when every member would land in the same one. Step 13 keeps the hidden columns in its own app-wide setting (`hiddenColumns`) rather than in AppKit's autosave, because View ▸ Columns and every open window need one shared value; the autosave still keeps order and width. The two coalition columns start hidden. "Thr", "Res. coal." and "Jetsam" became "Threads", "Res. coalition" and "Jetsam coalition", and default widths are at least the width of the header when sorted (bold title plus arrow), which "CPU %" did not fit before. Step 14 differs as follows. Visibility is stored as the list of *shown* columns (`shownColumns`, migrated once from `hiddenColumns`), so a column added later starts hidden, as the persistence rules require. State's running/sleeping comes from the running-thread count, because `p_stat` says runnable for nearly every process (143 of 143 app processes when measured). Hardened runtime shows "platform" for Apple platform binaries, which don't set the flag, and group rows leave them out of the count. A "same" group value is shown only when every member has it; otherwise the row counts the different values. A column switched on from View ▸ Columns goes just before Context, from the header menu next to the column that was right-clicked. Measured with `--bench` on 729 processes: building the Smart tree went from 12 ms to 15 ms with the default columns shown and 30 ms with all 42; hidden columns cost nothing. Chips so far appear in General (parent, responsible), Lineage and the group summary pane; the header, Origin and socket peers come with steps 7 and 9.

This covers three changes that build on each other:

1. **Smart tree**: a new default grouping that sorts every process into a small set of top-level categories, with sub-groups inside them, instead of the 550-row top level the responsible tree has today.
2. **Columns**: a catalogue of 52 columns drawn from data the app already reads, a way to pick them, and named column sets, instead of 13 fixed columns.
3. **Linked inspector**: the ten source-shaped tabs regrouped into six question-shaped ones, with every pid, path, label and signer turned into a link.

All counts below were measured on this machine on 2026-11-12 (macOS 27, Apple silicon, uid 501, no privileged helper, about 715 processes). The total moved between 705 and 718 across runs, so treat the figures as accurate to a few processes. The measurement scripts were throwaway and are not in the repo; each section says how its numbers were produced so they can be redone.

## Part 1: the process tree

### Why the tree is flat today

| Grouping | Top-level rows | Of those, with children |
|---|---|---|
| Parent tree | 613 | 8 |
| Responsible tree | 553 | 36 |

In the responsible tree 517 rows are childless, and only 161 processes sit under another one. Three things cause that:

- 600 of 705 processes have launchd as their parent, so `ppid` says nothing about them.
- The responsible pid is its own pid for 354 processes and unreadable without the helper for 199 (127 owned by root, 72 by other system users).
- Nothing groups the remaining rows by what they are. A widget extension, a root daemon and a menu bar app are all sibling rows.

### The model: attach, then categorise

The Smart tree is built in two passes.

**Pass 1, attach.** Each process gets at most one owner, by the first rule that matches. A process with no owner is the root of a *unit*.

| # | Rule | Measured effect |
|---|---|---|
| 1 | Left Behind group (existing logic) | unchanged |
| 2 | Responsible pid, when it is another live process | 161 processes |
| 3 | App extension whose containing `.app` is running: attach to that app | 9 of 104 extensions |
| 4 | Owner of the launchd pid domain the process runs in (`launchctl print pid/<n>`), for anything that is not an app extension | 1 process today; more with the helper |
| 5 | Parent pid, when it is not launchd or the kernel | 11 processes |

Rule 4 deliberately skips app extensions. The pid domain tells you the *host* of an extension, and for 100 of 104 extensions it does give an answer, but the host is a system daemon: `chronod` hosts 46 (widgets), `linkd` 25 (App Intents), `WallpaperAgent` 9, the Quick Look thumbnail agent 7. Nesting on that would produce a 47-process `chronod` unit that nobody thinks of as one thing. The host is shown as a link on the row and in the inspector instead.

**Pass 2, categorise.** Each unit root is placed in one category by the first rule that matches. Descendants follow their root.

| # | Category | Rule for the unit root | Units | Processes |
|---|---|---|---|---|
| 1 | Left behind | existing ghost groups | — | — |
| 2 | Apps | LaunchServices type `Foreground` | 12 | 151 |
| 3 | Background apps | LaunchServices type `UIElement` or `BackgroundOnly`, not Apple | 28 | 45 |
| 4 | Extensions | path contains `.appex/` | 89 | 98 |
| 5 | Third-party services | has a launchd label, not Apple, not an `application.*` label | 16 | 16 |
| 6 | System interface | LaunchServices type `UIElement` or `BackgroundOnly`, Apple | 42 | 50 |
| 7 | System services | everything else that is Apple | 344 | 353 |
| 8 | Other | no rule matched (one process with no readable path today) | 1 | 1 |

That is 532 units in 7 visible categories. The top level goes from 553 rows to 7, and the first three categories, which are what the user actually started, hold 40 rows between them.

"Apple" in the measurement was approximated by path (`/System`, `/usr`, `/sbin`, `/bin`, `/Library/Apple`). The implementation should use `SignInfo.isAppleSigned`, which already exists, and fall back to the path rule until signing info has loaded so rows do not jump categories a second after launch.

### Categories in detail

**Apps.** One row per foreground app, with its helpers grouped by role rather than listed flat. The largest units today are Claude (67 processes), Firefox (34), MarkEdit (12) and Slack (9), so the role groups matter more than the category itself.

Role of a child, first match:

| Role group | Signal | Notes |
|---|---|---|
| Renderers, GPU, Network, Utility | bundle name suffix such as `Helper (Renderer)`, or `--type=` in argv | Chromium and Electron. Measured in argv now: 12 utility, 4 renderer, 3 gpu-process. The bundle-name suffix needs no argv read. |
| Web content | executable name `com.apple.WebKit.WebContent`, `.Networking`, `.GPU` | WebKit apps |
| Content processes | `plugin-container` (24 running) | Firefox. I believe the process type is in argv, but did not check; without it these stay one group. |
| Extensions | `.appex/` | only the app's own, by rule 3 |
| XPC services | `XPCServices/` | |
| Terminal sessions | has a controlling tty | sub-grouped by tty, then process group, so a pipeline is one row |
| Helpers | anything else | |

A role group is only created when it would hold two or more processes. A lone helper sits directly under the app.

Terminal sessions are a role group and not a top-level category because every process with a tty already belongs to an app: all 10 tty processes measured sit under Claude or Ghostty through the responsible pid. A top-level category would pull them away from the app that owns the window. `tty` is already read from `kinfo_proc` and unused.

**Background apps.** Third-party things LaunchServices knows about that have no Dock icon: menu bar apps, updaters, login items. 61 processes are registered this way (19 `UIElement`, 42 `BackgroundOnly`), collapsing to 28 units. Two sub-groups, "Menu bar" (`UIElement`) and "Background only", are enough. This is the category most likely to surprise a user, so it sorts second.

**Extensions.** 95 extension processes whose containing app is not running, grouped by extension point. The extension point comes from the bundle's `Info.plist` (`NSExtension.NSExtensionPointIdentifier`, or `EXAppExtensionAttributes.EXExtensionPointIdentifier` for ExtensionKit); that lookup found a value for 96 of 102 distinct bundles. Of the six misses, four are iOS-app wrappers, where `Info.plist` is at the bundle root rather than under `Contents/`, and two have neither key.

| Extension point | Running |
|---|---|
| `com.apple.widgetkit-extension` | 41 |
| `com.apple.appintents-extension` | 25 |
| `com.apple.wallpaper` | 9 |
| `com.apple.quicklook.thumbnail.secure` | 6 |
| `com.apple.intents-service` | 4 |
| `com.apple.FinderSync`, `com.apple.modelmanager.inferenceprovider` | 3 each |
| eight others | 1–2 each |

Group titles should be readable names ("Widgets", "App Intents", "Wallpaper", "Quick Look thumbnails", "Finder Sync") from a small table, with the raw identifier as the fallback. Each row shows the containing app's name, taken from the bundle path (40 extensions are inside an `.app`) and the host daemon as a link.

**Third-party services.** Non-Apple launchd jobs with no LaunchServices record: 16 today. Split into "Daemons" (system domain, usually root) and "Agents" (gui or user domain). When Background Items have been loaded, each row gains the name of the app that installed it, matched on `BTMItem.executable` or `identifier`.

**System interface.** Apple processes registered with LaunchServices as `UIElement` or `BackgroundOnly`: Dock, Control Center, Notification Centre, WindowManager and similar. 90 processes carry those types (47 and 43), in 42 units. They are kept apart from System services because they are the Apple processes with visible UI, and the ones users most often want to restart.

**System services.** 344 units, 337 of them a single process. This category is useless without sub-groups, and the two obvious automatic keys do not work:

| Sub-group key | Buckets | Singletons |
|---|---|---|
| Third label component (`com.apple.<x>`) | 298 | 273 |
| Location (framework name, or `/usr/libexec`, `/usr/sbin`, …) | 119 | 92 |

The location key also puts 121 units in one `/usr/libexec` bucket. What does work is a hand-written keyword table matched against the executable name, launchd label and framework name. A first pass of nine subsystems written in a few minutes placed 259 of 344 units:

| Subsystem | Units |
|---|---|
| Logging, diagnostics, updates | 54 |
| iCloud, accounts, sync | 35 |
| Security, privacy | 31 |
| Networking | 29 |
| Audio, video, camera | 28 |
| Storage, files, backup | 25 |
| Search, intelligence, ML | 25 |
| Graphics, windows, input | 19 |
| Power, hardware, devices | 13 |
| Unmatched | 85 |

The table needs care before shipping: the first pass used first-match regexes, so some placements are wrong, and 85 units (`gamepolicyd`, `UserEventAgent`, `watchdogd`, `eligibilityd`, `remindd`, …) need either more keywords or an explicit name list. It should live in one data file, with an "Other system services" group for what is left, and a test that fails when the unmatched share on the build machine passes a threshold. Each subsystem is further split into "Daemons (root)" and "Agents (user)" only when it holds both.

### What the top level looks like

```
▸ Apps                         12 apps · 151 processes      38.2 %   9.1 GB
▸ Background apps              28 apps · 45 processes        1.4 %   1.2 GB
▸ Extensions                   95 processes                  0.3 %   1.9 GB
▸ Third-party services         16 processes                  0.1 %   210 MB
▸ System interface             42 · 50 processes             2.0 %   1.4 GB
▸ System services              344 · 353 processes           4.1 %   3.8 GB
▾ Left behind                  2 groups
    † Xcode — exited           3 processes
```

Expanded:

```
▾ Apps
  ▾ Firefox                    34 processes                 12.0 %   3.1 GB
      firefox                  pid 2211
    ▸ Content processes        24
    ▸ XPC services             3
  ▾ Ghostty                    7 processes
      ghostty                  pid 4410
    ▾ Terminal sessions
      ▾ ttys000
          zsh                  pid 4502
        ▾ job 4610             npm run dev | tee log
            node               pid 4610
            tee                pid 4611
```

The CPU and memory figures in these sketches are placeholders, not measurements.

### Row behaviour

- **Roll-ups.** Every group row shows the sum of its subtree for CPU, memory, disk and energy. `ProcNode.cpuKey` and `memKey` already hold subtree totals for sorting; the outline needs to display them and the other columns need the same treatment.
- **Sort inside, not across.** Categories keep a fixed order. The sort column orders units inside a category and members inside a unit. A "sort categories too" option is not worth having.
- **Collapse identical siblings.** Three or more siblings running the same binary become one expandable row ("distnoted ×24"). Measured benefit under the attach rules above: 5 sets covering 49 processes, saving 44 rows, almost all inside apps. Small, so this is a late step.
- **Expansion state.** Categories 2 and 3 start expanded, the rest collapsed. State is stored per category and per unit, keyed by something stable across launches (bundle id or path, not pid).
- **Filtering.** The existing `prune` keeps a group when any descendant matches. With a filter active, every surviving group auto-expands and group rows show "3 of 151".
- **Selection on a group row.** Selecting a unit row selects its root process. Selecting a category or role row shows a summary pane: member count, totals, top five by CPU and memory.
- **Badges.** Small glyphs on the name cell for root, not sandboxed, Rosetta, unsigned or ad hoc, and Left Behind, so the risky rows stand out without adding columns.

### Pivots and filter chips

The grouping menu keeps Smart, Parent, Responsible, Coalition, Jetsam and Flat, and gains a "Group flat list by" submenu: signer or team, user, launchd domain, sandboxed, architecture. Each is a `Dictionary(grouping:)` over fields `ProcInfo` already has, plus roll-ups.

Filter chips above the tree combine with the text filter:

- Started in the last 5 minutes
- Non-Apple running as root
- Unsigned or ad hoc
- Not sandboxed
- Rosetta
- Using more than 5 % CPU

### Data this needs

| Need | Source | Cost and status |
|---|---|---|
| LaunchServices type per pid | `LSApp.type`, already parsed | free |
| tty | `kinfo_proc`, already read | free; add to `ProcInfo` |
| launchd label and domain for system daemons | `launchctl print system`, `print gui/<uid>`, `print user/<uid>` | Works without root. `launchctl list` (used now) covers only the gui domain: 214 running labels. Adding the other two gives 400 (157 system, 29 user). Three calls on the slow tick in place of one. |
| pid-domain owner | `launchctl print pid/<n>` | One call per process. 2.4 s for all of this user's processes, so it cannot run every tick: do it once per new process, in the background, like signing. Fails with "Operation not permitted" for root-owned pids; needs the helper for those. |
| Extension point | bundle `Info.plist` | Read once per bundle path and cached. |
| Chromium role | bundle name suffix; argv as a fallback | argv means `KERN_PROCARGS2` per helper process, once, cached by `key`. Cost not measured. |
| Subsystem | keyword table over name, label, framework | pure computation |
| Responsible pid for root processes | helper (`allMetrics` already returns it) | 199 processes have no readable responsible pid without it |

New `ProcInfo` fields: `tty`, `launchdDomain`, `domainOwner`, `extensionPoint`, `role`, and a computed `category`. `launchdLabel` becomes available for system daemons as a side effect, which also improves the launchd tab.

### Code changes

- `Grouping` gains `.smart` and becomes the default. The raw value of existing cases stays as is, since it is persisted.
- `ProcNode` gains a `kind` (`category`, `unit`, `role`, `session`, `collapsed`, `process`), so the outline can style and summarise group rows without parsing titles.
- Synthetic row ids need a scheme like the existing `groupID`: stable across refreshes, or the outline sees moved rows and rebuilds (the comment on `sorted` describes that failure). Hash of category plus unit key into a reserved negative range.
- Classification runs in `Store.snapshot`, off the main thread, and only for processes that are new or whose `codeKey` changed.
- `buildNodes` gets a `.smart` case built from the two passes; `tree(_:parentOf:)` can serve pass 1 unchanged.

### Risks and open questions

- **Category jumps.** A process can change category when signing info or the LaunchServices record arrives. Mitigation: path-based provisional answer, and never move a row the user has selected until the selection changes.
- **Subsystem table rot.** Apple adds daemons every release. The unmatched-share test catches it; the "Other" group keeps it harmless.
- **Is System interface worth a category?** It could be a subsystem of System services. I would keep it separate and see whether it earns its place.
- **Extensions under their app when it is running.** Only 9 extensions move today, so the rule is cheap either way. Leaving all extensions in one category would be simpler and more predictable.

## Part 2: columns and the column picker

### What is there today

`ProcessOutline.Column` defines 13 columns: Name, PID, CPU %, Memory, Thr, User, Responsible, Res. coal., Jetsam, Signer, Disk I/O, Started and Context. They can be reordered and resized, and AppKit saves that under the autosave name `ProcessOutline.columns`. What is missing:

- **No way to hide or add a column.** The header has no menu and nothing sets `isHidden`.
- **Everything is shown at once.** The ideal widths in the code add up to 1,378 pt, 1,456 pt with the 6 pt cell spacing, so the table scrolls sideways in any window narrower than that. Two of the 13 are coalition ids, which matter in one grouping.
- **Most of what the app reads has no column.** `ProcInfo` and `Counters` hold close to 50 values; the 12 data columns show 13 of them, and Context summarises a few more as text.
- **Totals only.** Disk I/O is lifetime bytes read plus written. There is no column that says what a process is doing now, apart from CPU %.
- **Group rows fill three columns.** CPU %, Memory and Disk I/O show subtree totals; every other cell on a group row is blank.

### Column catalogue

Each column has an id, a title, a header tooltip, a default width, an alignment, a sort key and a rule for group rows. "Data" says what it needs: **have** means the value is already in `ProcInfo`, `Counters` or the signing cache; **rate** means it needs the previous sample kept per process, as `prevCPU` is kept now; **new** means a read the app does not make yet.

Group-row rules:

- **sum**: add the members. Used where the values really are additive.
- **same**: show the value when every member has the same one, otherwise a count ("3 users").
- **root**: on a unit row, the root process's value; blank on category and role rows.
- **blank**: no value, because a total would mislead. Resident and virtual sizes count shared pages once per process, and peaks happened at different times.

**Identity**

| Column | Shows | Group row | Data |
|---|---|---|---|
| Name | icon, name, badges; always first, cannot be hidden | title | have |
| PID | | root | have |
| User | | same | have |
| Kind | category and role: "App · Renderer", "Extension · Widgets", "System service · Networking" | same | have (role and subsystem arrive with steps 5 and 6) |
| Bundle ID | | root | have for LaunchServices apps; new otherwise (`Info.plist`, cached per bundle) |
| Path | executable path, middle-truncated | root | have |
| Architecture | arm64, or x86_64 (Rosetta) | same | have |
| State | running, sleeping, stopped, zombie | count of non-sleeping | have |

**Ownership**

| Column | Shows | Group row | Data |
|---|---|---|---|
| Parent | name (pid) | root | have |
| Responsible | as today | root | have |
| launchd label | | root | have |
| Domain | system, gui, user | same | have |
| Extension point | readable name | same | have |
| Contained in | app whose bundle holds this executable | same | have |
| Res. coalition, Jetsam | ids, as today | same | have |
| TTY | `ttys003` | same | have (device number; needs `devname`) |
| Process group | pgid | same | have |
| Context | the existing one-line summary | member counts, as today | have |

**CPU**

| Column | Shows | Group row | Data |
|---|---|---|---|
| CPU % | as today | sum | have |
| CPU time | lifetime | sum | have |
| Threads | total | sum | have |
| Running threads | | sum | have |
| P-core share | percent of CPU time on performance cores | weighted by CPU time | have |
| Waiting for CPU | percent of the last interval spent runnable but not running | blank | rate |
| Context switches/s | | sum | rate |
| Instructions per cycle | | blank | have |

**Memory**

| Column | Shows | Group row | Data |
|---|---|---|---|
| Memory | footprint, as today | sum | have |
| Peak memory | lifetime peak footprint | blank | have |
| Resident | | blank | have |
| Virtual | | blank | have |
| Neural Engine | | sum | have |
| Page faults/s, Page-ins/s | | sum | rate |

**Disk**

| Column | Shows | Group row | Data |
|---|---|---|---|
| Read/s, Written/s | bytes per second | sum | rate |
| Disk read, Disk written | lifetime bytes, separately | sum | have |
| Disk I/O | read plus written, as today | sum | have |
| Logical writes | | sum | have |

**Energy and activity**

| Column | Shows | Group row | Data |
|---|---|---|---|
| Power | watts over the last interval, from billed energy | sum | rate |
| Energy | joules, lifetime | sum | have |
| Idle wakeups/s | | sum | rate |
| System calls/s | BSD plus Mach | sum | rate |
| Mach messages/s | sent plus received | sum | rate |

**Security**

| Column | Shows | Group row | Data |
|---|---|---|---|
| Signer | as today | same | have |
| Team ID | | same | have (signing cache) |
| Signing ID | | root | have |
| Sandboxed | yes, no, unknown | "all", "none" or "n of m" | have |
| Hardened runtime | yes, no | "all", "none" or "n of m" | have (signing cache) |

**Time**

| Column | Shows | Group row | Data |
|---|---|---|---|
| Started | age, as today | oldest member | have |
| Start time | absolute date and time | oldest member | have |

**Later, each needing a new read** (sources are in `process-info-sources.md`): Open files (`PROC_PIDLISTFDS`), Preventing sleep (`IOPMCopyAssertionsByProcess`), % GPU and GPU time (IORegistry), Priority and nice (`proc_bsdinfo`, `pti_priority`), Ports and Compressed memory (task port, helper only), Network bytes (`nettop` or NetworkStatistics).

That is 52 columns from data the app already holds, 10 of them rates, and 9 more behind new reads.

Rate columns share one mechanism with the inspector's Resources tab (step 8): keep the previous `Counters` per process key and divide the difference by the interval. The `proc_taskinfo` counters are 32-bit and wrap, so a negative difference is a wrap and shows as "—" for that tick.

### Picking columns

Three entry points, all driving the same state.

**1. Header context menu.** Right-click anywhere on the header:

```
Size Column to Fit
Size All Columns to Fit
────────────────────────
✓ PID
✓ CPU %
✓ Memory
  Threads
✓ User
  …the columns shown now, then the rest of the Overview set
────────────────────────
Identity            ▸
Ownership           ▸
CPU                 ▸
Memory              ▸
Disk                ▸
Energy and activity ▸
Security            ▸
Time                ▸
────────────────────────
Column Set          ▸   ● Overview   CPU   Memory   Disk & Energy   Security   Ownership
Customize Columns…
Reset Columns
```

The top section lists what is visible plus the active set's defaults, so the common toggles are one click. The submenus hold the full catalogue with checkmarks. A new column appears to the right of the one that was clicked. When the click lands on a column, the menu gains "Hide *title*" as its first item.

**2. View ▸ Columns.** The same menu in the menu bar. A header's context menu cannot be reached from the keyboard, so this is the accessible route, and it is where the set shortcuts live.

**3. Customize Columns… sheet.** For bulk changes and for finding a column by what it means:

```
┌ Customize Columns ──────────────────────────────────────────┐
│ [ Search columns                                         ]  │
│                                                             │
│ SHOWN — drag to reorder                                     │
│ ☰ ☑ PID                                                     │
│ ☰ ☑ CPU %          Share of one core over the last tick     │
│ ☰ ☑ Memory         Physical footprint                       │
│ ☰ ☑ Power          Watts over the last tick · billed energy │
│                                                             │
│ CPU                                                         │
│   ☐ CPU time       User plus system, lifetime               │
│   ☐ Waiting for CPU   Runnable but not running              │
│ MEMORY                                                      │
│   ☐ Peak memory    Highest footprint since launch           │
│   ☐ Compressed     Needs the privileged helper              │
│                                                             │
│ Set: [ Overview ▾ ]   [Save as New Set…]      [Reset] [Done]│
└─────────────────────────────────────────────────────────────┘
```

One list, not the two-list Inactive/Active dialog that Process Hacker uses: shown columns sit at the top in display order and can be dragged, the rest are grouped below, and search filters both by title and description. Changes apply to the table live, so there is no Cancel; Reset restores the set's defaults. Each row carries the same one-line description as the header tooltip, and says when a column needs the helper or is expensive.

### Column sets

A set is a named, ordered list of columns with widths and a sort. Switching sets swaps all of that at once, which is what makes a 52-column catalogue usable: nobody wants 52 columns, they want the six that answer the current question.

| Set | Columns after Name | Default sort |
|---|---|---|
| Overview | CPU %, Memory, Power, Read/s, Written/s, User, Signer, Started, PID, Context | CPU % descending |
| CPU | CPU %, CPU time, Threads, Running threads, P-core share, Waiting for CPU, Context switches/s, System calls/s, PID | CPU % descending |
| Memory | Memory, Peak memory, Resident, Virtual, Neural Engine, Page faults/s, Page-ins/s, PID | Memory descending |
| Disk & Energy | Read/s, Written/s, Disk read, Disk written, Power, Energy, Idle wakeups/s, PID | Written/s descending |
| Security | User, Signer, Team ID, Sandboxed, Hardened runtime, Architecture, Path | Signer |
| Ownership | Kind, Responsible, Parent, launchd label, Domain, Contained in, Started | Name |

Overview is the default. With the current widths and 60 to 70 pt for the new columns it comes to about 1,095 pt with Context at its 120 pt minimum, against 1,456 pt for today's fixed layout.

- Sets are switched from the header menu, View ▸ Columns, and a menu button beside the Group picker in the toolbar. ⌃1 to ⌃6 select the first six.
- Editing columns while a set is active changes that set. "Reset Columns" restores a built-in set's defaults; "Save as New Set…" keeps the current layout under a new name. User sets can be renamed and deleted; built-in ones cannot.
- Sets are independent of the grouping. Coalition ids are not forced on when grouping by coalition, because the group row's title already carries the id.

### Behaviour details

- **Name is fixed.** It is the outline column: always first, never hidden, not offered in the menus.
- **Sorting.** Every column with a value sorts; group rows sort by their group-row value. Sorting stays single-key, as now. If the sort column is hidden, the sort falls back to the set's default.
- **Size to fit.** Double-clicking a column divider, or the menu item, sizes the column to its widest visible cell (`outlineView(_:sizeToFitWidthOfColumn:)`).
- **Header tooltips.** `NSTableColumn.headerToolTip` explains each column and its unit. Abbreviated titles such as "Thr" and "Res. coal." become readable, since they no longer have to fit a 13-column row.
- **CPU % scale.** A View option: percent of one core (today's behaviour, can pass 100) or percent of all cores.
- **Bars.** An optional faint bar behind CPU %, Memory, Power and the disk rates, scaled to the largest value in view, so outliers are visible without reading numbers.
- **Show as Column.** A context menu item on any value in the inspector's Overview and Resources tabs that has a matching column. This is the reverse of a link: the inspector teaches which columns exist.
- **Copy Row.** Copies the visible columns, tab-separated, with a header line when several rows are copied.

### Reading only what is shown

Columns under "Later" need reads the app does not make per tick, and some are expensive. The store gets a set of *wanted sources* derived from the visible columns across open windows, and `snapshot` skips a source nobody is showing. Hiding the GPU column stops the IORegistry walk. Rates are different: the counters are read every tick anyway, so keeping the previous sample costs a dictionary and is always on.

### Persistence

AppKit's column autosave stores order, width and, per the comment on `autosaveTableColumns` in `NSTableView.h`, the hidden flag. That is enough for the first step: a header menu that toggles `isHidden` on the existing 13 columns needs no new storage. The saved state for this app already contains the hidden key.

Sets need more than one layout, so from that point the app owns the state: `[ColumnSet]` as JSON in `UserDefaults`, where a set is a name, a list of column id and width pairs, and a sort, plus the active set's name. Autosave is switched off then. Two rules keep upgrades clean:

- A column id that is no longer in the catalogue is dropped when a set is loaded.
- A column added in a later version is hidden in existing sets, and visible only in built-in sets that list it and that the user has not edited.

Existing widths and order from the autosave blob are not migrated; the app is pre-release and the blob is an AppKit archive.

### Code changes

- `Column` stops being a 13-case enum with switch statements for title, width and comparator, and becomes a table of descriptors: id, title, tooltip, group, width, alignment, a value function `(ProcNode) -> CellValue` and a group-row rule. `Cell.show` renders a `CellValue` (text, number with unit, or a small set of special cases such as Responsible) and stops switching on the column.
- `ProcNode` gets its group-row values from one aggregation pass in `Store.sorted`, where `cpuKey` and `memKey` are filled now, driven by each visible column's rule, so hidden columns cost nothing.
- The per-column `KeyPathComparator` properties on `ProcNode` are replaced by comparing `CellValue`s, so a new column needs one descriptor and no new key property.

## Part 3: the inspector

### What is wrong today

The ten tabs are General, Lineage, Signature, Entitlements, Args & Env, Files & Sockets, Memory Map, Sample, Logs and launchd / LS. They follow where the data comes from, so one question needs several tabs: "why is this running?" is spread over General (parent, responsible, label), Lineage and launchd / LS.

Specific problems, from the code:

- `GeneralTab` is a single key-value list of up to 35 rows: identity, relationships, state, memory, CPU, I/O and counters with no grouping.
- Counters are lifetime totals. A process that made 4 billion syscalls last week looks the same as one making them now.
- `LineageTab` rows are an icon, name, pid and path. They do not select or open the process they name. The same is true of every pid in General.
- Files & Sockets shows a socket's peer address but not the process on the other end.
- Entitlements are a flat key list; nothing says which ones matter.

### Proposed structure

A fixed header above six tabs.

| New tab | Replaces | Question it answers |
|---|---|---|
| Overview | top of General | What is this? |
| Origin | Lineage, launchd / LS, Args & Env | Why is it running, and who does it belong to? |
| Trust | Signature, Entitlements | What is it allowed to do? |
| Resources | rest of General, Memory Map | What is it costing me? |
| Connections | Files & Sockets | What is it talking to and touching? |
| Activity | Logs, Sample | What has it been doing? |

Raw tool output stays available in every tab through the existing `RawToggle`.

### Header

Always visible, whatever the tab:

```
[icon] Firefox Web Content   pid 2240 · yossi · 3 h 12 m          ← →   [Pin]
       Content process of [Firefox 2211] · sandboxed · Mozilla Corporation
       ⚑ not notarised?  ⚑ Rosetta                         [Signal ▾] [Reveal]
```

The second line is a generated sentence built from category, role, owner, sandbox state and signer, with the owner as a link. The third line holds badges and actions. Back and forward buttons belong here because following links makes the inspector a browser.

### Overview

- Four tiles with a sparkline each: CPU, memory footprint, disk, energy. The store keeps a short ring buffer per process (120 samples at the 2 s tick is four minutes) to draw them.
- A facts grid of about ten rows: path, bundle, version, user, started, state, architecture, sandbox, working directory, category and role.
- "Related" strip: owner, parent, number of children, number of processes it is responsible for, each a link into Origin.

### Origin

A vertical chain read top to bottom, each step a card with a link:

1. **Installed by**: the Background Items record, when loaded. App name, developer, enabled and allowed state.
2. **Launched by**: the launchd job: label, domain, plist path with a Reveal button, `RunAtLoad`, `KeepAlive`, last exit status. For a LaunchServices app: launched by the user, with the LS record. For an extension: the extension point, the host daemon (pid-domain owner) and the containing app.
3. **Parent chain**: the existing ancestors list, as chips.
4. **Responsible**: the responsible process, or the Left Behind explanation.
5. **Command**: argv, environment and working directory, collapsed by default (the current `ArgsEnvView`).

Below the chain, the reverse relations as collapsible lists, as Lineage has now: children, processes this one is responsible for, same resource coalition, same jetsam coalition. Added: same bundle, same binary (same `cdhash`), and for a host daemon, the extensions running in its pid domain.

### Trust

- **Verdict line**: "Apple platform binary", "Developer ID: Team Name (TEAMID), hardened runtime", "ad hoc signed", "unsigned". Derived from `SignInfo` fields that exist.
- **Signature**: identifier, team, authority chain, flags decoded, cdhash, designated requirement. As now.
- **Sandbox**: yes or no, and the container path when sandboxed.
- **Entitlements grouped by capability**: Files, Network, Hardware (camera, microphone, USB, Bluetooth), Personal data (contacts, calendar, photos, location), Automation (Apple Events), Debugging and code loading, Private Apple (`com.apple.private.*`), Other. Grouping is a prefix table over keys.
- **Highlighted**: `get-task-allow`, `disable-library-validation`, `allow-unsigned-executable-memory`, `allow-dyld-environment-variables`, and any `com.apple.private.*` on a non-Apple binary.
- **Same team**: other running processes signed by the same team id, as links.

### Resources

Four sections, each a small table with a "now" column (rate since the last tick) beside the lifetime total:

- **CPU**: percent now, total time, P-core share, time waiting for a CPU, threads (running of total), instructions per cycle, context switches per second.
- **Memory**: footprint, peak footprint, resident, virtual, Neural Engine, page faults and page-ins per second. The `vmmap` chart sits here behind a "Load memory map" button, since it is slow.
- **Disk**: bytes read and written per second and total, logical writes.
- **Energy and wakeups**: billed energy as watts now and joules total, idle wakeups per second.
- **System calls and IPC**: BSD and Mach syscalls per second, Mach messages in and out per second.

Rates need the previous `Counters` kept per process, the same way `prevCPU` is kept now. The `proc_taskinfo` counters wrap at 2^32, so a negative delta must be treated as a wrap, not shown.

Cheap additions listed in `process-info-sources.md` that belong here: open file descriptor count (`PROC_PIDLISTFDS`), power assertions (`IOPMCopyAssertionsByProcess`; 4 assertion holders right now), CPU time per QoS class.

### Connections

The current `LsofView`, with peers resolved.

- **Pipes and unix sockets.** `lsof` prints each endpoint's kernel address and its peer's (`->0x…`). Running `lsof -u <uid>` once and matching addresses resolved 272 of 274 pipe peers and 366 of 500 unix socket peers. The 134 unresolved socket peers are presumably in other users' processes, which this run could not see; running `lsof` through the helper should cover them, untested.
- **TCP on localhost.** 134 localhost TCP descriptors are visible. Matching local and remote port pairs across processes names both ends.
- **Files.** "Also open in" for a selected file, from the same all-process `lsof` run. Reveal in Finder. Group by volume and by location (app bundle, container, `~/Library`, temporary, system).
- **Listening ports** called out at the top, since that is the usual reason to open this tab.

The all-process `lsof` run is expensive, so it happens only when this tab is open, with a manual refresh. Its cost was not timed.

A small graph view (this process in the middle, peers around it, edges labelled pipe, socket, TCP) is a natural later addition once peers are resolved.

### Activity

- **Timeline** recorded by ProcXRay while it runs: started, exec'd a different binary (cdhash changed, which the store already detects), child spawned or exited, CPU or memory crossing a threshold, signal sent from this app. Nothing else in the app keeps history, so this is new state: a capped event list per process key.
- **Logs**: the current view, with the timeline's events drawn as markers on its histogram.
- **Sample**: the current view.

### Links

One component, a process chip (icon, name, pid), used wherever a pid appears: header, Origin chain, reverse lists, socket peers, same-team list.

- Click: select that process in the tree and show it in the inspector.
- Cmd-click: open it in a separate inspector window (`inspect` already exists as a command).
- Hover: a small card with path, user, CPU and memory.
- A chip for a process that has exited renders struck through and is not clickable.

Other values become links by context menu rather than by click, so text stays selectable:

| Value | Menu actions |
|---|---|
| Path | Reveal in Finder, Copy, Show processes running this binary |
| Signer or team id | Filter tree by this team |
| User | Filter tree by this user |
| launchd label | Show in the launchd view, Reveal plist |
| Bundle id | Show in Apps view, Show in Background Items |
| Coalition id | Switch tree to coalition grouping and select it |

Navigation history is a list of process keys with an index, per inspector. Selecting from the tree pushes; back and forward move the index. An entry whose process has exited still shows its last snapshot, as the inspector does today for an exited selection.

### Later: compare and pin

- **Pin**: keep the inspector on one process while the tree selection moves. When the process exits, the pinned inspector shows the last snapshot and the exit time.
- **Compare**: select two processes and diff entitlements, environment, arguments, signature and loaded images side by side. Most useful for two helpers of one app that behave differently.

## Order of work

Each step is usable on its own. Sizes are relative.

| # | Step | Size | Depends on |
|---|---|---|---|
| 1 | Smart tree with categories 2, 3, 5, 6, 7 and roll-up columns; no sub-groups | M | — |
| 2 | launchd labels from all three domains | S | — |
| 3 | Extensions category with extension points | S | 1 |
| 4 | Process chips and back/forward in the current tabs | M | — |
| 5 | Role groups inside apps, terminal sessions | M | 1 |
| 6 | System services subsystem table | M | 1, 2 |
| 7 | Tab regroup: header, Overview, Origin, Trust | L | 4 |
| 8 | Resources with rates and sparklines | M | 7 |
| 9 | Connections peer resolution | M | 4 |
| 10 | pid-domain owner (extension hosts), via helper for root | M | 3 |
| 11 | Filter chips, pivots, identical-sibling collapse | S each | 1 |
| 12 | Timeline, pin, compare | L | 7 |
| 13 | Header menu and View ▸ Columns to show and hide the existing columns; size to fit; header tooltips | S | — |
| 14 | Column descriptors, the "have" columns of the catalogue, group-row rules | M | 13 |
| 15 | Rate columns | M | 14; shares the previous-sample store with 8 |
| 16 | Column sets, Customize sheet, own persistence | M | 14 |
| 17 | Columns needing new reads, read only while shown | S–M each | 14 |

Steps 1 and 4 give the most for the least: the tree stops being flat, and the inspector's existing content becomes navigable, with no new data sources. Step 13 is small and independent of everything else, and step 14 is where the code gets simpler, so columns can run alongside either part.

## Not measured

- Time to read `KERN_PROCARGS2` for every helper process, and to run `lsof` across all processes.
- Anything that needs the helper: responsible pid and pid domains for root processes, socket peers in other users' processes.
- How the category counts look on a machine with a different mix of apps. Every number here is from one machine at one moment.
- The Firefox process-type argument.
- The per-refresh cost of showing more columns, and of the group-row aggregation pass.
- Whether a column added after a layout was autosaved keeps its default hidden state. This only matters if step 13 ships long before step 16.
