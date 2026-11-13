# Process info: sources and gaps

Every piece of information Proc X-Ray has about a process, grouped by the API, tool or calculation that produces it. After that: what else macOS makes available, and how Proc X-Ray compares with `top` and Activity Monitor.

The availability notes on unused APIs were measured on 2026-11-12 (macOS 27, Apple silicon, running as uid 501 without the helper) with a small C probe. They were not measured as root, so "needs root" means the call failed for this user and is expected to work from the helper; that has not been tested.

## What we read today

### Read for every process on each refresh

#### 1. `sysctl(KERN_PROC_ALL)` → `kinfo_proc` (`Native.listProcesses`)

- **pid**, **ppid**, **pgid**
- **uid** (effective) and **ruid** (real; only the helper uses it, for its permission check)
- **comm**: the short process name
- **start**: start time; together with the pid it is the process's identity (`key`)
- **stat**: process state
- **pflags**: process flags (used for Rosetta)
- **tty**: read, not shown anywhere

`sysctl(KERN_PROC_PID)` reads the same record for one pid; `Native.isSame` uses it to check that a pid still belongs to the same process.

#### 2. libproc

| Call | Gives |
|---|---|
| `proc_pidpath` | **path** |
| `proc_pidinfo(PROC_PIDTASKINFO)` → `proc_taskinfo` | **rss**, **virt**, **threads**, **cpuNanos** (user + system, mach ticks converted to ns); in `counters`: **runningThreads**, **contextSwitches**, **faults**, **cowFaults**, **pageins**, **machMsgsSent**, **machMsgsReceived**, **machSyscalls**, **unixSyscalls** |
| `proc_pid_rusage(RUSAGE_INFO_V6)` | **footprint**, **diskRead**, **diskWrite**, **energyNJ** (`ri_energy_nj`, the process's own CPU energy; until 2026-11-12 this read `ri_billed_energy`, which measured 0 for a process using 4 W of CPU), **billedEnergyNJ** (`ri_billed_energy`, shown as "Billed energy" in the inspector), **wakeups** (package idle + interrupt), and **cpuNanos** if task info failed; in `counters`: **instructions**, **cycles**, **pCoreNanos** (performance-core CPU time), **waitingNanos**, **logicalWrites**, **peakFootprint** (lifetime max), **neuralFootprint** |

`PrivMetrics.read` makes both calls; the app and the helper use the same function. The `proc_taskinfo` counters are 32-bit in the kernel and are read as unsigned, so they wrap at 2^32.

**waitingNanos** is `ri_runnable_time` minus CPU time. The kernel's runnable time is in mach ticks and includes time spent running: a CPU-bound process on a machine with twice as many busy processes as cores got 1.69 s of CPU and 3.95 s of runnable time in 4 s of wall time.

Checked against `top` for Dock: context switches, faults, COW faults, page-ins, Mach messages and both syscall counts matched, and CPU time matched `top`'s TIME.
| `proc_pidinfo(PROC_PIDCOALITIONINFO)` (flavor 20) | **coalition** (resource coalition id), **jetsamCoalition** |
| `proc_pidinfo(PROC_PIDVNODEPATHINFO)` | **working dir** (only while the General tab is open) |

#### 3. Private libsystem functions, looked up with `dlsym`

- `responsibility_get_pid_responsible_for_pid` → **responsible**
- `sandbox_check(pid, nil, 0)` → **sandboxed**. A "yes" only counts if `isSame` confirms the process is still there afterwards, because `sandbox_check` is also non-zero for a pid that no longer exists.
- `csops(CS_OPS_CDHASH)` → **cdhash** of the code running now. A change means the process exec'd something else, which invalidates cached signing details.

#### 4. Other libc / Mach calls

- `getpwuid` → **user** name
- `mach_timebase_info` → tick-to-nanosecond conversion
- `kill(pid, 0)` → whether the process is alive
- `sysctl(KERN_BOOTTIME)` → boot time, for start times recorded before the clock was set

#### 5. Command-line tools (every 5th tick, and on every manual refresh)

- `/usr/bin/lsappinfo list` → `LSApp`, matched by pid: **lsAppName** and **lsTags** (state tags such as `exited-with-subordinates`). The record also has bundleID, bundlePath, executablePath, type, version, arch, coalition (the *jetsam* coalition id), coalitionPIDs, relatedCoalitionIDs, relatedCoalitionPIDs and parentASN. The raw text is shown in the launchd / LS tab.
- `/bin/launchctl list` → **launchdLabel**, matched by pid; each job also has its last exit status.

### Signing: Security framework → `SignInfo` (`CodeSign.inspect`)

Filled in the background and cached by `codeKey`. `SecCodeCopyGuestWithAttributes(pid)` gets the running code; if that fails, the app falls back to `SecStaticCodeCreateWithPath`.

- `SecCodeCheckValidity` → **valid**
- `SecCodeCopySigningInformation` → **identifier**, **teamID**, **staticFlags**, **runtimeStatus** (runtime CS flags), **cdHash**, **authority** (certificate subject summaries), **entitlements** (keys and XML), **designatedRequirement**
- Checked against requirements: **isAppleSigned** — the code satisfies `anchor apple`, or has a `com.apple.` identifier and satisfies the Mac App Store leaf requirement
- Decided from those fields: **isPlatform** (platform identifier non-zero, or `CS_PLATFORM_BINARY` set), **isAdhoc** (static flag `0x2`), **unsigned** (no identifier, certificates or cdhash)
- Copied onto the process: **signer** (`shortSigner`) and **signID**

### Privileged helper (root, over XPC)

- `allMetrics`: the calls from groups 2–3 run as root. They fill only fields that couldn't be read locally (rss, virt, threads, cpuNanos, footprint, disk I/O, energy, wakeups, counters, responsible, sandboxed). `counters` is filled as a whole: a local read that got only one of the two calls keeps its partial set. **viaHelper** is set whenever the helper filled anything.
- `argsEnv`: the same as Args & Env below, plus the working dir, for processes the app can't read itself.
- `runTool`: runs the Inspector tools below as root.

### Read only when an Inspector tab is opened

- **Args & Env**: `sysctl(KERN_PROCARGS2)` → **execPath**, **argv**, **environment**, parsed by the kernel's layout (exec path padded to 8 bytes)
- **Files & Sockets**: `lsof -n -P -p <pid>`
- **Memory Map**: `vmmap --summary <pid>`
- **Sample**: `sample <pid> 1 -mayDie`
- **Logs**: `log show --last 10m --predicate 'processID == pid OR eventMessage CONTAINS "pid"'`
- **launchd / LS**: `launchctl print gui/<uid>/<label>` (falling back to `system/<label>`), `launchctl procinfo <pid>` (helper only), and the raw lsappinfo record
- Not per process: `sfltool dumpbtm` → Background Items, loaded only on request because it asks for an admin password

### Calculated and heuristic values (`Model.swift`)

- **name**: last path component, or `comm` without a path
- **isZombie**: `stat == 5`
- **isTranslated** (Rosetta): `P_TRANSLATED` (`0x20000`) in `pflags`
- **isInspectable**: rss could be read
- **respIsOther**: responsible pid set and not the process's own
- **bundlePath**: the path up to the last `.app/`
- **cpuPercent**: change in cpuNanos divided by the time since the last tick
- **key** (`pid:start`) and **codeKey** (`key:cdhash`, falling back to path, then comm)
- **Parent name**, **responsible description**, **coalition / jetsam member counts**: looked up or counted across the store
- **Shown start**: a start before boot is shown as boot time
- **Left Behind** (`leftBehindGroup` / `leftBehindApp` / `leftBehindPid`), from three signals:
  1. The responsible pid belongs to a process that's no longer running.
  2. LaunchServices marks an app `exited…`; its survivors are the processes in its coalition or its coalition pids.
  3. A running app lists a coalition other than its own under `relatedCoalitionIDs`: an earlier instance, whose processes outlived it.

  On macOS 27 signal 1 rarely fires, so signals 2 and 3 do most of the work.

## What else is available

Grouped by how hard it is to get. "Same user" means the call worked for another process of this user (Finder) but failed for a root process (launchd); the helper would cover the rest.

### Fields in structs we already read

`proc_taskinfo`: `pti_priority`, `pti_policy`, and `pti_threads_user` / `pti_threads_system` (CPU time of live threads only).

`rusage_info_v6` (measured: works, same user):

- `ri_penergy_nj`: the part of `ri_energy_nj` spent on performance cores (measured: 4.107 of 4.109 W for `yes`)
- `ri_cpu_time_qos_*`: CPU time per QoS class
- `ri_billed_system_time`, `ri_serviced_system_time`: CPU billed to this process for work done by others, and the reverse; probably what top's `cpu_me` / `cpu_others` show. Not added because the units are unconfirmed.
- `ri_serviced_energy`
- `ri_interval_max_phys_footprint`, `ri_lifetime_max_neural_footprint`, `ri_interval_max_neural_footprint`
- `ri_pinstructions`, `ri_pcycles`: the performance-core share of instructions and cycles
- `ri_wired_size`, `ri_pageins`
- `ri_child_*`: totals for reaped children
- `ri_page_wait_time_mach`, `ri_page_cache_hits`

### Other unprivileged calls

- `proc_pidinfo(PROC_PIDTBSDINFO)` → `proc_bsdinfo`: **nice**, gids (real, effective, saved), saved uid, controlling-tty process group, a registered process name (`pbi_name`, longer than `comm`). Same user.
- `proc_pidinfo(PROC_PIDWORKQUEUEINFO)`: workqueue threads total / running / blocked (top's `wq`). Same user.
- `proc_pidinfo(PROC_PIDLISTFDS)`: open file descriptor count without running `lsof`.
- `proc_pidinfo(PROC_PIDLISTTHREADS)` + `PROC_PIDTHREADINFO`: per-thread state, priority, CPU time and name, which would give top's "stuck" (uninterruptible) state.
- `proc_pidinfo(PROC_PIDARCHINFO)`: CPU type of the running image.
- `IOPMCopyAssertionsByProcess`: power assertions per pid — Activity Monitor's "Preventing Sleep" and the inspector's "Assertions". Measured: works.
- IORegistry `IOAccelerator` children: each user client has `IOUserClientCreator` ("pid N, name") and `AppUsage` with `accumulatedGPUTime`. Activity Monitor's "% GPU" and "GPU Time" come from this kind of data. Measured: readable without privileges.

### Needs root (the helper)

- `task_for_pid` (or the inspect / read variants) → a task port. Measured: works only for our own process, not even for another process of the same user. Root is not enough either: the helper got an inspect port for 13 of 727 processes (see "Task-port entitlements" below). So the list that follows is only reachable through Apple tools that carry the entitlement. With a task port:
  - `mach_port_space_basic_info` → **Mach port count** (top's `ports`, Activity Monitor's "Ports")
  - `task_info(TASK_VM_INFO)` → **compressed** and **purgeable** memory, internal / external memory
  - `task_policy_get(TASK_POLICY_STATE)` → importance **boosts** (top's `boosts`; not verified)
  - region walk (`mach_vm_region`) → private / shared resident memory (Activity Monitor's Real Private / Real Shared). top on this machine prints `N/A` for `mregion`, `rprvt`, `vprvt`, `kprvt` and `kshrd` without `-r`.
- `memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST)` → **jetsam priority** (top's `jetpri`) and memory limits. Measured: returns -1 without root.

### Other sources

- Per-process network bytes and packets: the private NetworkStatistics framework (what `nettop` uses), or parsing `nettop -P -L 1`. Not tried.
- Energy Impact: Apple doesn't publish the formula; it could be approximated from CPU, wakeups, GPU, disk and network. `powermetrics --samplers tasks` (below) prints Apple's own per-process energy impact.
- App Nap state, Recent hangs: source not identified. `taskinfo` (below) prints the App Nap suppression policy.

## Task-port entitlements: what root cannot do, and the Apple tools that can

Checked on 2026-11-13 (macOS 27, Apple silicon).

### Why the helper cannot read task ports itself

Most per-process kernel detail (Mach port space, VM regions, thread state, exception ports, vouchers) starts from a task port of the target. Being root does not give one: the helper got a task inspect port for 13 of 727 processes (`ExtraReads.swift`), and a read port is stricter still. Apple's tools get them through the `com.apple.system-task-ports.*` entitlements, which AMFI only honours on Apple-signed platform binaries; our Apple Development–signed helper would not launch with one. `com.apple.security.cs.debugger` does not help, since it only reaches targets that set `get-task-allow`. Injecting into the Apple tools is ruled out by library validation.

So the way in is the one the helper already uses for `lsof`, `vmmap`, `sample` and `lsmp`: run an Apple tool that carries the entitlement, as root, and parse its output.

For example, `lsmp` imports `host_processor_set_priv` → `processor_set_tasks_with_flavor` and `task_read_for_pid` (to get every task's read port), then `mach_port_space_info`, `mach_port_get_attributes`, `mach_port_get_context`, `mach_port_get_set_status`, `mach_port_kernel_object`, `mach_port_kobject_description`, `task_get_exception_ports_info`, `thread_get_exception_ports_info`, `task_threads`, `thread_get_mach_voucher` and `mach_voucher_debug_info` (`nm -u /usr/bin/lsmp`). Its only entitlement is `com.apple.system-task-ports.read`.

### Who holds which entitlement on this machine

Found by searching every binary under `/bin`, `/sbin`, `/usr`, `/System`, `/Library/Apple` and Xcode for the string `system-task-ports` (`grep -rlaF`, about 45 s), then reading each match's real entitlements with `codesign -d --entitlements - --xml`. Matches in the kernel, dyld shared caches and `taskgated` only mention the string. 44 binaries hold a variant:

| Entitlement | Holders | Usable from the helper |
|---|---|---|
| `system-task-ports` + `.control` + `.token.read` | Xcode's Instruments XPC services `com.apple.dt.instruments.dtarbiter`, `dtsecurity` | No: XPC services for Instruments, not tools |
| `.read` (+ `.read.safe`) | `atos`, `heap`, `leaks`, `malloc_history`, `sample`, `stringdups`, `vmmap` (system and Xcode copies) | Yes, command-line tools |
| `.read` | `ps`, `top`, `taskinfo`, `lsmp`, `spindump`, `tailspin`, `symbols` | Yes, command-line tools |
| `.read` | `sysmond` (Activity Monitor's data source), `tailspind`, `osanalyticshelper`, `PerformanceTraceService`, `TailspinSymbolicationServer` | Daemons and XPC services; whether `sysmond` serves other clients is not checked |
| `.read.safe` | `footprint` | Yes |
| `.inspect` | `powermetrics` | Yes |
| `.name.safe` | `PerfPowerServices`, `PerfPowerServicesExtended`, `perfpowermetricd`, `powerlogHelperd`, `rapportd`, `corespeechd`, `corespeechd_system`, `privatecloudcomputed` | Daemons |
| `.token.corpse` | `ReportCrash` and its three `ReportCrashService` XPC services | Crash corpses only |
| `.token.control` | `coreservicesd` | Daemon |

NewOSXBook's entitlement database (`ent.php`, macOS 15 data) lists 24 holders of `com.apple.system-task-ports`. It appears to group every variant under that name (it lists `footprint` and `powermetrics`, which hold `.read.safe` and `.inspect`). Six of its names are not holders here: `log`, `zprint`, `sysdiagnose` and `sysdiagnose_helper` exist on macOS 27 without any task-port entitlement, and `iclouddrivectl` and `thermald` are not installed. Entitlement lists from older releases need re-checking on the current one.

### What each usable tool adds

| Tool | Status | Adds |
|---|---|---|
| `lsmp -a -j` | used (Mach links) | Much more than we parse; see "lsmp JSON we don't read yet" |
| `vmmap --summary`, `sample` | used | — |
| `powermetrics --samplers tasks` | not used; not run yet (root) | Apple's per-process energy impact, CPU ms/s, interrupt and idle wakeups, disk and network, time per QoS |
| `taskinfo` | not used; not run yet (root, text only, cost unknown) | Requested and effective policy (role, App Nap suppression, darwin BG, QoS clamp and ceiling, I/O tier, runningboard managed, runaway daemon mitigation); boosts and "boosted by"; importance donor / receiver; **CPU time billed to others / billed to me by others** (voucher accounting: who a daemon works for); `extmod` (task-for-pid, thread injection and set-state counts by other processes); P / E core time and switches; Mach port count and occupancy; per-thread dispatch queue names (`--threads --dq`). Fields from the binary's format strings |
| `footprint -j` | not used | Per-category dirty / swapped / clean / reclaimable / wired bytes as JSON. **Works unprivileged for the user's own processes** (Finder: 0.07 s); others and `-a` need root. Overlaps `vmmap --summary`, but faster and JSON; `--sample` for a time series |
| `spindump` | not used | Every thread's stack, and possibly what a thread blocked in `mach_msg` waits on (owner pid). Heavy; not verified |
| `heap`, `leaks`, `stringdups`, `malloc_history`, `atos`, `symbols` | not used | Malloc and symbolication tools; `leaks` suspends the target, `malloc_history` needs MallocStackLogging. At most an on-demand per-class object count from `heap` |
| `ps`, `top` | not used | Nothing beyond what `proc_pidinfo` already gives |

`zprint` (no task-port entitlement, but `com.apple.private.memoryinfo`) shows kernel zone usage machine-wide, including memory used for Mach ports in total; not per process.

### lsmp JSON we don't read yet

`MachSnapshot.parse` reads `ipc-object`, `rights`, `msg_count`, `type`, `description`, `pid` and `members`. The binary also writes the keys below (from its strings; not yet checked against a real root snapshot):

- **Kernel object type**, already read but only tallied. About 60 values that group into: process / thread control (`TASK-CONTROL/READ/INSPECT/NAME`, `THREAD-*`, `TASK_RESUME`, `TASK_ID_TOKEN`, `TASK_FATAL`); drivers (`IOKIT-CONNECT/OBJECT/IDENT`, `UEXT_OBJECT`, `MAIN-DEVICE`, `IO-QUEUE-DONE`); memory (`NAMED-MEMORY`, `MEMORY-OBJECT`, `UPL`, `PAGER-REQUEST`, `XMM-*`); sync and timing (`SEMAPHORE`, `LOCK-SET`, `EVENTLINK`, `TIMER`, `CLOCK`, `WORK_INTERVAL`); privilege and host (`HOST`, `HOST-PRIV`, `HOST-SECURITY`, `PROCESSOR(-SET)`, `LEDGER`, `SUID_CRED`, `MACF-LABEL`); other (`VOUCHER`, `FILEPORT`, `HYPERVISOR`, `EXCLAVES_RESOURCE`, `ARCADE_REG`, `UND-REPLY`). Worth flagging: `HOST-PRIV`, `HYPERVISOR`, `FILEPORT`, another process's `THREAD-CONTROL`.
- `port_status_flags`: guarded, strict guard, importance donation, tempowner, taskptr, revive. Guarded receive rights are likely libxpc / libdispatch connection ports (not verified).
- `boosts`: importance boost count.
- `notifications`: dead-name, no-senders and port-destroyed requests. A no-senders request usually marks a server port.
- `queue_limit`, next to `msg_count`: a full queue means senders block.
- `send_rights`, `send_once_rights` (reply ports for requests still in flight), `oref`, `context`.
- `dead_names`: rights to ports whose receiver has died.
- `exception_ports` for each task and thread: mask (`BAD_ACCESS`, `CRASH`, `GUARD`, `RESOURCE`…), behaviors, flavor and receiver. Shows who handles the process's crashes (ReportCrash, a debugger, a crash reporter SDK); a link type not drawn anywhere yet.
- `vouchers` with recipes (importance and resource accounting), `threads`.

What lsmp cannot give: names of anonymous ports (nothing in it asks the kernel for service-port info; launchd plists remain the source), and what flows over a port. Mach message IDs, and from them the MIG subsystem, would come from kdebug, which the helper already reads for the Syscalls pane.

## Compared with `top`

`/usr/bin/top` is setuid root, so it can read fields that need a task port.

| top key | Proc X-Ray |
|---|---|
| pid, command, ppid, pgrp, uid, user | yes |
| cpu, time | yes |
| threads | yes (total and running) |
| mem (footprint), vsize | yes |
| state | partly: from `p_stat`; top's "running" / "stuck" come from thread states |
| csw, faults, cow, pageins, msgsent, msgrecv, sysbsd, sysmach | yes |
| instrs, cycles | yes (lifetime totals; `top -l` prints per-interval deltas) |
| cpu_me, cpu_others | no — probably `ri_billed_system_time` / `ri_serviced_system_time`, units unconfirmed |
| wq | no — `PROC_PIDWORKQUEUEINFO` |
| ports, purg, boosts | no — task port (root) |
| jetpri | no — `memorystatus_control` (root) |
| mregion, rprvt, vprvt, kprvt, kshrd | no — region walk; top itself shows `N/A` by default |

## Compared with Activity Monitor

Column and inspector labels taken from Activity Monitor's bundled strings (`ActivityMonitor.loctable`, `ProcessInspector.loctable`).

| Activity Monitor | Proc X-Ray |
|---|---|
| Process Name, PID, User, Kind (Apple / Intel), Sandbox, Restricted | yes (Restricted = runtime `CS_RESTRICT`, in the Signature tab) |
| % CPU, CPU Time, Threads, Idle Wake Ups | yes |
| Memory (footprint), Real Memory (RSIZE), Virtual Memory | yes |
| Bytes Read, Bytes Written | yes |
| Parent Process, Process Group, executable path | yes |
| Open Files and Ports, Sample | yes (`lsof`, `sample`) |
| Context Switches, Faults, Page Ins, Mach Messages In / Out, Mach / UNIX System Calls | yes |
| Neural footprint | yes |
| % GPU, GPU Time | yes — IORegistry `AppUsage` |
| Preventing Sleep, Assertions | yes — `IOPMCopyAssertionsByProcess` |
| Ports, Compressed Memory, Purgeable Memory, Private / Shared Memory, Real Private (RPRVT) / Real Shared (RSHRD) | no — task port (root) |
| Sent / Received Bytes, Sent / Received Packets | bytes per second from `nettop`, sampled about every 5 s; packets no |
| Energy Impact, Avg Energy Impact, 12 hr Power | no — unpublished formula, history kept by the system |
| App Nap, Requires High Perf GPU, Recent hangs | no — source not identified |
| Spindump | no |

Proc X-Ray has things neither tool shows: responsible process, coalitions, Left Behind detection, code signature and entitlements, launchd / LaunchServices attribution, arguments and environment, and logs.
