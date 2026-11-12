# Implementation plan: Connections tab (IPC peers of a process)

This is a brief for an agent implementing the first, deliberately small, version of the IPC map. Background and all measurements are in `docs/ipc-map-proposal.md`; read it first, but build only what is listed here. The proposal describes more than this plan. Where they differ, this plan wins.

## Goal

Select a process, open a new **Connections** inspector tab, and see which other processes it is connected to, over what, grouped so the list is readable. Peers are clickable.

Two data sources:

1. **Descriptors** (pipes, unix sockets, loopback TCP), read in-process with `proc_pidfdinfo`. No privileges. 15 ms for every process.
2. **Mach ports**, from `/usr/bin/lsmp -a -j` run by the root helper. About 3 s per snapshot. This is 99 % of the links (9,732 against 110), so the tab is not finished without it.

## Explicitly out of scope

Do not build these, even though the proposal describes them. They were cut for cost:

- The drawn three-column diagram with edges. Use grouped lists.
- The IPC Map sidebar section, the category matrix, path finding, lenses.
- Diffing between snapshots, timeline events, Record.
- Naming Mach edges by service name (plist `MachServices` table, `launchctl print pid/<n>`). Show the peer's existing `launchdLabel` instead.
- Client → server direction for Mach links. Show the two counts.
- Shared memory, IORegistry walk, tree columns, peer highlight in the tree, filter chips.
- Replacing `lsof` in the Files & Sockets tab. Leave that tab alone.
- Refreshing on the timer tick. Everything here loads when the tab appears and on a Refresh button.

## Before you start

- The working tree has uncommitted changes from other work (`InspectorNavigation.swift` is new; `InspectorView.swift`, `ProcessesView.swift`, `ProcessOutline.swift`, `App.swift` are modified). Build on top of them. Do not revert, reformat or commit them.
- There is no test target. The project verifies with CLI modes of the app binary: `--dump` (`SelfTest` in `UI/OtherViews.swift`), `--bench`, and `--helper-call` (`Bench.swift`). Follow that pattern.
- Build: `./build-app.sh` makes `build/ProcXRay Dev.app` with its own helper (`local.procxray.dev.helper`). It needs full Xcode and a signing identity; both are set up on this machine.
- You cannot run `sudo`. The dev helper is installed and runs as root, so test privileged code through `--helper-call`. After a rebuild the helper is the new binary; if `probe()` reports a protocol mismatch, wait about 10 s for the old helper to exit when idle and retry. If it reports "not installed" or "needs approval", stop and tell the user: only they can approve it.
- Code style: match the files you touch. Comments say why, not what. 4-space indent, long lines are normal here.
- Markdown you write: no hard-wrapped lines.

## Reference material in the repo

`tools/ipc-probe/` holds the throwaway scripts the proposal's numbers came from. Use them as the specification for the pairing logic, and port them; do not ship them.

| File | What it is |
|---|---|
| `fdprobe.c` | The descriptor pass: which `proc_pidfdinfo` flavors and struct fields to read. |
| `pair-fds.py` | Pairing of pipes, unix sockets and TCP from that output. |
| `pair-lsmp.py` | Pairing of Mach send and receive rights from `lsmp` JSON. |
| `lsmp-sample.json` | Real `lsmp -a -j` output cut down to four processes (Finder 1409, cfprefsd 675, distnoted 991, Dock 1407), 56 KB. |

Expected result of pairing `lsmp-sample.json` (sender → receiver: channels): Finder → cfprefsd 1, Finder → distnoted 2, cfprefsd → Dock 1, cfprefsd → Finder 1, distnoted → Dock 1, distnoted → Finder 1. Nothing else.

## Step 1: descriptor pass and pairing

New file `Sources/ProcXRay/Sys/IPC.swift`.

**Types** (all `Codable, Sendable`):

```swift
enum ChannelKind: String { case pipe, unix, tcp, mach }
struct IPCLink {            // everything between two processes, one kind
    var a: pid_t, b: pid_t  // a < b
    var kind: ChannelKind
    var aToB: Int           // pipe: a writes; unix/tcp: a connected to b's bound address; mach: send rights a holds to b's ports
    var bToA: Int
    var undirected: Int     // channels where the direction is not known
    var names: [String]     // socket paths, "tcp :port"; at most 5, deduplicated
}
struct IPCExternal {        // an endpoint that is not a visible process
    var pid: pid_t
    var kind: ChannelKind
    var name: String        // unix path, or "host:port" for a remote TCP peer
    var count: Int
    var listening: Bool     // this process is the one bound and accepting
}
struct IPCSnapshot { var links: [IPCLink]; var external: [IPCExternal]; var readablePids: Int; var totalPids: Int }
```

