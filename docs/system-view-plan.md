# Plan: a System view that exposes every counter macOS keeps

Status: phase 1 implemented 2026-11-18 (`Sys/Counters/*.swift`, `UI/CountersView.swift`, sidebar System ▸ All Counters, `--counters`). Differences from the plan:

- **Pinning.** Pinned counters are a "Pinned" group in the browser for now; the Overview tab they were meant to feed is phase 2.
- **What the browser reads.** It reads the groups on screen plus the pinned counters' groups, once a second. The "what changes" pass reads everything twice, 1.5 s apart, when the browser opens and from the Check Again button.
- **Measured costs** (`--counters`, M1, 27.2):
  - Listing: Mach 0.5 ms, sysctl 32 ms (1,953 nodes in 80 groups), IOReport 119 ms (7,608 channels in 145 groups), IORegistry 43 ms (1,819 values in 13 groups).
  - Full reads: Mach 0.9 ms, sysctl 25 ms, IOReport 126 ms (including the first subscription), IORegistry 20 ms.
  - In total 11,460 counters, about 1,120–1,280 of them changing within 1–1.5 s. A browser tick on the PMP group reads in about 5 ms.
- **Units.** `HOST_EXPIRED_TASK_INFO` times are Mach absolute units, not ns: a 0.4 s spin reads 10 M, ×125/3 on M1. They are converted to ns, as are the 10 ms CPU ticks, so CPU time rates read as "cores".
- **Not decoded yet:** IOReport array channels (format 4) are listed but not decoded (none on this Mac). sysctl opaque structs other than loadavg, timeval, xsw_usage and clockinfo are left out.
- **UI check.** Checked in the Atlas helper: group list, values and rates, a state channel's detail, per-core energy as watts, and the graph. Typing into the toolbar search field couldn't be driven there: Atlas loses the app's windows once a SwiftUI toolbar search field has focus, the existing Processes search included. Search was checked through `--counters <filter>` only.

Phase 2 implemented 2026-11-18 (`UI/SystemOverview.swift`, `UI/Dashboards.swift`, sidebar System ▸ Overview), with all seven tabs. Differences and findings:

- **New catalog sources.** HID temperature sensors (57 on M1, ~45 ms per read, so read only while the Thermal tab is open) and per-interface network counters. The catalog is listed once and shared by the browser and the Overview.
- **Network counters were wrong.** `NET_RT_IFLIST2` cuts interface byte counts to 32 bits and rounds them to 1 KiB on 27.2 (en0: 1,952,969,728 against the exact 10,542,904,749). Interfaces are now read through the interface MIB (`IFMIB_IFDATA`), and so is the menu bar's network total (`SystemStats.netBytes`), which had the same bug.
- **Memory traffic.** AMC Stats per-agent channels include requests the system-level cache served: about 11 GB/s across agents against 4.5 GB/s at the DRAM controller (DCS). The dashboard shows DCS as "DRAM traffic" and the agents as "memory requests".
- **APFS volumes.** "Bytes read by user" includes reads the file cache served (Data: 89 MB/s while disk0 read 10 MB/s), so the Storage table shows it beside "from disk".
- **Linking.** Any metric's context menu has "Show in All Counters", which opens the browser on that counter. Power assertions open the process inspector.
- **Read cost per tick, once warm:** GPU tab ~7 ms; the first tick of a tab is slower (~190 ms) while its IOReport subscriptions are made.
- **Not done:** fans (SMC), per-protocol network stats (helper, phase 3), and the "top app at that moment" on graph hover.

Also done 2026-11-18, after phase 3:

