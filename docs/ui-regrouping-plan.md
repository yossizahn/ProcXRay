# Plan: regroup the UI around one taxonomy

Status: plan, written 2026-11-16. Nothing here is implemented. It is written to be handed to an agent and done in the order of Part 9.

## 0. Read this first

### Goal

The app grew feature by feature and is now a kitchen sink: every piece of data is there, but where it lives and what it is called follow no single rule. This plan fixes grouping, ordering and naming. It is deliberately not a redesign: almost every step moves rows, renames things or changes a rule in one function.

### Principles (the owner's, in priority order for this work)

1. Grouping is logical. Logic matters more than looks.
2. The app is for power users, but a cryptic system term is never shown bare. A label is a plain phrase followed by the system's own term in brackets: "No Dock icon (UIElement)", "Privacy permissions (TCC)". The phrase says what it means; the term is what to search for. See "Glossed terms" in Part 1.
3. It is a Mac app: source-list sidebar, menu bar commands with shortcuts, standard controls.
4. Language is terse. No sentence where a row will do. Nothing stated twice on one screen.
5. Every item shows its source.
6. Every piece of available information is surfaced. Tooltips may explain; they never hold data.

### Ground rules for the implementer

- **One step per commit**, in the order of Part 9. Each step leaves the app working.
- **Open decisions** are listed in Part 10 with a default. Use the default unless the owner says otherwise; don't stop to ask.

### What was measured

All counts are from `ProcXRay --dump` and `--tree-stats` on 2026-11-16 (macOS 27.2, Apple silicon, uid 501, helper running, 939 processes).

| Smart tree category | Top-level rows | Processes |
|---|---|---|
| Apps | 11 | 184 |
| Background apps | 18 | 44 |
| Extensions | 104 | 106 |
| Third-party services | 16 | 16 |
| System interface | 42 | 53 |
| System services | 499 | 535 |
| Other | 1 | 1 |

Of 108 running `.appex` processes, 89 run from `/System` and 19 from elsewhere.

## 1. The taxonomy

The app has four groupings of the same facts that don't agree: 10 column sections (`Column.Section`), 6 inspector tabs, 9 cards in the Usage pane, and the by-API grouping in `docs/process-info-sources.md`. Replace the first three with one list. The sources doc stays by-API; it is the lookup table for Part 6.

**Glossed terms.** Principle 2's rule, applied to the terms this plan touches. Use these exact labels wherever the term appears as a label (group title, card title, row label, column title, badge):

| System term | Label |
|---|---|
| `UIElement` | No Dock icon (UIElement) |
| `BackgroundOnly` | No UI (BackgroundOnly) |
| TCC | Privacy permissions (TCC) |
| cdhash | Code hash (cdhash) |
| ASN | LaunchServices instance (ASN) |
| BTM | Background item (BTM) |
| send-once right | Replies owed (send-once) |
| jetsam band | Memory-kill band (jetsam) |
| jetsam coalition | Memory-kill group (jetsam coalition) |
| resource coalition | Accounting group (resource coalition) |
| pid domain | Per-process launchd domain (pid domain) |
| dirty tracking | Idle exit (dirty tracking) |

- Apply the same pattern to any other term of this kind you meet while editing a label: one a Mac developer would have to look up in xnu or a man page. Terms in everyday use need no gloss: PID, TTY, launchd, XPC, sandbox, QoS, Mach port, entitlement.
- The app already does this in places ("Same binary (same CDHash)", "Replies owed (send-once)"). Keep those; make the rest match.
- Where the bracketed form doesn't fit (a narrow column header), the title is the plain phrase and the term goes first in the tooltip and into the Column Manager's list.
- Values are data, not labels, and stay verbatim in table cells: the LS type column shows `UIElement`, so it matches what `lsappinfo` prints and what a predicate compares against (`lsType == UIElement`). In the inspector, where there is room, a row's value is glossed too: `Type  No Dock icon (UIElement)`. See decision D8.

**Sections, in this order, everywhere:**

| # | Section | Holds |
|---|---|---|
| 1 | Identity | What the code is: name, pid, path, bundle id, kind, architecture, command line |
| 2 | Execution | How this instance runs: user, state, start, tty, process group, idle exit |
| 3 | Lineage | Who it belongs to: parent, responsible, launchd job and domain, LaunchServices type and state, extension point, container app, coalitions |
| 4 | CPU | |
| 5 | GPU | |
| 6 | Memory | |
| 7 | Disk | |
| 8 | Network | |
| 9 | IPC | Syscalls, Mach messages, Mach ports, open descriptors |
| 10 | Energy | Power, energy, wakeups, sleep assertions |
| 11 | Security | Signature, sandbox, hardening |

This list drives: the header menu and View ▸ Columns submenus, the Column Manager's grouping, the rows of the inspector's Info and Usage tabs, and (through `PredicateFields`, which reads `Column.all`) the predicate's field list.

**One name per quantity.** Today the same value has up to three names. Use the left column everywhere (column title, inspector row, tile, thread table):