**Reading.** `IPC.readDescriptors() -> [FDRecord]` over `Native.allProcesses()`: `proc_pidinfo(PROC_PIDLISTFDS)`, then per descriptor `proc_pidfdinfo` with `PROC_PIDFDPIPEINFO` or `PROC_PIDFDSOCKETINFO`. Skip every other descriptor type without a call (vnodes are 5,184 of 7,668 descriptors and are not needed). A process whose list can't be read is just not readable; count it.

**Pairing**, as pure functions `IPC.pair([FDRecord]) -> IPCSnapshot` so they can be checked from fixed input:

- Pipe: `pipe_handle` and `pipe_peerhandle`. Both ends in one process: ignore. Several processes can hold the same end (inherited); link every holder of one end to every holder of the other.
- Unix socket: this end's `soi_pcb`, peer's `unsi_conn_pcb`. Resolved and in another process: a link, named by whichever of `unsi_addr` / `unsi_caddr` has a path. Not resolved but a path is present: an `IPCExternal` with that path (measured: `/var/run/syslog` 82, `/var/run/mDNSResponder` 51). Bound and unconnected with a path: an `IPCExternal` with `listening: true`.
- TCP: match (local port, remote port) against (remote, local) when both addresses are loopback. Both ends in one process: ignore (measured: 104 of 114 loopback connections are inside one VPN process). Connected to a non-loopback address: `IPCExternal` named `addr:port`. Remote port 0: `listening: true`, named `addr:port`.
- Direction is best effort. If it takes more than the obvious check (which end has a bound path, which port has a listener), count the channel as `undirected` and move on.

**Verify.** Add `--ipc` to the argument handling in `App.swift`, next to `--dump`. It prints: pids total and readable, the pass time in ms, descriptor counts by kind, pairs resolved and unresolved per kind, link count, number of processes with at least one link, and the ten processes with most peers. Then compile `tools/ipc-probe/fdprobe.c`, run it with `pair-fds.py`, and compare. Counts drift as processes come and go; resolved and unresolved counts per kind should agree within a few percent. On 2026-11-12 the reference gave 110 links between 81 processes. Also call `IPC.pair` on a small hand-built `[FDRecord]` (one cross-process pipe, one same-process pipe, one resolved unix pair, one unresolved unix with a path, one inherited pipe held by three processes) from `--ipc` and print `ok` or `MISMATCH` per case, as `SelfTest` does for groupings.

## Step 2: Mach links through the helper

**Helper side** (`Helper/HelperProtocol.swift`, `Helper/HelperDaemon.swift`):