- **Graph hover.** Hovering an Overview tile's graph shows the value at that point, how long ago, and the busiest app then: AmbientMonitor's top accounting group for the tile's metric (CPU for CPU, power and thermal tiles). While the Overview is open it keeps the monitor running for this.
- **Export Snapshot.** A toolbar button in All Counters, and `--counters --json`, save one reading of every counter as JSON (13,509 counters on M1).
- **LaunchWatcher leak (existing code).** For a user who isn't an admin, `log stream` exits at once (exit 77, "Must be admin"), and every 5 s restart leaked a reader thread, a pty and a `sh` (63 after a few minutes in a non-admin account). Fixed:
  - the script stops its lifeline watcher when the stream ends;
  - exit 77 stops the retries, and the inspector says why launches aren't traced;
  - other quick exits back off up to 10 minutes.
- **Cost.** Measured in a non-admin account: the Overview's CPU tab costs ~6.7 % of one core settled (`top` over 20 s), including the monitor and redrawing the panels each second.
- **Not investigated:** the launchd Jobs section burned ~70 s of CPU in its first ~80 s in that account, then settled to under 1 %.
- **Phase 4 (folding `SystemStats` into the catalog) left as is.** The menu bar's reader is a small, tuned subset (~1 ms) and works; moving it onto the catalog would change a working path for no visible gain.

Phase 3 implemented 2026-11-18 (`Sys/Counters/SMCCounters.swift`, `ProtocolCounters.swift`, `HelperCounters.swift`; helper call `systemCounters`, protocol version 18). Findings:

- **SMC, unprivileged.** The AppleSMC user client opens and reads without privileges: 1,607 of 1,644 keys on an M1 MacBook Air, grouped by first letter (T temperatures, P power, V voltages, I currents, F fans, B battery…).
  - Integer keys are little-endian on Apple silicon (B0CT reads 307 cycles so), but `#KEY` (the key count) is big-endian, and `flt ` is little-endian.
  - Listing costs ~250 ms. Reading a group costs per key (all 1,607 keys: ~370 ms), so only open groups are read.
  - The Thermal tab shows fans from F<n>Ac/Mn/Mx/Tg. They're untested with a real fan: this Mac is fanless and the VMs have no SMC fans.
- **Protocol stats.** TCP, UDP, IPv4, ICMP and mbuf stats are decoded with the SDK's structs through `Mirror`, so every field keeps its kernel name. The SDK struct sizes match the kernel's.
  - Unprivileged, only TCP reads as zeros; it comes from the helper.
  - `ip6stat` isn't in the SDK, so it's left out.
- **Kernel zones.** An unprivileged `mach_memory_info` returns zone names with every size 0. On the host-priv port as root it returns 650 zones, 186–266 MB.
- **SIP.** Measured as root with SIP off (`pxr-dev`) and with SIP on (`pxr-base`): TCP stats and zones read the same, so the helper path doesn't need SIP off.
- **Helper call.** `--helper-call counters` checks it; one call takes 4.4 ms in the VM.
- **Not done:** CPU performance counters (kpc). The VMs expose none (virtualized), so they can't be tested there, and they need care not to disturb other tools that own the counters.

## 1. Goal

A System section that shows the whole machine, not just its processes. It is not a copy of System Informer's System Information window. The aim is to surface every system-wide counter macOS exposes, on top of a few curated dashboards. macOS keeps thousands of counters in sysctl, Mach host statistics, IOReport, the IORegistry and the HID event system. Activity Monitor shows a few dozen of them, and the app today reads about fifteen (`SystemStats`, `ClusterStats`).

Two layers:

- **All Counters:** a browser over everything every source exposes, live, with the rate for each counter. It has search, a "changing only" filter, and lets you pin any counter to a graph.
- **Overview:** curated dashboards (CPU, Memory, Power, Thermal, Storage, Network, GPU). They are built from the same catalog, with friendly names, units, InfoBubbles and graphs.

The browser guarantees nothing is hidden. The dashboards make the useful part readable.

## 2. What macOS exposes (measured)

Measured on this Mac (M1, macOS 27.2, 26B131) as an unprivileged process, with throwaway probes. These counts set the scale.

