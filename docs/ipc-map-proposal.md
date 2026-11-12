# Proposal: mapping every IPC connection between processes

Status: proposal, written 2026-11-12. Nothing here is implemented. It extends the "Connections" tab and the "small graph view" sketched in `tree-and-inspector-proposal.md` (Part 3) into a full design.

The goal: for any process, app or category, answer "what is this talking to, over what, and who started it?", and for the whole machine, "who talks to whom?", without drawing an 800-node hairball.

All counts were measured on this machine on 2026-11-12 (macOS 27, Apple silicon, uid 501). The descriptor, launchd and IOKit figures are from an unprivileged run with 810 processes; the probe was a throwaway C program calling `proc_pidinfo` / `proc_pidfdinfo` plus a Python script to pair endpoints. The Mach port figures are from `sudo lsmp -a -j` run later the same day with 692 processes. None of the scripts are in the repo. What is still untested is listed under "Not measured".

## What counts as a connection

A **channel** is one kernel object shared by two endpoints. A **link** is all the channels between two nodes, where a node is a process, a Smart tree unit (an app with its helpers), or a category.

| Kind | Evidence | Direction (client → server) | Name shown on the edge |
|---|---|---|---|
| Mach port | A holds a send right, B holds the receive right | none from the rights alone: 85 % of linked pairs hold rights both ways (see Layer 2). Use the server heuristic there. | Mach service name from launchd, else the kernel object type |
| XPC service | process is a live service in another process's launchd pid domain | owner → service | service label |
| Unix socket | A's `unsi_conn_pcb` equals B's `soi_pcb` | the end with a peer address (`unsi_caddr`) → the end bound to it | socket path |
| Pipe | A's `pipe_peerhandle` equals B's `pipe_handle` | writer → reader | fd numbers (`stdout → stdin`) |
| TCP / UDP on loopback | local and remote port pairs match | connecting end → the end whose port has a listener | port |
| Remote network | connected socket with a non-loopback peer | process → host | host:port |
| IOKit | an `IOUserClient` whose `IOUserClientCreator` is the pid | process → driver | driver class |
| Shared memory | the same VM object mapped in both | none | region name |
| Passed descriptor | fileport entries (`PROC_PIDLISTFILEPORTS`) | none | — |

An endpoint that is not a process is still a node: a remote host, a kernel driver, the kernel itself (kernel control sockets), or "unreadable process" when the peer is one the app cannot inspect.

One distinction the UI must keep visible: a Mach send right, an XPC registration or a shared mapping means **can talk**. A connected socket or a pipe with both ends open means **is connected**. Neither proves traffic is flowing right now.

## What can be read, and what it costs

### Layer 0: file descriptors, unprivileged

`proc_pidinfo(PROC_PIDLISTFDS)` then `proc_pidfdinfo` per descriptor. One pass over all 810 processes took **15 ms** (three warm runs: 14.4–15.1 ms; first run 44 ms). 575 processes were readable; the other 235 belong to other users and need the helper.

| Descriptor kind | Count | Result of pairing |
|---|---|---|
| Pipes | 286 fds = 145 pipes | 128 have both ends inside one process; **17 cross a process boundary**. 14 ends had no visible peer. |
| Unix sockets | 549 fds, 536 connected | **396 peers resolved** (31 of them in the same process). 140 unresolved, and all of those carry the server's path: `/var/run/syslog` 82, `/var/run/mDNSResponder` 51, `/var/run/usbmuxd` 7. |
| TCP | 214 fds, 17 listening | 114 connected on loopback: 104 are both ends inside `PacketTunnel`, 10 have no visible peer. 83 go to remote hosts. |
| UDP | 13 | — |
| Kernel control sockets | 63 | `com.apple.netsrc` 33, `utun_control` 14, `netagent` 13, `flow-divert` 3 |
| kqueue, channel, nexus | 328, 127, 27 | not connections; counted only |
| POSIX shared memory fds | 0 | processes close the fd after mapping, so this source is empty. Shared memory has to come from the VM map. |

Two things follow from this.

- The 140 unresolved unix peers do not need the helper to be named. The client's descriptor holds the path it connected to, so the edge can be drawn to "whoever listens on `/var/run/syslog`" and resolved to a pid once any source identifies the listener.
- The descriptor graph is small. It has **110 links between 81 processes**, in three islands (51 processes around Firefox, 28 around Claude, one pair). The other 729 processes have no cross-process descriptor at all. Descriptors are the cheap part of the picture, not the bulk of it.

`lsof` is no longer needed for this. The Files & Sockets tab can use the same pass.

### Layer 1: launchd and IOKit, unprivileged