| Use | Replaces |
|---|---|
| Memory | "Footprint" (Usage row), "Physical footprint" (memory map tile). Keep "physical footprint" in the tooltip as the definition. |
| P-core share | "On performance cores" (Usage row), "P cores" (Threads column) |
| Instr/cycle | "Instr. per cycle" (column), "Instructions per cycle" (Usage row), "IPC" (Threads column). "IPC" must mean inter-process communication only. |
| Runnable wait | "Waiting for CPU" (column), "Waiting for a CPU" (Usage row) |
| Disk I/O | "Disk read + written" (tile) |
| Power | "CPU energy" as the name of the watts figure (Usage row). "Energy" stays the name of the joules total. |
| Signer | "Signed" (Overview row) |
| Accounting group (resource coalition) | "Res. coalition" (column), "Same resource coalition" (Related) |
| Wakeups | "Wakeups (idle + interrupt)"; the parenthesis goes to the tooltip |
| Replies owed (send-once) | "Replies owed" alone (column title). The Usage row already has the bracketed form |

## 2. Columns

File: `Sources/ProcXRay/UI/Columns.swift`.

### 2.1 Re-section the catalogue

Change `Column.Section` to the 11 cases of Part 1 and reassign each column. Reorder the `catalogue` array to match, since menus and the Column Manager list columns in catalogue order.

| Section | Column ids, in order |
|---|---|
| Identity | `name`, `pid`, `kind`, `path`, `bundleID`, `commandLine`, `arch` |
| Execution | `user`, `state`, `started`, `startTime`, `tty`, `pgid`, `idleExit` |
| Lineage | `parent`, `responsible`, `label`, `domain`, `lsType` (new), `lsState` (new), `extPoint`, `containedIn`, `coalition`, `jetsam`, `leftBehind` (new), `context` |
| CPU | `cpu`, `cpuTime`, `threads`, `waiting`, `cswRate`, `priority`, `nice`, `pcore`, `ipc`, `cycles`, `cycleRate`, `instructions`, `instructionRate` |
| GPU | `gpu`, `gpuTime` |
| Memory | `mem`, `peakMem`, `resident`, `virtual`, `compressed`, `neural`, `jetsamBand`, `memLimit`, `memLimitUsed`, `faultRate`, `pageinRate` |
| Disk | `readRate`, `writeRate`, `diskRead`, `diskWritten`, `disk`, `logicalWrites` |
| Network | `netIn`, `netOut` |
| IPC | `syscallRate`, `machMsgRate`, `machPorts`, `machDeadNames`, `machRepliesOwed`, `machFullQueues`, `openFiles` |
| Energy | `power`, `energy`, `wakeupRate`, `preventingSleep` |
| Security | `signer`, `team`, `signingID`, `sandboxed`, `hardened` |

Ids do not change, so saved column sets, shown columns and widths survive. `ColumnPrefs.order` appends columns the saved order doesn't know, so the new columns start hidden at the end.

### 2.2 New columns