| Source | Size | Changing within 1 s | Notes |
|---|---|---|---|
| sysctl (`sysctl -a`) | 1,777 named nodes | to measure | Mixes counters with tunables. Opaque struct nodes (`net.inet.tcp.stats`, `kern.ipc.mbstat`…) aren't listed by `-a` and need their structs decoded. |
| Mach host / processor set | ~8 flavors | all | `HOST_VM_INFO64`, `HOST_CPU_LOAD_INFO`, `PROCESSOR_CPU_LOAD_INFO`, `HOST_LOAD_INFO`, `HOST_EXPIRED_TASK_INFO`, `HOST_EXTMOD_INFO64`, `PROCESSOR_SET_LOAD_INFO` |
| IOReport (`IOReportCopyAllChannels`) | 7,608 channels in ~150 groups | ~1,100 | Simple (value + unit), state (residency per state) and histogram channels |
| IORegistry properties | `Statistics` on 24 objects, `PerformanceStatistics`, `PowerTelemetryData`, `BatteryData`, IOPMrootDomain | — | Block storage, APFS containers and volumes, Thunderbolt, GPU, battery, sleep/wake |
| HID event system | 57 temperature sensors | yes | Die, PMU, NAND and others, read via `IOHIDEventSystemClient` (private) |
| Interfaces | per interface | yes | `NET_RT_IFLIST2` 64-bit counters (already read, summed) |

### 2.1 Highlights the app doesn't use yet

- **sysctl `vm.*` (~250) and `vm.compressor.*` (~100).** Covers the page queues (free, speculative, throttled, wired, realtime, background, reusable) and the pageout scanner (inactive clean/dirty, shared-cache protection). The compressor side has segment counts, compaction, bytes in vs compressed (live compression ratio: 613 GB in → 218 GB out since boot), and the swapper: swap-outs and swap-ins by cause, plus *why* the swapper woke (`swap_threshold_exceeded`, `fragmentation_detected`, `thrashing_detected`…). Also code-signing blob totals, wire limits, and corpse footprints.
- **sysctl `kern.*`.** Covers boot time; last sleep and wake times; `kern.wakereason` ("trackpadkeyboard…"); `kern.shutdownreason` for the previous shutdown ("wdog,reset_in_1 ap_restart"); `kern.memorystatus_level` plus purge thresholds; timer-coalescing state; and entropy health tests. `vfs.vnstats.*` holds vnodes (free, recycled, dead), `kern.num_files` the open files, and `net.necp.*` the network policy and client counts.
- **`HOST_EXPIRED_TASK_INFO`.** CPU time and wakeups of every task that has *exited* since boot. With the live processes' totals, that gives "CPU since boot" that adds up, and it covers short-lived processes the list never sees.
- **`PROCESSOR_SET_LOAD_INFO`.** Task and thread counts (953 / 4,653) in one call.
- **IOReport `PMP` (unprivileged).** Energy in mJ per CPU cluster (ECPU, PCPU) and **per core** (ECORE0…, PCORE0…), DRAM, display, SoC (always-on and the rest), and the DRAM fabric. Per-agent DRAM bandwidth comes as state channels. `ClusterStats.swift` says CPU energy reads 0 unprivileged. That holds for the `Energy Model` group, but `PMP` has it.
- **IOReport `AMC Stats`.** Memory-controller bytes read and written **per agent**: P-cores, E-cores, GPU, SoC, display (internal and external), SSD controller (ANS2), PCIe, and the secure enclave (SBR). It also has DRAM CAS/RAS counts, self-refresh and power-down entries, and system-level-cache hits and misses by client (GPU render target, DART…).
- **IOReport `CPU Stats`.** Has `CPU Core Performance States` per core (per-core clocks, not just per cluster), `CPU Complex Voltage States`, and DVD states.
- **IOReport `Interrupt Statistics (by index)`.** 625 channels: first- and second-level handler counts and time per interrupt source. The names come from the channels' legend (`IOReportLegend` on the providers), to decode.
- **IOReport, storage and IO.** NVMe and ANS2 (SSD controller power states, sleep/wake counts, link states, AES bandwidth), PCIe link states and bandwidth per port, SMC sleep and wake counts.
- **IOReport, Wi-Fi and Bluetooth.** Tx retransmissions, Rx errors by kind, per-channel CCA (channel busy) and noise, channel switches and their reasons, BT coexistence antenna time, AWDL use, and Wi-Fi power states.
- **IOReport, the rest.** Display (DCP), audio codecs, AOP (always-on processor: sensor reports, wake reasons), HID transport errors and resets, and `SoC Stats` (CLK/PWR/EVT/DEV counters, names opaque).
- **`AppleSmartBattery` `PowerTelemetryData`.** Whole-machine power: `SystemPowerIn`, `SystemLoad` (mW), adapter efficiency loss, accumulated wall and system energy. Also cycle count, temperature, voltage, amperage and charger data.
- **IOPMrootDomain.** Last sleep reason, wake reason, sleep type. `IOPMCopyAssertionsByProcess` gives what's keeping the Mac awake, by process.
- **HID temperature sensors.** 57 on this Mac. Some read nonsense (`PMU tdev3` = −22 °C) and need filtering or labeling as raw.
- **mbufs** (`kern.ipc.mbstat`, what `netstat -m` shows): network buffer use, plus "requests for memory denied" (297 here).