| Source | What it gives | Measured |
|---|---|---|
| `launchctl print pid/<n>` | the XPC services running inside a process's own domain, with pids | 597 of 810 domains readable; 62 processes own live services; **202 owner → service links**. 5.0 s for all 810 calls, so run it per selection, or once in the background and cache by process key. |
| LaunchDaemon / LaunchAgent plists, `MachServices` key | Mach service name → launchd label | 966 plists, 799 declare services, **2,115 service names**. Static; read once. |
| `launchctl print gui/<uid>/<label>` | the endpoints a running job has registered, including ones not in its plist | works; one call per label |
| IORegistry, `IOUserClientCreator` | process → driver | **694 user clients held by 248 processes**. `ioreg -l` took 0.25 s; walking the registry in-process should be faster (not timed). |

### Layer 2: needs the helper

- The Layer 0 pass run as root, for the 235 processes the app cannot read.
- **Mach ports**: `lsmp -a -j <file>`, measured below. `task_for_pid` fails for other processes (see `process-info-sources.md`), but `/usr/bin/lsmp` is signed with `com.apple.system-task-ports.read`, so the helper can run it the way it runs `lsof` and `vmmap` today. This is where most of the graph is.
- **Shared memory**: full `vmmap` output for both processes, matching shared regions. Per pair and slow; only on request.

### Mach ports, measured (`sudo lsmp -a -j`)

**It works, for every process.** As root it read all 692 processes, including `launchd`, `WindowServer`, `logd` and hardened third-party apps. Unprivileged it reads none.

| | |
|---|---|
| Time, all processes | **2.97 s** wall (1.95 s user) |
| Time, one process (`-p`) | 0.08–0.31 s (`launchd`, Finder, Firefox, `logd`, `WindowServer`) |
| Output | 38.8 MB JSON, 169,725 port entries |
| Ports per process | median 84, 90th percentile 409; `WindowServer` 25,141, 1Password Browser Helper 10,102, `launchd` 5,589 |

**Pairing.** Every entry has an `ipc-object` id that is the same in every process holding a right to that port, and stable between runs (790 of 790 matched for Finder across two runs). Joining send rights to receive rights on it:

- 110,131 send and send-once rights. **81,572 pair with a receive right** (zero id collisions among 66,070 receive rights); 31,657 of those are a process's rights to its own ports.
- The 28,559 that don't pair are kernel objects, which `lsmp` types: memory entries 5,061, thread ports 3,833, IOKit objects 3,140 and connections 676, task ports 3,811, semaphores, vouchers, clock and host ports. 5,997 are reported as owner "unknown".
- Where `lsmp` prints the receiver's pid itself (send-once rights mostly), it agrees with the join in 12,992 of 13,122 cases.

**`-p` is not enough.** For one process, `lsmp -p` lists who holds rights to *its* ports, but its own outgoing send rights come back typed `UNKNOWN` with no receiver. Outgoing links need the all-process run. So the cost is 3 s per snapshot whatever is selected.

**The graph.**

| | |
|---|---|
| Cross-process channels | 49,915 |
| Links (pairs of processes) | **9,732**; 8,310 have rights in both directions, 1,422 in one |
| Peers per process | median 12, 90th percentile 48 |
| Processes with no outgoing link | 6 |

Compare 110 links from descriptors: Mach is 99 % of the map.

**Hubs.** Share of all processes holding a send right to each: `launchd` 99 %, `notifyd` 96 %, `logd` 93 %, `opendirectoryd` 85 %, `cfprefsd` 77 %, `coreservicesd` 64 %, `lsd` 52 %, `runningboardd` 47 %, `analyticsd` 42 %, `distnoted` 37 %, `launchservicesd` 35 %, `WindowServer` 27 %.

| Fold peers that this share of processes link to | Hubs folded | Links left | Peers per process, median / 90th pct |
|---|---|---|---|
| ≥ 50 % | 8 | 10,097 directed | 12 / 80 |
| ≥ 25 % | 13 | 7,582 | 11 / 76 |
| ≥ 10 % | 36 | 3,881 | 6 / 51 |
| ≥ 5 % | 109 | 700 | 2 / 11 |

**Also in the same output:**

- **Queued messages** on each receive right. 1,373 ports had a backlog; one widget extension had 2,989 messages queued on one port. That is a direct "this process is not draining its queue" signal, shown nowhere else in the app.
- **IOKit connections** with the driver class (676: `IOHIDEventServiceUserClient` 138, `RootDomainUserClient` 135, `IOSurfaceRootUserClient` 92, `AGXDeviceUserClient` 86). With the helper this replaces the IORegistry walk.
- **Shared memory entries**: 2,798 objects, 1,808 held by more than one process. Most are shared by many processes at once; only 69 pairs come from objects with six holders or fewer. So memory entries need a "shared by few" cut-off to mean anything, and may make step 10's `vmmap` comparison unnecessary.