- Add `func machLinks(reply: @escaping (Data?) -> Void)` to `HelperProtocol` and bump `HelperConfig.protocolVersion` to 2.
- Admin callers only (`callerIsAdmin`); otherwise reply `nil`. The snapshot covers every user's processes, which is the same rule `runTool` applies.
- `lsmp -j` writes to a path and the output is 39 MB, far over `HelperTool.maxOutput`. So do not go through `runTool`. Create a private directory with `mkdtemp` (the helper's umask is already `077`), run `Shell.exec("/usr/bin/lsmp", ["-a", "-j", "<dir>/ports.json"], timeout: 20)` honouring the connection's `cancel` as `runTool` does, read the file, delete the directory in a `defer`, parse, and reply with compact JSON. Try `-j /dev/stdout` first only if you want; if it does not behave, use the file.
- Parse with `JSONSerialization` into the reduced form below. Do not define `Codable` types for the full `lsmp` schema.

**Pairing** (`IPC.pairMach(lsmpJSON: Data) -> MachSnapshot`, pure, in `Sys/IPC.swift` so `--ipc` can run it on the sample):

- Walk `processes[].ports[]`, and for entries of type `port set`, their `members[]` too.
- An entry whose `rights` contains `recv`: record `ipc-object` → pid.
- An entry whose `rights` contains `send` or `send once`: a send right from that pid to `ipc-object`.
- Join on `ipc-object`. Drop rights whose receiver is the same pid, and rights with no receiver (those are kernel objects).
- Output:

```swift
struct MachSnapshot: Codable, Sendable {
    var links: [IPCLink]                 // kind .mach; aToB / bToA are the send-right counts each way
    var portCount: [pid_t: Int]          // entries per process
    var queued: [pid_t: Int]             // sum of msg_count over the process's receive rights; omit zeros
    var processCount: Int
    var seconds: Double                  // lsmp run plus parse
}
```

- Reference numbers for a whole machine: 692 processes, 169,725 entries, 9,732 links, 2.97 s for `lsmp` alone.

**Client side** (`Helper/HelperClient.swift`): `func machLinks(timeout: Double = 30) -> MachSnapshot?`, on a connection of its own like `run(_:pid:timeout:)` so cancelling stops `lsmp`.

**Verify.**

- `--ipc --lsmp-file tools/ipc-probe/lsmp-sample.json` runs `pairMach` on the file and prints the links. It must print exactly the six links listed above.
- Add `machlinks` to `Bench.helperCall`. Run `"build/ProcXRay Dev.app/Contents/MacOS/ProcXRay" --helper-call machlinks` and report: processes, links, reply size in bytes, total seconds, and how much of that was parsing. If parsing takes more than about 2 s, say so in your report and leave it; do not write a custom parser.

## Step 3: the Connections tab

**Store** (`Model.swift`): one cache for the app, not per window.

- `var ipc: IPCSnapshot?`, `var mach: MachSnapshot?`, each with the `Date` it was taken, and `func loadIPC(mach: Bool)` that runs off the main actor and assigns on it. Loading the descriptor snapshot is automatic when the tab appears and it is older than 5 s. Loading Mach is automatic only when there is no Mach snapshot yet and the helper is running; after that only the Refresh button reloads it. Ignore a second request while one is in flight.

**Tab** (`UI/InspectorView.swift`): add `case connections = "Connections"` to `InspectorTab`, after `files`. New view in a new file `UI/ConnectionsView.swift`.

Layout, top to bottom:

1. **Toolbar row**: kind filter pills (Mach, Socket, Pipe, TCP) with counts, using the existing `Pill`; a text filter; "Mach ports: 8 s ago" with a Refresh button and a spinner while loading.
2. **Banner**, only when it applies: "Mach ports need the helper. Showing sockets and pipes only." (helper not running), or "N processes belong to other users and could not be read." (descriptor pass without the helper).
3. **Listening**: one line per `IPCExternal` with `listening`, for example `tcp 127.0.0.1:6379` or a socket path. Omit the section when empty.
4. **Peers**, grouped by the peer's Smart tree category, in `ProcCategory` order, each group collapsible with a count in its header. One row per peer process:
   - the existing `ProcessChip` (click opens that process in the inspector, which already pushes history);
   - the peer's `launchdLabel` in secondary text when it has one;
   - one pill per kind with its counts: `mach 14 → · ← 3`, `unix 2`, `pipe 1`;
   - a "queued N" badge when `mach.queued[peer]` is non-zero.
   Sort by total channels, descending. Show the first 15 rows of a group and a "Show N more" row.
5. **Common services**: a peer that at least 10 % of all processes in the Mach snapshot have a link to goes here and not under its category. Collapsed by default, header "Common services (N)". Compute the set once per snapshot. Measured: this folds 36 peers and takes the median process from 12 peers to 6.
6. **Outside**: `IPCExternal` rows that are not listening, grouped as "Unix sockets" (by path) and "Remote hosts" (by address, with count). Collapsed when there are more than 10.

To find a peer's category you need the root of its unit and `SmartTree.category(ofRoot:)`. If `SmartTree` does not already expose "category of the unit containing pid", add one small function that builds a pid → category map from the same input `SmartTree.build` uses, and compute it once per snapshot. Do not rebuild the tree per row.

Rows for a peer pid that is no longer in `store.procs` show the pid in plain text, not a chip.

When the selected row is a group and not a process, the tab is not shown; no group-level view in this version.

Empty state: "No connections to other processes found." with the banner above if it applies.

**Verify.** Build and launch the dev app. Use the computer-use or screenshot tools you have to check, and compare numbers, not impressions:

- Select Finder. The peer count shown must equal the number of distinct peers `--ipc --pid <finder pid>` prints (add that flag: it prints one line per peer with per-kind counts, and the common-services set). 
- Select `redis-server` or another process with a loopback listener: the Listening section shows its port.
- Stop being able to reach the helper is not testable by you; instead check the no-Mach path by running `--ipc --pid <pid> --no-helper` and confirming the app-side code path renders the banner (a `#Preview` or a debug default is acceptable).
- Click a peer chip: the inspector moves to that process and the back button returns.
- Time from opening the tab to peers appearing, with and without a cached Mach snapshot. Report both.

## Step 4: documentation

- `docs/process-info-sources.md`: add the two sources (descriptor pass; `lsmp` through the helper) to the right sections, and `machLinks` to the helper's call list.
- `docs/ipc-map-proposal.md`: change the status line to say which parts are implemented and that the rest is not planned yet. Do not rewrite the rest.
- `README.md`: one line for the Connections tab. No screenshot unless asked.

## Rules for the whole job

- Do the steps in order. Each step ends with its verification; do not start the next one with a failing check.
- Do not commit. Leave the changes in the working tree and report.
- If something measured contradicts this plan (for example `lsmp` fails under the helper, or the JSON differs from the sample), stop that step, report what you observed with the output, and do not work around it with a more expensive design.
- If a part turns out to cost much more than it looks here, drop to the cheaper behaviour and say so. The peer list with counts is the product; everything else in the tab is optional.

## What to report at the end

- What was built, per step, and which checks passed, with the numbers printed by `--ipc` and `--helper-call machlinks`.
- Anything cut or simplified, and why.
- Anything that needs the user: helper approval, a decision, a check you could not do.