### 2.2 Not readable unprivileged (helper candidates, to measure as root in `pxr-dev`)

- Per-protocol network stats (`net.inet.tcp.stats` and the rest: `netstat -s` prints all zeros unprivileged on 27.2).
- Kernel memory by zone (`mach_memory_info`, as `zprint`).
- System-wide PMCs (cycles and instructions per CPU through kpc; `kern.monotonic` has per-thread counting only).
- SMC keys for fans and the remaining sensors (AppleSMC user client). Check what's readable without root first.

## 3. Design

### 3.1 A counter catalog

One model for every source:

```swift
struct CounterID: Hashable { var source: SourceKind; var path: [String] }   // e.g. .ioreport ["PMP", "", "PCORE0"]
struct CounterInfo {
    var id: CounterID
    var name: String            // raw name as the source gives it
    var unit: Unit              // bytes, ns, mJ, MATU ticks, pages, count, °C, mW, none
    var kind: Kind              // cumulative counter, gauge, state residency, histogram, text
    var privilege: Privilege    // none, helper
}
protocol CounterSource {
    func enumerate() -> [CounterInfo]                       // once, plus on demand (interfaces and disks come and go)
    func sample(_ ids: Set<CounterID>) -> [CounterID: Value]  // only what's subscribed
}
```

Sources: `SysctlSource`, `MachHostSource`, `IOReportSource`, `IORegistrySource`, `HIDSensorSource`, `InterfaceSource`, `PowerSource` (assertions, sleep/wake) and `HelperSource` (the root-only ones over XPC).

- **Counter or setting.** A value that changed between two reads is a counter. A curated list marks the known gauges, and everything else in sysctl lands under a "Settings" filter, not hidden.
- **Curation is a table, not code.** A Swift table keyed by counter path gives a friendly name, unit, description and source note for the InfoBubble. Uncurated counters show their raw name and source. Labels follow "friendly phrase (Term)".
- **Rates.** Cumulative counters show the value since boot and the per-second rate over the last tick. State channels show the share of time per state. Histograms show buckets.

### 3.2 Sampling