### Direction and names for a Mach edge

Direction cannot come from the rights, since most pairs hold them both ways (request port one way, reply or notification port the other). Use, in order: B is a service in A's pid domain → A is the client; exactly one side has a launchd label that declares `MachServices` → that side is the server; otherwise draw the link undirected.

`lsmp` does not say which service a port is. Three joins, in order:

1. B is a service in A's pid domain → the XPC service label (Layer 1).
2. B has a launchd label → the `MachServices` names from its plist. Of 799 jobs that declare services, 437 declare exactly one, so the name is certain; 362 declare two or more, and the edge reads "one of: …" with the count.
3. Otherwise the kernel object type from `lsmp`, or "anonymous port".

## The UI

Three places, one model. Each is useful without the next.

### 1. Connections tab: one node in the middle

The selected node sits in the centre. Things that connect **to** it are on the left, things it connects **to** are on the right. Both sides are grouped by Smart tree category, so the layout is the same every time and nothing moves when data refreshes. This is a fixed three-column layout, not a force-directed graph.

Illustrative, not measured:

```
 Connections                 [This process | Whole app]   ● Mach ● XPC ● Socket ● Pipe ● TCP ● IOKit      ⟳ 8 s ago

  CONNECT TO THIS                        THIS                          THIS CONNECTS TO

  Apps                             ┌──────────────────┐                System services
    Claude ──── tcp :9222 ────────▶│ Firefox          │━━ mach ×14 ━━▶   WindowServer
                                   │   34 processes   │── mach ×3 ───▶   coreaudiod
  System interface                 │   61 links inside│── unix ──────▶   mDNSResponder
    Dock ────── mach ×2 ──────────▶│                  │                Drivers
                                   └──────────────────┘── iokit ×4 ──▶   AGXAccelerator
                                                                       Network
  ▸ Common services (9 hidden)                           ── tcp ×83 ──▶   31 remote hosts
```

- **Line weight** is the number of channels. **Colour** is the kind; the kind chips at the top filter and double as the legend. **Solid** lines are connected channels, **dashed** are can-talk rights.
- **Scope switch**: "This process" or "Whole app". For a unit, links between its own processes are counted in the box ("61 links inside") and open as a second view of the same layout, one level down. Selecting a category row in the tree uses the same view with the category in the middle.
- **Common services**: a peer that most processes talk to (`launchd`, `logd`, `notifyd`, `cfprefsd`, `distnoted`, `syslog`, `mDNSResponder`) carries no information on every single map. A peer that more than **10 %** of processes link to is folded into one "Common services" row, collapsed by default. On this machine that folds 36 peers and leaves a median of 6 peers per process. The threshold is a setting; the list is computed, not hard-coded.
- **Busy nodes**: even after folding, one process in ten has more than 51 peers. Each category on either side therefore shows its top rows by channel count and a "+ N more" row; the table mode is the complete list.
- **Backlog badge**: a peer or edge whose receive port has queued messages shows the count.
- **Click a peer**: selects it in the tree and re-centres the tab on it, pushing onto the inspector's existing back/forward history. Peers are the existing `ProcessChip`.
- **Click an edge**: opens the channel list below.

```
 Firefox → WindowServer                                                       14 channels
 Kind   Name                              This end          Other end        State
 mach   com.apple.windowserver.active     send  0x1a03      recv 0x5b07      can talk
 mach   (anonymous port)                  send  0x2c0f      recv 0x9e13      can talk · 2 queued
 unix   /var/run/…/Listeners              fd 41             fd 12            connected
```