| id | Title | Value | Group rule | Why |
|---|---|---|---|---|
| `lsType` | LaunchServices type | `ProcInfo.lsType` (`Foreground`, `UIElement`, `BackgroundOnly`), empty when not registered | `.same` | The Smart tree's categories are derived from it, and it is visible nowhere as a raw field. Needed for step 8. |
| `lsState` | LaunchServices state | `ProcInfo.lsTags` joined with a space | blank | The LaunchServices Apps section's "State" column, for step 8. |
| `leftBehind` | Left behind | `ProcInfo.leftBehindText` (the exited app's name), empty otherwise | `.same` | Makes "left behind" a predicate field and a sortable column, for step 8. |

`PredicateFields` picks them up automatically from `Column.all`.

### 2.3 Titles

Apply the renames of Part 1 to column titles (`ipc` → "Instr/cycle", `waiting` → "Runnable wait") and the glossed terms. A column header is narrow, so the title is the plain phrase and the term leads the tooltip: `coalition` → "Accounting group", `jetsam` → "Memory-kill group", `jetsamBand` → "Memory-kill band", `machRepliesOwed` stays "Replies owed". The Column Manager, which has room, lists the full bracketed label. `PredicateFields.lookup` is keyed by both title and id, so old ids keep working in saved predicates; a predicate typed with an old title will stop resolving. That is acceptable while the feature is unreleased.

### 2.4 Tooltips

Each tooltip is currently one paragraph mixing definition, source, group-row rule and privilege needs. Split `Column.tooltip` into fields so each can be shown consistently (and so Part 6 can show the source on its own):

```swift
let help: String        // what the number means, one sentence
let source: String      // the API, tool or calculation: "proc_pid_rusage ri_phys_footprint"
var needs: String? = nil // "helper", "helper (admins only)", nil
```

The group-row sentence ("Group rows: the sum.") is generated from `rule`, not written per column. The header tooltip is composed as: help, then `Source: …`, then `Group rows: …`, then `Needs: …`, each on its own line. `machNote` and `rateNote` become shared `help` suffixes or `needs` values.

**Check:** `--dump` still prints `ok` for every grouping; View ▸ Columns shows 11 submenus in Part 1's order; a saved column set made before the change still applies.

## 3. Smart tree

File: `Sources/ProcXRay/SmartTree.swift`. The two-pass design (attach to an owner, then categorise the unit root) stays. Only the categorising rules and a few labels change.

### 3.1 What is wrong

- **Vendor splits some kinds and not others.** Background apps and services divide into Apple and third-party; Extensions does not. Extensions is the second-largest category (104 rows) and is 84 % Apple, so the third-party extensions a user would look for are buried.
- **System interface is misnamed.** `category(ofRoot:)` sends every Apple process with LS type `UIElement` *or* `BackgroundOnly` there. `BackgroundOnly` means no UI (`chronod`, `sharingd`, `universalaccessd`).
- **The biggest category has no structure.** System services holds 535 of 939 processes as one flat list, while Third-party services (16 processes) is split into Agents and Daemons.
- **Labels without their term.** "No Dock icon" and "Background only" stand for the LS types `UIElement` and `BackgroundOnly`, but nothing on screen says so, and "Background only" beside the category "Background apps" and the sidebar's "Background Items" reads as a third meaning of the same word.

### 3.2 New rules

`category(ofRoot:)`, in order (changes in bold):

1. `leftBehindGroup != nil` → Left behind
2. `lsType == "Foreground"` → Apps
3. `isExtension(p)` → **Apple: System services. Otherwise: Extensions.**
4. Job in launchd's system domain (label not `application.*`) → Apple: System services. Otherwise: Third-party services.
5. **`lsType == "UIElement"` → Apple: System interface. Otherwise: Background apps.**
6. **`lsType == "BackgroundOnly"` → Apple: System services. Otherwise: Background apps.**
7. Has a launchd label, not Apple, not `application.*` → Third-party services
8. Apple → System services. Otherwise → Other.

`subgroup(ofRoot:in:)`:

| Category | Sub-groups |
|---|---|
| Background apps | **No Dock icon (UIElement)**, **No UI (BackgroundOnly)** |
| Extensions | Extension point title (unchanged) |
| Third-party services | Daemons, Agents (unchanged rule) |
| System services | **Extensions** (`isExtension`), **Daemons**, **Agents** (same rule as Third-party services; see decision D2) |

The existing rule in `build` that only makes a sub-group for two or more units still applies.

`kinds(_:)` appends the extension point only when the category is `.extensions`. Change the test to `isExtension(rp)` so an Apple extension's Kind reads "System service · Extension · Widgets" instead of losing its extension point.

Category order stays, except Left behind moves to the top: it is a warning, it starts expanded, and it is usually empty.

Resulting top level: Left behind · Apps (anything with a Dock icon, any vendor) · Background apps · Extensions · Third-party services (these three: third-party only) · System interface · System services (Apple only) · Other.

### 3.3 App rows show the app's identity

A unit row (`ProcNode.Kind.unit`) is drawn from the root process's icon and name only (`ProcessOutline.showName`). Every identity column on it is blank because those columns' rule is `.blank`, yet the tooltips of `pid`, `path`, `bundleID`, `commandLine`, `parent` and `signingID` say "App rows: the app's". In the running build the Xcode row has no PID and no Responsible.

Add `var unitShowsRoot = false` to `Column` and set it on `pid`, `path`, `bundleID`, `commandLine`, `parent`, `responsible`, `label`, `signingID`, `lsType`, `started`, `startTime`. In `Column.groupValue`, when `n.kind == .unit` and the flag is set, return the root process's value (`store.procs[n.rootPid]`) with `.secondary` tint, before the `rule` switch. Remove "App rows: …" from the tooltips; the generated group-row line says it.

Also give unit rows the process context menu and the info bubble, acting on the root process (`menuNeedsUpdate` and `bubble(for:)` in `ProcessOutline.swift` return early for any row without `proc`).

### 3.4 Sorting inside the tree

A column sort always switches the list to flat (`ProcessesView.shownGrouping`), so there is no way to rank apps by their summed memory, which is the question the tree exists to answer. `Store.sorted` already orders siblings by group values, so only the view needs to change.

Add `@AppStorage("processes.sortKeepsGroups")` (default off, see decision D3) and a View menu toggle "Keep Groups When Sorting". When on, `shownGrouping` returns `grouping` even with a sort. `fixedOrder` already keeps categories in their order and the app's own process first in its unit. Update the grouping menu's help text.

**Check:** `--dump` prints `ok` for Smart and the new shape. Expected: Extensions drops from 106 processes to about 19; System interface shrinks; System services gains about 89 extensions plus the Apple `BackgroundOnly` agents and shows three sub-groups. Paste the before and after category lines in the commit message. With `sortKeepsGroups` on and sort by Memory descending, the first row under Apps is the app whose unit row has the largest Memory.

## 4. Group rows

File: `Sources/ProcXRay/UI/Columns.swift` (`Column.GroupRule`, `Column.groupValue`). Sums, the weighted P-core share and "73 of 182" for Sandboxed are good and stay. With every column shown, `--dump` printed these for the category rows:

| Column | Shown on 2026-11-16 | Problem |
|---|---|---|
| `coalition`, `jetsam`, `pgid` | "471 coalitions", "534 groups" | A count of distinct ids says nothing |
| `coalition` on the Claude app row | "1 coalition" | One value, but the row shows a count because one member lacks it |
| `domain`, `extPoint`, `containedIn` | "1 domain", "1 extension point", "1 app" | Same: a single value hidden behind a count |
| `user`, `kind` | "47 users", "5 kinds" | Fine for 47, unhelpful for 2 |
| `priority` | "4 prioritys" | Wrong plural, and a count of priorities is not useful |
| `state` | "1 stopped, zombie or hung" | Doesn't say which |
| `started` | "13d 11h" on all six categories | The oldest member of a category is always something started at boot |
| `ipc` | blank | Both sums it needs are already computed |
| `cpuTime` | "47450.88 s" | Unreadable above a few minutes |
| any byte column | "Zero KB" | `ByteCountFormatter`'s wording |

### New rules

| Rule | Behaviour | Columns |
|---|---|---|
| `.same(noun:)`, revised | All members have one value: that value. One distinct value but some members have none: the value, `.secondary` tint. Two or three distinct values: comma-separated, most common first, `.secondary`. More: the most common value and "+N" ("yossi +46"). | `user`, `signer`, `team`, `kind`, `arch`, `domain`, `lsType`, `extPoint`, `containedIn`, `tty`, `idleExit`, `leftBehind` |
| `.uniform` (new) | The value when every member that has one agrees (dimmed if some have none); otherwise blank. | `coalition`, `jetsam`, `pgid` |
| `.range` (new) | "min–max", or the single value. | `priority`, `nice`, `jetsamBand` |
| `started`, `startTime` | Category rows (`n.kind == .category`): the newest member. Every other group row: the oldest, as now. App rows get the root's start through `unitShowsRoot`. | |
| `state` | Counts by state, largest first: "2 stopped, 1 zombie". | |
| `ipc` | Σ instructions ÷ Σ cycles over members that have both. | |

`.same`'s plural fallback (`noun + "s"`) disappears with the revised rule, which fixes "prioritys".

### Formatting (file: `Model.swift`, `enum Fmt`)

- `Fmt.bytes`: return "0" for zero instead of "Zero KB".
- `Fmt.secs`: below 60 s keep "12.34 s"; from 60 s use "m:ss"; from an hour "h:mm:ss"; from a day "Nd h:mm:ss". The column sorts by `amount`, so the string change does not affect sorting.

**Check:** `--dump`'s `values` lines contain no "Zero KB", no "prioritys", no "N coalitions"/"N groups", and `values Claude:` (or whichever app is first) includes `pid=`, `coalition=<number>` and `path=`.

## 5. Inspector

Files: `UI/InspectorView.swift`, `UI/InspectorTabs.swift`, `UI/GroupInspector.swift`, `UI/HardeningCard.swift`, `UI/TCCCard.swift`, `UI/SandboxCard.swift`.

### 5.1 Flat tabs, named by content

Today: Overview · Origin · Trust · Resources [Usage | Threads | Memory map] · Connections · Activity [Logs | Sample | Syscalls]. Two tabs hide three unrelated tools each behind a second selector of a different style, and the names say what question is answered rather than what is inside.

New `InspectorTab` cases, in this order (static facts, then live counters, then on-demand captures):

| New tab | Raw value | Was |
|---|---|---|
| Info | `Info` | Overview |
| Launch | `Launch` | Origin |
| Security | `Security` | Trust |
| Usage | `Usage` | Resources ▸ Usage |
| Threads | `Threads` | Resources ▸ Threads |
| Memory | `Memory` | Resources ▸ Memory map |
| Files & Ports | `Files & Ports` | Connections |
| Logs | `Logs` | Activity ▸ Logs |
| Sample | `Sample` | Activity ▸ Sample |
| Syscalls | `Syscalls` | Activity ▸ Syscalls |

- Delete `SubPanes` and the `inspector.resourcesView` / `inspector.activityPane` defaults.
- **Migration:** `inspectorTab` is stored in `@AppStorage` and `@SceneStorage` by raw value. Give `InspectorTab` a failable init that maps the six old raw values (Overview → Info, Origin → Launch, Trust → Security, Resources → Usage, Connections → Files & Ports, Activity → Logs) and use it where `InspectorTab(rawValue:)` is called in `InspectorView`.
- Add ⌘1 … ⌘0 for the ten tabs in the View menu (enabled when an inspector is focused).
- `InspectorTabStrip` already scrolls horizontally; no layout work.

### 5.2 Header

`InspectorHeader` is three fixed rows: name/pid/user/age; kind/owner/sandbox/signer; badges and the Signal and Reveal buttons. Changes:

- Row 2 gains the four live figures as text: `CPU 3.7 % · 759 MB · 0 B/s · <0.01 W`. They replace the four `SparkTile`s on the Info tab (5.3).
- The Signal menu and Reveal button leave the header for the Process menu (Part 7) and stay in the row context menu. Row 3 then holds badges only and collapses to zero height when there are none. Decision D4 covers keeping the buttons.

### 5.3 Info (was Overview)

Today: four spark tiles, a 10–13 row fact grid in no particular order, a Related card that repeats Origin, and the command line collapsed at the bottom.

New content, as `Card`s titled by Part 1's sections, rows in catalogue order:

| Card | Rows |
|---|---|
| Identity | Path, Bundle ID (with version), Kind, Architecture, Extension point (when any) |
| Command | `argv`, shown open, one argument per line as now; Environment collapsed with its count |
| Execution | User (uid), Started, State, Idle exit, Working dir, TTY, Process group, Priority, Nice |

Removed from this tab:

- The four `SparkTile`s: every figure is in the header (5.2) and on Usage with its sparkline.
- The "Sandbox" and "Signed" rows: the header's second line shows both and Security has the detail.
- The Related card and its "N children" / "responsible for N" buttons: Launch shows all of it. `OverviewTab`'s `show` closure goes away.
- "launchd label": moves to Launch.

Rule for completeness (principle 6): every column in the Identity and Execution sections has a row here. The simplest way to guarantee it is to generate these two cards from `Column.all.filter { $0.section == … }` and add the few inspector-only rows (Working dir, Environment) by hand. Priority and Nice are listed under Execution here because they describe how this instance is scheduled; as columns they stay in the CPU section next to the figures they explain. `nice` is an optional read (see 5.6).

### 5.4 Launch (was Origin)

Today six cards: Installed by, Launched by, Attribution, Parent chain, Responsible, Related processes. "Who started it" is spread over three of them and the parent is named in three places; the least often present record (Background Items) comes first and the parent chain fourth.

New cards, in this order:

| Card | Rows | From |
|---|---|---|
| Lineage | Parent chain as one line, root first (`kernel_task › launchd › firefox`); Responsible; Requested by (the launch-log hops); Parent app (LS `parentASN`); Loaded on behalf of (launchd's attribution); Inherited environment (Claude session, terminal, working directory) | Parent chain, Responsible, and the "who" parts of Attribution and Launched by |
| Mechanism | One row per `LaunchMechanism` line (how it was started), and "Started because" (launchd's `immediate reason`) | Attribution, Launched by |
| launchd job | Label, Domain, Type, Properties, Runs / last exit, Plist path, Registered by (SMAppService), pid-domain host; then the collapsed raw `launchctl print` and `launchctl procinfo` | Launched by |
| LaunchServices | Name, Type (glossed: "No Dock icon (UIElement)"), LaunchServices instance (ASN), State tags; then the collapsed raw record | Launched by |
| Background item | Item, Developer, State, Type, Parent item | Installed by |
| Extension | Extension point, Containing app | Launched by |
| Related | Children, Responsible for, In its launchd domain (pid domain), Same accounting group (resource coalition), Same memory-kill group (jetsam coalition), Same bundle, Same binary (cdhash), Same team | Related processes, plus "Same team" from Trust |

A card whose record does not exist is not drawn as a sentence. Instead the tab ends with one row: `Not registered with: Background Items, LaunchServices`. This replaces "No Background Items record for this executable or label.", "Not the main process of a launchd job in your domains, not a LaunchServices app." and "Parent is launchd: launchd started it (a launchd job or an app launch), or the process that started it has exited."

### 5.5 Security (was Trust)

The grouping is sound. Changes:

- Rename the "Runtime hardening" card to "Hardened process (kernel)". It sits under a headline that can read "…, hardened runtime" and then says "0 of 5 … not a hardened process": two different mechanisms with near-identical names.
- In that card, move each row's sentence ("security-critical settings for the system memory allocator") to the row's tooltip, and give the status glyph a text value (`on` / `off`) so it is not a bare circle.
- Rename the "Privacy & Security" card to "Privacy permissions (TCC)".
- Signature row "CDHash" becomes "Code hash (cdhash)".
- "Same team" moves to Launch ▸ Related.
- Signature rows: rename "Valid now" to "Valid", "Requirement" to "Designated requirement".

### 5.6 Usage

Cards follow Part 1's sections 4–10: CPU, GPU (when read), Memory, Disk, Network, IPC, Energy.

| Today | Change |
|---|---|
| "CPU by QoS class" card | Becomes indented rows at the end of the CPU card |
| "System calls and IPC" card with Mach port counts appended | Card is named IPC. The four Mach port rows move to Files & Ports, which is where the ports are listed |
| "Energy and wakeups" | Named Energy |
| "On behalf of other processes" card | "CPU for others" / "CPU by others" become rows of the CPU card; the two energy rows become rows of Energy. `VoucherFlowsView` goes under Energy |
| "Other" card (Open files, Power assertions) | Deleted. Power assertions → Energy. Open files → the header line of Files & Ports and a row in IPC |
| "Task metrics read as root through the privileged helper." footer | Deleted; Part 6's source marker says it per row |

There is no GPU card today although `gpu` and `gpuTime` are columns: add one (% GPU, GPU time). Likewise add rows for `compressed` (Memory) and `openFiles` (IPC). These values are optional reads (`Column.reads`, `ExtraReads`) that the snapshot makes only while something asks for them; the tab must ask while it is on screen, the way it already does for jetsam and network (`store.jetsamViewers`, `store.networkViewers` in `Model.swift`).

`GroupInspector.swift` calls `UsageTab.section` with the same titles and row names: change it in the same commit so the group page and the process page stay aligned.

**Check for Part 5:** launch with `PROCXRAY_INSPECT=<pid>` after writing each of the six old raw values to the `inspectorTab` default and confirm the mapped tab opens. Grep the UI sources for the removed sentences; none remain.

## 6. Sources

Principle 5 says every item shows its source. Today sources appear five ways: column tooltips, the `EXACT Source: …` line in Attribution, grey paragraphs under cards (Hardening, Sandbox, compiled profile), command titles on tool tabs (`lsof -n -P -p 24741   [as root via helper]`), and not at all (every row of Overview, Signature, Related and Usage).

One mechanism:

- A row in a fact grid becomes a struct, not a tuple: `FactRow(label:, value:, source:, via:)`, replacing `(String, KVValue)` in `FactGrid`/`KV`, and the three-string tuple in `UsageTab.section`.
- `source` is a short token naming the API, tool or calculation: `proc_pidpath`, `csops CS_OPS_CDHASH`, `ri_phys_footprint`, `sandbox_check`, `launchctl print`, `lsappinfo`, `sfltool dumpbtm`. A derived value says so: `derived: Smart tree` for Kind, `derived: Σ members` for sums. Take the tokens from `docs/process-info-sources.md`; where that doc lacks one, read the code that produces the value and add it to the doc.
- `via` is an enum: `.direct`, `.helper` (read as root by the helper). It renders as a small marker after the token and replaces every "as root via helper" phrase.
- Rendering: the token trails the value in `.caption` monospaced `.tertiary` text. A View menu toggle "Show Sources" (`@AppStorage("showSources")`, default on, ⌥⌘S) hides them all.
- Columns: the `source` field from 2.4 is the same token; the Column Manager shows it as a column of its own.
- Attribution keeps its confidence badge (`EXACT` / `INFERRED`); only the "Source: …" sentence moves into the row's `source`.
- The explanatory paragraphs under Hardening, Sandbox and the compiled profile shrink to the caveat only (what the figure does *not* cover); the "From the kernel (…)" part becomes row sources.

**Check:** with Show Sources on, every row of Info, Launch, Security ▸ Signature and Usage has a token. A debug assertion in `FactGrid` that `source` is non-empty catches omissions during development.

## 7. Wording and commands

### 7.1 Three null states

| Meaning | Show | Replaces |
|---|---|---|
| Does not apply | `—` | "", "none" used for not-applicable |
| Could not be read | `?` with the reason as tooltip (`needs helper`, `SIP`, `exited`, `other user`) | "not readable", "unknown", "sandbox unknown", "Not readable (another user's process; the privileged helper can read it)." |
| A real value | `0`, `none`, `no`, `off` | — |

Apply in `CellValue` (`.unknown` → `?`, `.empty` stays blank in the table, where a blank cell reads as "not applicable") and in every inspector row.

### 7.2 Sentences to rows or to a word

| Today | Becomes |
|---|---|
| "The process has exited, so this can't be collected any more." | "Exited." |
| "Press Run to collect this data." | (nothing; the Run button is right there) |
| "Run collects the last 10 minutes; Live follows new events as they're logged." | Tooltips on Run and Live |
| "Started directly by [chip] (its parent process)" | Lineage row "Parent" |
| "Registered with LaunchServices as the app "X" (UIElement)." | LaunchServices rows Name, Type |
| "— (it is the top of its group)" | `self` |
| "Enhanced security: no (not a hardened process)" | `Enhanced security  off` |
| "Sandboxed, but not by the App Sandbox entitlement: a system profile, one inherited from its parent, or sandbox-exec." | `Sandbox  on · profile: system / inherited / sandbox-exec`, detail in the tooltip |
| "Background Items aren't loaded." + Load button | Row `Background item  not loaded` with the button |

Settings captions are out of scope; they are the right place for full sentences.

### 7.3 Tooltips must not hold data

Move these into the UI proper (a column, a row or a detail line):

- Threads: user/system split (tooltip on CPU time) and current/base/max priority (tooltip on Priority) → columns.
- TCC rows: last changed, database, client key → a detail line under the row.
- Mach-O libraries: current and compatibility version → columns.
- Files & Ports: the fd number (tooltip on the Listening chips; the table has no FD column) → a column.
- Memory map chart: resident/dirty/swapped/virtual per region are already in the table; no change.

### 7.4 Marks that need a word

- Name-column badges `SBX`, `LEFT`: spell them `sandboxed`, `left behind`, or drop `SBX` in favour of the Sandboxed column (decision D5).
- `†` before an exited responsible: write `exited` after the name instead.
- LS state tags such as `!signalled`: keep verbatim (they are values, and lsappinfo's own), but the column tooltip says so.
- Every other bare system term in a label gets its plain phrase, per "Glossed terms" in Part 1.

### 7.5 One name per command

The same action is "Inspect" (toolbar), "Inspect Process" (View menu) and "Properties" (context menu). Use "Inspect" everywhere.

### 7.6 Process menu

There is no menu-bar menu for the selected process; its commands are split between View, the pane header and the context menu. Add a **Process** menu (a `Commands` struct next to `InspectCommand` in `App.swift`), acting on the focused window's selected process through `FocusedValues`:

Inspect ⌘I · Show Inspector Pane ⌥⌘I · Reveal in Finder ⇧⌘R · Inspect Binary · Copy PID · Copy Path · Select Parent · Select Responsible · — · Sample · Trace Syscalls · — · Terminate… · Kill… · Suspend · Resume

Move "Inspect Process", "Show Inspector Pane" and "Pick Process by Window…" out of View into it. View keeps Columns, grouping, Refresh, Pause, Show Sources, Keep Groups When Sorting.

## 8. Sidebar and sections

Files: `App.swift` (`Section`, `ContentView`), `UI/OtherViews.swift`, `Ambient/SettingsView.swift`. Depends on the predicate feature being committed and on 2.2.

### 8.1 Which sections are really filters

Test: is every row a running process? If yes, the section is a filter and a column set of Processes.

| Section | Verdict | Reason and what moves |
|---|---|---|
| Left Behind | **Fold** | The Smart tree already has a Left behind category, the name badge and the Responsible column. `GhostsView` shows the same processes with four columns. Its per-row Terminate is in the context menu. The exited app's LS state tags (`g.lsApp.stateTags`) go into the ghost group row's Context cell. The subtitle "macOS keeps an app 'running in background' while these live" becomes the saved filter's tooltip. |
| LaunchServices Apps | **Fold** | Nearly all of its 153 rows are running processes. Its columns exist or are added in 2.2 (`lsType`, `lsState`, `coalition`, `bundleID`, `arch`); the raw record is in Launch ▸ LaunchServices. Registered-but-exited entries are exactly the Left behind ghost rows. Add ASN to the Launch card (5.4). |
| launchd Jobs | Keep | Most of its 588 jobs have no process, so it cannot be a process filter. |
| Background Items | Keep | Records, not processes. |
| Triage | Keep | The only system-wide view (meters, alerts, launches, exits). |

### 8.2 Saved filters

The predicate work already has saved filters: `SavedPredicate` (a name and a predicate source) in `UI/PredicateBar.swift`, stored as JSON under `processes.savedPredicates` and shown as bookmark chips after the presets. Build on it; don't add a second store. Extend `SavedPredicate` with an optional grouping and an optional column list (both `Codable` optionals, so filters saved before the change still decode), and show the saved filters in the sidebar as well as in the chip bar.

Built-in, not deletable:

| Name | Predicate | Grouping | Columns |
|---|---|---|---|
| All Processes | (none) | Smart | current |
| Left Behind | `leftBehind` | Smart | current |
| LaunchServices Apps | `lsType` | Flat | name, pid, lsType, lsState, coalition, bundleID, arch |

The seven `FilterChip`s are already presets that add or remove a predicate clause (`FilterChip.source`); they stay in the chip bar as they are.

The predicate bar can already save the predicate in force under a name. User filters appear in the sidebar under the built-ins.

### 8.3 Sidebar

A source list with two headed groups:

```
Processes
  All Processes
  Left Behind            3
  LaunchServices Apps
  <user filters>
  Triage                 1
Launch registries
  launchd Jobs
  Background Items
```

- `Section` loses `.ghosts` and `.apps`. **Migration:** the `section` default stores the raw value; map "Left Behind" and "LaunchServices Apps" to Processes with that saved filter selected.
- The Left Behind count badge moves to the saved filter's row.
- Delete `GhostsView` and `AppsView` once the filters work.
- Rename the launchd section's subtitle only if 8.5 is done.

### 8.4 Helper and status out of the sidebar

The sidebar's bottom inset permanently shows the helper status and an "Uninstall Helper" button, a destructive and rarely used action.

- New Settings tab "Helper" (after General): status, pid, Install / Uninstall / Open Login Items, the error text, and one paragraph on what the helper does (from the README).
- The bottom inset becomes one status line: `939 processes · 75 ms · helper root · SIP off`. Each part's tooltip gives the detail; clicking the helper part opens Settings ▸ Helper. When the helper is not installed the line reads `helper: not installed` in orange, and that is the only prompt.

### 8.5 Cross-links between the registries (optional, last)

- launchd Jobs: selecting a running job offers "Show in Processes"; add columns Domain and Plist path; list the `system` and `user/<uid>` domains too. Today the list is `launchctl list`, which covers only the caller's gui domain (the subtitle says `gui/501`), while `Launchd.printJob` in `Sys/SysTools.swift` already looks a label up in all three.
- Background Items: add a "Job" column that names the matching launchd label and its pid when running, matched as `OriginTab.btmItem` matches (executable path, then label).
- Triage: "Top CPU" and "Just launched" get a header link that opens Processes sorted by CPU, or with the "Started < 5 min" chip.

## 9. Order of work

Each step is one commit and leaves the app working. Later steps depend on earlier ones only where noted.

| # | Step | Part | Size | Depends on |
|---|---|---|---|---|
| 1 | `Fmt.bytes` zero, `Fmt.secs` units | 4 | Small | — |
| 2 | Re-section and reorder the column catalogue; title renames | 1, 2.1, 2.3 | Small | — |
| 3 | New columns `lsType`, `lsState`, `leftBehind` | 2.2 | Small | 2 |
| 4 | Smart tree category and sub-group rules; Kind suffix; Left behind first | 3.2 | Small | — |
| 5 | Group-row rules (`.same` revised, `.uniform`, `.range`, state, started, ipc) | 4 | Medium | 2 |
| 6 | App rows show the root's identity; context menu and bubble on app rows | 3.3 | Small | 5 |
| 7 | Keep Groups When Sorting | 3.4 | Small | — |
| 8 | Flatten inspector tabs with migration; ⌘1–⌘0 | 5.1 | Small | — |
| 9 | Info tab: cards by section, argv open, tiles and Related removed; header figures | 5.2, 5.3 | Medium | 2, 8 |
| 10 | Launch tab: merge into Lineage / Mechanism / registrations / Related | 5.4 | Medium | 8 |
| 11 | Security renames; Usage card moves; GroupInspector kept in step | 5.5, 5.6 | Medium | 8 |
| 12 | `FactRow` with `source` and `via`; column `help`/`source`/`needs`; Show Sources | 2.4, 6 | Large | 9–11 (rows have settled) |
| 13 | Null states; sentences to rows; tooltip-held data into the UI; badges | 7.1–7.4 | Medium | 12 |
| 14 | Process menu; "Inspect" everywhere | 7.5, 7.6 | Small | — |
| 15 | Saved filters; fold Left Behind and LaunchServices Apps; sidebar groups | 8.1–8.3 | Medium | 3, predicate feature committed |
| 16 | Settings ▸ Helper; sidebar status line | 8.4 | Small | — |
| 17 | Registry cross-links | 8.5 | Medium | 15 |
| 18 | Docs: README (tabs, sidebar, screenshots), status line of `tree-and-inspector-proposal.md`, new tokens in `process-info-sources.md` | — | Small | all |

Steps 1–7 touch the process list only; 8–13 the inspector; 14–17 the window chrome. The three blocks are independent of each other apart from the dependencies listed, so they can be reordered as blocks.

## 10. Decisions, with defaults

| # | Decision | Default | Alternative |
|---|---|---|---|
| D1 | Ten flat inspector tabs | Yes (Process Hacker has twelve; the strip scrolls) | Keep six tabs and only rename them and the sub-panes |
| D2 | Rule for Daemons vs Agents in both service categories | Daemons: launchd system domain, or uid 0. Agents: the rest. This is the rule Third-party services uses today; role accounts (`_rmd`, `_networkd`) with no readable label land in Agents | Treat every uid below 500 as a daemon. Not a field the system reports, so it conflicts with the tree's "nothing inferred" rule |
| D3 | Keep Groups When Sorting default | Off, to keep the Process Hacker behaviour the owner chose | On when the grouping is Smart |
| D4 | Signal and Reveal buttons in the inspector header | Remove; they are in the Process menu and the context menu | Keep them in a standalone inspector window, where there is no selected row to right-click |
| D5 | `SBX` badge on the Name column | Remove; the Sandboxed column and the header say it, and about two thirds of all processes carry it (624 of 946 in the `--tree-stats` run) | Spell out as `sandboxed` |
| D6 | Sidebar name of the Left Behind filter | Keep "Left Behind" | "Orphans": shorter, but in Unix it means reparented to launchd, which is not the test used here |
| D7 | Top-level categories | Keep seven and fix the rules (Part 3) | Merge System interface, System services and Apple extensions under one "macOS" category with sub-groups |
| D8 | Glossing values, not only labels | Table cells show the system's value verbatim (`UIElement`); labels everywhere and values in inspector rows are glossed | Gloss cell values too. Wider columns, and the cell no longer reads the same as the predicate that matches it |

## 11. Out of scope

- Visual restyling: fonts, spacing, colours, card chrome.
- The menu bar item, its popover and Settings captions.
- The Mach-O inspector window, apart from 7.3's library versions.
- New data sources. This plan only regroups, renames and exposes what is already read.