- **Read only what's watched:** visible rows in the browser, pinned counters, and the open dashboard. IOReport subscriptions are rebuilt from the needed groups (`IOReportCopyChannelsInGroup`), as `ClusterReader` does today. Rebuild cost and full-subscription cost are to measure; the target is under 2 ms per tick with a dashboard open.
- **One clock.** The System view drives a `SystemSampler`. `AmbientMonitor` keeps sampling `SystemStats` for the menu bar, and in time `SystemStats` becomes a curated subset of the catalog rather than a separate reader.
- **History.** Ring buffers (no `removeFirst`) only for pinned and dashboard counters. Ten minutes at 1 s by default.

### 3.3 UI

A new sidebar section, **System**, with two modes:

- **Overview.** Tabs CPU · Memory · Power · Thermal · Storage · Network · GPU. Each has curated graphs and grids. Hovering a graph names the top app at that moment (from `topGroups`). Any value opens its counter in the browser.
- **All Counters.** An outline of Source ▸ group ▸ counter, with columns for value, rate/s, since boot, unit and source. It has search, a "changing only" filter (on by default: about 1,100 of 7,600 IOReport channels move), sorting by rate, and a detail pane with the counter's graph and description. "Pin" adds it to a Pinned tab on the Overview.

The curated dashboards, from the measured data:

| Tab | Content |
|---|---|
| CPU | per-core use (user vs kernel) and **per-core clock**, cluster voltage states, load averages, tasks and threads, interrupts per second by source, CPU time of exited processes |
| Memory | page queues as a stacked graph; faults, page-ins and page-outs, compressions, purges per second; compressor ratio and segments; swap-outs and swap-ins by cause and **swapper wake reasons**; memorystatus level and purge thresholds; **DRAM bandwidth by agent** |
| Power | **energy per core, cluster, DRAM, display, SoC, GPU** (W); whole-machine power in from the adapter; battery (charge, health, cycles, temperature, current); sleep assertions by process; sleep and wake history and reasons; previous shutdown reason |
| Thermal | thermal pressure, HID temperature sensors grouped (die, PMU, NAND, battery), fans once readable |
| Storage | per disk and per APFS container/volume statistics (ops, bytes, latency, errors), SSD controller power states, vnode and open-file counts |
| Network | per interface (bytes, packets, errors, drops), mbufs, NECP clients and flows, Wi-Fi radio (retransmissions, Rx errors, channel busy share, BT coexistence); per-protocol stats through the helper |
| GPU | use, renderer and tiler, clock, power, GPU memory, GPU share of DRAM bandwidth, system-level-cache hits |

## 4. Phases

1. **Catalog and browser.** The `CounterSource` protocol; sysctl, Mach host, IOReport (simple and state) and IORegistry sources; the All Counters browser with rates, search, "changing only" and the detail graph. This alone exposes everything readable unprivileged. Add `--counters` to dump the catalog with values for diffing between Macs.
2. **Overview dashboards:** CPU, Memory, Power first (they have the richest new data), then Thermal, Storage, Network, GPU, with the curation table growing alongside.
3. **Helper sources** (section 2.2), each measured as root in `pxr-dev` before shipping. For each one, record whether it also works with SIP on (`pxr-dev` has AMFI off too).
4. **Fold `SystemStats` into the catalog,** and fix the `ClusterStats.swift` comment about CPU energy.

## 5. Open questions

- **Per-chip channel names.** IOReport groups and channels differ by chip (M1 here: `AppleMCA2Cluster_T8103`, `PCPU`/`ECPU`; M4 adds `MCPU`, and `PMP` channel names may differ). Curated dashboards must match by pattern and show nothing rather than something wrong, as `ClusterStats` already does. This needs a check on at least one M3/M4 machine.
- **Opaque names:** `SoC Stats` (CLK001, PWR001…) and interrupt indices. Interrupts can probably be named from the legend. SoC Stats probably can't, and stays raw in the browser.
- **Units:** "MATUs" (mach absolute time units) in interrupt times need `mach_timebase_info`; some channels have no unit label.
- **Snapshots of all ~7,600 channels:** whether an "Export snapshot" action (all counters, as JSON) is worth having for comparing before/after.
