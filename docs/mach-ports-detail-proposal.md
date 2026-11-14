# Richer Mach port information: proposal

Today the Connections tab turns `lsmp -a -j` into peers (who can send to whom, port counts, queued messages) and kernel objects (IOKit classes, shared memory, task ports, a tally of other types). `docs/process-info-sources.md` ("lsmp JSON we don't read yet") lists what else lsmp writes, from its strings, unchecked. This proposal checks it against a real snapshot and says what to show.

## What was measured

One `sudo lsmp -a -j` run on 2026-11-13 (macOS 27, Apple silicon): 802 processes, 204,356 port entries, 43 MB of JSON. Counted with throwaway Python scripts (not in the repo). The same machine through the helper, a few seconds earlier: 800 processes, 20,146 directed links, 3.42 s.

Keys present, per entry: `ipc-object`, `name`, `rights`, `type`, `send_rights` (user references), `notifications`, `identifier`, `pid` / `process`, `description`, `members`. On receive rights only (87,780): `queue_limit`, `msg_count`, `port_status_flags`, `boosts`, `recv_rights`, `send_once_rights`, `oref`, `context`. Per process: `total`, `send_rights`, `receive_rights`, `send_once_rights`, `port_sets`, `dead_names`, `dead_name requests`, `vouchers`, `exception_ports`.

Not in the JSON, although the binary has strings for them: thread exception ports, voucher recipes, threads. The text output may have them; not checked.

## Findings

### 1. Task ports of other processes: currently always empty (a bug)