- **Table mode**: a Visual / Table switch (the app's existing Visual / Raw pattern) shows every channel of the node as one filterable, sortable table. This is what replaces `LsofView`'s socket rows, and it is the fallback for nodes with hundreds of links.
- **Listening**: ports and socket paths this node accepts on are listed above the diagram, with the number of connected clients, since that is the most common reason to open the tab.

### 2. In the tree

- New columns: **Peers** (distinct processes linked), **Channels**, **Listening** (ports and socket paths), **Clients**. Group rows roll up, counting only links that leave the group.
- **Highlight peers**: with a row selected, its peers get a marker in the tree's gutter, and collapsed groups containing a peer show a count. No view switch needed to see "these six rows are what it talks to".
- **Filter chip** "Connected to ⟨selection⟩": reduces the tree to the selection and its peers, keeping the category structure.

### 3. IPC Map: the whole machine

A new sidebar section. It opens at the category level and drills down, so it never draws more than a few dozen nodes at once.

- **Level 1, categories**: a 7 × 7 matrix (rows call, columns serve), each cell shaded by link count, split by kind on hover. Seven rows fit on screen and answer "do third-party services talk to my apps?" at a glance.
- **Level 2, a cell or a category**: the units inside it, as a matrix when both sides are large, or as the three-column layout when one side is a single unit.
- **Level 3, a unit**: the Connections view above. The map and the inspector tab are the same component.
- **Find a path**: pick two processes; the map shows the shortest chains between them (A → `tccd` → B), ignoring common services unless asked. Answers "how could this app reach that daemon?".
- **Lenses**, as chips, each a saved filter: "Crosses the sandbox" (one end sandboxed, the other not), "Crosses users" (uid differs, especially user → root), "Third-party ↔ third-party", "Network-facing" (processes with remote sockets, plus everything linked to them), "Unsigned or ad-hoc peers". These are the questions a map is opened to answer, and they use fields the store already holds (`sandboxed`, uid, `SignInfo`).

### Changes over time

Each snapshot is diffed with the previous one. New links get a "new" badge for a minute; ended links stay greyed for a minute. The capped per-process event list proposed for the Activity tab gains "connected to X" and "disconnected from X" entries. A "Record" toggle on the map keeps every link seen since it was switched on, so short-lived connections are not missed between refreshes.

## Model and code

```
Endpoint  = process(key, fd or port name) | remoteHost(addr, port) | driver(class) | kernel(name) | unresolved(hint)
Channel   = kind, a: Endpoint, b: Endpoint, name, direction, state (connected | canTalk), source layer
IPCSnapshot = [Channel], taken at, which layers it includes
```

- `Sys/IPC.swift`: the Layer 0 pass and the pairing, as pure functions over the raw descriptor records, so pairing is unit-tested from fixtures.
- Links are derived, not stored: group channels by the pair of nodes at the level being shown (process, unit, category). The unit and category of a process come from `SmartTree`.
- Helper: add `fdSnapshot` (the Layer 0 pass as root, returning the raw records) and an `lsmp` case to the tool enum. Protocol version bump.
- Refresh policy: Layer 0 is cheap enough to run on every tick, but only while a Connections tab, an IPC column or the map is visible. Layer 1 and Layer 2 are snapshots with an age label and a refresh button. A Mach snapshot is 3 s and 39 MB of JSON, so the helper should parse it and return only the paired links and per-port details the views use, not the raw file over XPC.
- Mach pairing is a join on `ipc-object`. The tree's Peers and Channels columns show Mach counts only once a snapshot exists, with its age in the header tooltip.
- When the helper is absent the views still work on Layers 0 and 1, with a banner saying Mach ports and other users' processes are not included. A partial map must say it is partial.

## Order of work

| # | Step | Size | Depends on |
|---|---|---|---|
| 1 | Layer 0 pass and pairing in-process; Files & Sockets reads from it instead of `lsof` | M | — |
| 2 | Connections tab: three-column view and channel table, descriptors only | M | 1 |
| 3 | Tree columns, peer highlight, "Connected to" chip | S | 1 |
| 4 | XPC service links from pid domains; `MachServices` name table; IOKit clients | M | 2 |
| 5 | Helper: `fdSnapshot` as root; resolve path-named peers to listeners | S | 1 |
| 6 | Helper: `lsmp` snapshot, parse, name edges; common-services folding | L | 4 |
| 7 | IPC Map section: category matrix, drill-down | M | 6 |
| 8 | Lenses and path finding | M | 7 |
| 9 | Diffing, timeline events, Record | M | 2 |
| 10 | Shared memory between two chosen processes | M | 6 |

Steps 1–3 need no privileges and no new tools, and give a correct picture of the 81 processes that use sockets and pipes. Step 6 is the one that makes the map complete: Mach is 9,732 of the links against 110 from descriptors. Since it is now known to work, a reasonable alternative order is 1, 6, 2: build the Connections tab once on both sources, so its layout is designed for 12 peers per process and not 2.

## Not measured

- The server heuristic for Mach direction: how many of the 9,732 links it leaves undirected.
- How many Mach links can actually be named by the three joins. The plist counts say how many jobs are unambiguous, not how many links.
- `lsmp` run by the helper (a launchd daemon) and not by `sudo` in a terminal. It should behave the same; not tried.
- The time to parse the 39 MB JSON in Swift.
- What the 5,997 send rights with owner "unknown" are.
- The Layer 0 pass as root, and whether the 14 unpaired pipe ends and 10 unpaired loopback TCP peers are in other users' processes.
- Whether pipe direction can be read reliably from the descriptor's open flags.
- Walking the IORegistry in-process instead of through `ioreg`.
- The cost of running the Layer 0 pass on every tick alongside the existing refresh.
- A machine with a different mix of apps. Every number here is from one machine at one moment.