The helper's snapshot reports **0** task ports held for another process. The parser takes the target from the entry's `pid`, but for `TASK-*` types lsmp writes the **holder's** pid, not the target's (3,841 of 3,841 task entries with a pid equal the holder's own; the 320 that differ are `TASK_ID_TOKEN`, which the `TASK-` prefix check skips anyway).

The target can be found by joining on `ipc-object`: a process's own task control port (mach_task_self) is its lowest-named control right, `0x00000203` for 798 processes and `0x00000103` for a few (`crashhelper`, `keyboxd`, `sudo`). By that rule each of the 801 control ports has exactly one owner, and the join recovers **565 control rights to other processes**: `coreservicesd` holds 503, 63 % of processes (it has `system-task-ports.token.control`), and browsers and Electron apps hold their helpers' (`crashhelper` 22, `firefox` 21, `Claude` 11, `Slack` 5, `1Password` 3). Read ports are never shared (802 objects, one holder each); name ports are widely held (`launchd` 91, `WindowServer` 60, `chronod` 43) and say little.

**Done** (`MachSnapshot.taskRights`): the join above, for control, read and inspect ports; live through the helper, 570 control rights, `coreservicesd` 507. Name ports and ID tokens stay counted under kernel objects only. A holder of at least 10 % of processes' task ports (`coreservicesd`) is marked as a common holder on the target's row and left out of its graph.

### 2. Port totals per process: Activity Monitor's "Ports", for every process at once

The per-process counts come for free with the snapshot already taken. Median `total` 77; top: `WindowServer` 27,129 (taskinfo, minutes earlier: 27,077), `1Password Browser Helper` 14,753, `1Password-BrowserSupport` 10,495, `launchd` 5,820, `identityservicesd` 4,845.

Proposal: a **Ports** column (and a line in the Resources tab) from the cached snapshot, read only while shown, like other columns that need extra reads. Blank without the helper. Its tooltip says it is up to 30 s old.

**Done** (`MachSnapshot.counts`, `MachLoader.current`): a Mach ports column section (Ports, Dead names, Replies owed, Full queues), rows in the Resources tab's "System calls and IPC" card, and the process's own counts on the Connections tab's Mach line. Checked on MarkEdit: 508 ports and 2 dead names in all three places. Note that a port name can hold both a receive and a send right, so receive plus send exceeds the total (214 + 361 against 508).

### 3. Leak and backlog signals

All three are per process or per port, and each names the other side.

- **Dead names**: rights to ports whose receiver died, never released. Median 0. `WindowServer` 21,173, `WindowManager` 585, `BetterTouchTool` 543, `AltTab` 399. The entries carry no `ipc-object` (all `0x0`), so the dead peer can't be named; only counted.
- **Outstanding send-once rights** (replies owed): `1Password Browser Helper` holds 14,561, of which 10,426 are replies owed to `1Password-BrowserSupport` and 4,135 to processes lsmp couldn't name. Next is `launchd` with 568. A count this large is a reply leak.
- **Full queues** (`msg_count` ≥ `queue_limit`): 231 receive ports. Senders block or get `MACH_SEND_TIMED_OUT`. Examples: `launchd` 6/6 with `universalaccessd`, `identityservicesd` and `biomed` the only senders; `powerd` 6/6 from `analyticsd`; `cfbackd` five ports at 1/1 from `diskarbitrationd`; `gamepolicyd` 16/16 from `notifyd`.

**Columns and process totals done** with finding 2. Proposal still open: in Connections a per-peer note, "queue full (6 of 6)", "owes 10,426 replies". A badge on the Mach status line when this process has any full queue.

### 4. Who is the client: send-once rights and no-senders requests

The IPC map proposal says the rights can't tell client from server. Two fields help:

- A **send-once right** held by A to a port B receives on is a reply A owes B: B asked, A serves. lsmp also writes the receiver's pid on send-once rights, but it agrees with the `ipc-object` join only 11,247 of 18,420 times, so use the join.
- A **no-senders notification** on a receive right is how servers notice their clients going away (9,777 receive ports have no-senders plus port-destroyed requests).

Proposal: per peer, a direction from these when they agree (replies owed one way, no-senders port on the other side), else stay "⇄". Not yet measured how many of the 10,917 pairs this settles; measure before showing it.

### 5. Exception (crash) handlers: a new link kind

523 task exception port entries. `receiver_object` never matches any port (0 of 523); `port_object` does, and the process holding its receive right is the handler:

| Mask | Handler | Count |
|---|---|---|
| RESOURCE | `ReportCrash` (via launchd's default) | 463 |
| RESOURCE | `chrome_crashpad_handler` (Claude, Slack, 1Password) | 29 |
| BAD_ACCESS, BAD_INSTRUCTION, ARITHMETIC, BREAKPOINT… | the process itself (`plugin-container` 20, `Raycast` 2, `ghostty`, `BetterDisplay`, `SSHTunnel`, `AltTab`) | 26 |
| same | `firefox` for its GPU helper and plugin containers | 2 |

Proposal: a "Crash handler" row in Connections ("crashes go to chrome_crashpad_handler: bad access, resource…", linked to the handler), and on the handler the reverse ("handles crashes for 19 processes"). An in-process handler (a crash-reporting SDK) reads "handles its own crashes". The default ReportCrash route is folded like a common service.

**Done** (`MachSnapshot.exceptionRoutes`), with one correction: the ReportCrash and crashpad routes carry only `RESOURCE` (resource-limit exceptions), not bad-access crashes, and lsmp prints their mask with a leading space, so it likely leaves a bit unnamed. The rows therefore list the exception kinds lsmp names instead of saying "crashes". Rows: **Handler** (who handles this process's exceptions), **Handles** (whose exceptions this process handles; the system default collapses into one row), **In-process**. 8 processes have two routes, e.g. AltTab handles its own bad-access exceptions and sends resource ones to ReportCrash. A handler can also be another process: Raycast handles its `node` child's. ReportCrash is marked common (58 % on the dump, 60 % live) and left out of graphs. Checked: the dump gives 523 routes, 30 in-process, ReportCrash 462, crashpad 29, matching the raw count. Live: 557 routes. In the app, Slack shows Handler → its chrome_crashpad_handler, and that handler shows Handles for the Slack processes and its own Handler → ReportCrash.

### 6. Importance boosts

175 receive ports carry boosts (122 of them 1). Summed by holder: `AXVisualSupportAgent` 60, `AccessibilitySettingsSearchExte…` 56, `com.apple.WebKit.GPU` 40, `launchd` 34. A boost is a client's priority donated to the receiver while its message is pending, so the boosted process is working on someone's behalf right now.

Proposal: a "boosted ×N" note on the peer row whose port carries it. Pair later with taskinfo's "boosted by", which names the donors.

### 7. Port flags

`guarded` 49,144, `strict guard` 37,478, `imp donation` 36,582, `taskptr` 242 (`(null)` 20,375 is lsmp printing an unknown bit). Guarded receive rights are most likely libdispatch / libxpc connection ports (not verified). Proposal: no column; use the flags only inside a port detail list (8), and count "XPC-style (guarded)" ports per peer if it proves to mean that.

### 8. Port detail per peer (drill-down)

Selecting a Mach peer row opens its ports: our name for each, rights and references, queue `msg_count` / `queue_limit`, boosts, flags, notification requests. The helper would keep these only for the selected process's ports instead of sending all 204,356; that needs a second helper call, `machPorts(pid:)`, served from the helper's own last lsmp run (it reruns lsmp only past the 30 s age). Not needed for 1–6.

## Left out

- `context`, `identifier`, `oref`: no use to a reader (`context` is a pointer the receiver set; 12,426 nonzero).
- Kernel object descriptions: only IOKit and memory entries carry one, already parsed.
- `HOST-PRIV` (6 holders: `launchd`, `UserEventAgent`, `powerd`, `coreauthd`, Little Snitch's network extension, `lsmp`) and `FILEPORT` (13, all `launchd`): could be flagged as privileged rights, but the holders are expected; one line under kernel objects, as today.

## Cost

No extra lsmp run: 1–6 all come from the run the helper already does. The reply grows by per-process counts (802 × 8 integers), exception routes (~523), owed replies and full queues per pair, and boosts: estimated well under 100 KB on top of today's ~1 MB. Measured after step 2: the per-process counts alone add **106 KB** (1.23 MB reply for 806 processes), since JSON repeats every key per process; an array encoding would cut that if the reply size starts to matter. Parsing reads fields of entries it already walks.

## Order

1. Fix task-port targets (finding 1). Small; the Connections tab shows wrong data today.
2. Per-process totals, Ports column, leak and backlog columns (2, 3).
3. Crash handlers (5).
4. Per-peer notes: full queue, replies owed, boosts (3, 6); then direction (4) once measured.
5. Port detail drill-down (8), if wanted.

Each step: run `--helper-call mach <pid>` against the numbers above, and add the new counts to `Bench.machSummary` so they are checkable from the command line.
