# Notes for agents

## Building

`./build-app.sh` builds `build/Proc X-Ray Dev.app` (bundle id `local.procxray.dev`, its own helper and settings); `--release` builds `build/Proc X-Ray.app`, `--install` also replaces the copy in /Applications. It needs full Xcode, not the Command Line Tools. See the script's header.

## The dev helper

- Never install the helper from the Atlas login (or any second login). Atlas opens a copy of the bundle and deletes it afterwards, which leaves the helper's background-item record orphaned: the daemon record `16.local.procxray.dev.helper` stays in the global store but its parent app record `2.local.procxray.dev` is gone, so launchd fails every 10 s with "copy_bundle_path(<uuid>…) error 0x6f", unregistering fails with "record not found", and re-registering reuses the broken record. Test helper-backed features in the user's login or in the VM.
- To recover, have the user run `sudo tools/btm-drop-orphan.sh` (`--dry-run` first, no root, to confirm the orphan), then `--helper-register` and approve it in System Settings > Login Items & Extensions. It removes only that record, with a backup; don't reach for `sfltool resetbtm`, which needs a restart and resets every app's background items.
- `ProcXRay --helper-register` / `--helper-unregister`, run from inside the bundle, register or remove the helper without the UI.

## Test VM (Tart): root, SIP off

The host Mac runs with SIP on and has no passwordless sudo, so anything that needs root on demand, or SIP off (task ports for the native readers, `task_for_pid`, kdebug benchmarks), is tested in a Tart VM.

- `pxr-dev`: the VM to use. macOS 27.2 (26B123), arm64, 4 CPUs, 4 GB, 1440×900, cloned from `ghcr.io/cirruslabs/macos-golden-gate-vanilla:27.2` (user `admin`, password `admin`). `admin` has passwordless sudo (`/etc/sudoers.d`).
- **SIP is disabled** in `pxr-dev` (`csrutil status` → disabled), and the boot args are `amfi_get_out_of_my_way=1`, so **AMFI is off too**. A result measured there with SIP off has also had AMFI off; a user who only turned SIP off may see something different.
- `pxr-base`: a second local VM from the same image, normally stopped. Check `csrutil status` in it before relying on its SIP state.
- No Xcode in the VM: build on the host, copy the bundle in.

To turn SIP off in a fresh clone: `tart run --recovery <vm>`, open Terminal from the Utilities menu in recoveryOS, run `csrutil disable` (and `nvram boot-args="amfi_get_out_of_my_way=1"` to match `pxr-dev`), then reboot with a plain `tart run`.

### Running and reaching it

- Start: `tart run pxr-dev --dir=build:$PWD/build` (shares `build/` at `/Volumes/My Shared Files/build`). Don't run the app from the shared folder: after a rebuild the guest keeps serving the old bundle's directories, so the signature breaks and the helper fails to register (-67023). Copy it with `tools/vm-deploy.sh` instead.
- SSH: key at `~/.tart/ssh_key` (one-time setup in the header of `tools/vm-deploy.sh`), then `ssh -i ~/.tart/ssh_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@$(tart ip pxr-dev)`.
- Deploy and launch a build: `./build-app.sh && tools/vm-deploy.sh` (`--release` for the release bundle, a VM name as the last argument for another VM).
- One-off test binaries (C or Swift) build on the host and run in the VM: `scp` them over, or `cat bin | ssh … 'cat > /tmp/bin && chmod +x /tmp/bin'`. Both are arm64 macOS 27.2, so host builds run as is.
- Syscall trace without the UI: `sudo ProcXRay --trace <pid> <seconds> [--ktrace] [--activity] [out.tsv]` runs the kdebug reader (or ktrace) in-process with the app's decoder and writes the records for diffing the two (`--activity` prints the Activity view's grouping, Mach message destinations named); `ProcXRay --helper-call trace <pid> <seconds> [stacks] [activity]` goes through the installed helper over XPC (`stacks`: kperf user stacks, printed symbolicated with the top callers; `activity`: the Activity grouping, as the app builds it). Only the signed bundle can talk to the helper, not the raw `swift build` binary.
- `ProcXRay --automation <app.app>… [-v]` prints what the Automation tab reads for each bundle (scripting dictionary, Shortcuts actions from the index and the bundle, SiriKit intents), without the UI.
- `ProcXRay --explore <pid> [depth]` walks an app's AppleScript objects (the Automation tab's explorer) without the UI. TCC charges Apple Events sent from an SSH session to `sshd-session`, not the app, so in the VM run it through `open -W -n --stdout /tmp/x --stderr /tmp/x "/Applications/Proc X-Ray Dev.app" --args --explore <pid>`, after inserting a `kTCCServiceAppleEvents` row for `local.procxray.dev` (with the target's bundle id as `indirect_object_identifier`) into the user TCC.db (path: `sudo lsof -c tccd`) and `killall tccd`. `PROCXRAY_EXPLORE=<pid>` opens the explorer window at launch, and `PROCXRAY_EXPLORE_PNG=<file>` then expands a little and captures the window to a PNG with ScreenCaptureKit (`screencapture` over SSH can't, and `cacheDisplay` doesn't draw SwiftUI). That needs a `kTCCServiceScreenCapture` row for `local.procxray.dev` in the system TCC.db (`/Library/Application Support/com.apple.TCC/TCC.db`).
- `PROCXRAY_APPLE_TOOLS=1` in the environment of the process doing the reading forces Apple's tools instead of the native readers (`NativeTools.swift`), for comparing the two in the VM.

## Resource budgets

The app is held to budgets for what it costs to run, measured on the running bundle, its helper and the tools they start:

- `swiftc -O tools/perf.swift -o build/perf && build/perf [--dev | --release] [--after 60] [--seconds 60] [--budget open|menubar]` prints total CPU, wake-ups, tools spawned and footprint against the budget, and exits 1 when one is over. `open`: main window in front. `menubar`: every window closed. `--after` leaves the launch out. It reads the app's rusage, so it runs as the app's user (in the Atlas helper: copy it in and `atlas run -- pxr-perf …`; in the VM: `scp` it over).
- `PROCXRAY_PERF=<file>` in the app's environment appends each refresh stage's CPU time to the file every 30 s (`PerfStages`): which stage is over, and whether it ran on the main thread.
- `ProcXRay --helper-call metrics` (signed bundle, helper running) compares what a timer refresh asks the helper for with the full reading, and gives the helper's CPU per call for each.
- `PROCXRAY_SETTINGS=<tab>` (`general`, `performance`, `helper`, `menuBar`, `alerts`) opens Settings on that tab at launch, for a screenshot without a click.
- In the VM nothing can click or take a screenshot. `PROCXRAY_INSPECT=<pid or name>` opens an inspector at launch (on the tab in the `inspectorTab` default), `PROCXRAY_AUTORUN=1` starts the Syscalls trace or the Logs query as its tab appears, and `PROCXRAY_WINDOW_PNG=<file>` writes a picture of the newest window there after `PROCXRAY_WINDOW_PNG_AFTER` seconds (default 15; needs the Screen Recording row described below). `open --env NAME=VALUE … '/Applications/Proc X-Ray Dev.app'` passes them.

Rules the measurements led to:

- Anything that costs CPU, memory or energy to keep up to date has a setting in `Tuning.swift` (Settings ▸ Performance), not a constant where it is used. The samplers ask `Tuning` how often to run.
- The refresh's background task builds everything, the table's tree included (`TreeBuilder`, from a `TableContext`): the main thread swaps results in. Column values and the tree read a `TableContext`, never the `Store`.
- A timer refresh starts no tool. launchd's jobs come from ServiceManagement in-process; `lsappinfo` and `launchctl print` run only when something changed (see `Store.refresh` and `fillPidDomains`).
- A background read that can fail for good caches the failure (`.some(nil)`), or it is retried on every refresh. The same goes for what a snapshot finds unset or unreadable: it is asked for again every 30th refresh, not every one.
- A timer refresh reads a process that used no CPU at its last reading only every Nth time (`Tuning.idleEvery`); the process keeps its figures and its sample in between. Anything a snapshot works out for every process must also be right for one taken over unread (see the `skip` branch in `Store.snapshot`).
- Tree rows and group-member lists hold processes as `ProcBox` references: a `ProcInfo` is ~1.5 KB with dozens of strings, and copying it per row move was a large part of a tree build.
- The menu bar monitor reads the processes on every Nth reading while nothing shows them (`Tuning.menuBarProcesses`), and the per-process network reader runs at the pace of whoever shows its figures (`NetPace`), not on a fixed 2 s.
- A SwiftUI form re-evaluates every control when anything its body reads changes: a value that updates on a timer (the Performance tab's cost readout) goes in a view of its own.
- Measuring in the Atlas login: its user isn't an admin, so the helper gives it figures for its own processes only, and the helper share measured there is not what an admin user sees (use the VM for that). `PROCXRAY_ASSUME_VISIBLE` keeps the list refreshing but doesn't make the app count as in front. Save panels take no input there, and the menu bar popover closes as soon as it opens under automated clicks.
- `for x in` over an array or dictionary of large structs (`ProcInfo`, `AmbientProc`, `AmbientGroup`) copies each element, retaining every string in it: to read a field or two of each, go by index. That copying was half of the menu bar monitor's time.
- No `beginUpdates`/`endUpdates` on a table when nothing structural changed: AppKit rebuilds the header's views for an empty transaction.
- Whole-app numbers move by a point or more with machine load. To compare two builds, measure them in turns (old, new, old, new) or use `ProcXRay --bench` (release build), which gives CPU time per stage: `tick: snapshot…` and `nodes(…)` lines.

## Shared UI components

- Rows of data go in `DataTable` (AppKit, `UI/DataTable.swift`): selection, keyboard navigation, type-to-jump, sort, column show/hide, ⌘C, copy cell / rows / with headers and CSV/TSV export come with it. Row actions go in its context menu and on double-click (`onOpen`), not in buttons inside cells. A cell is text, with an optional state dot, SF Symbol or bar before it. A table too big to sort on the main thread hands sorting to its owner (`sort:`), a column that doesn't apply right now is listed in `hiddenColumns`, `copyText` replaces the tab-separated copy, and `followsEnd` keeps the newest row in view. No SwiftUI `Table` is left in the app.
- Small graphs of recent readings are `SeriesGraphView` (`MiniGraph`, `MirrorGraph` wrap it). Only the menu bar label, which is rendered to an image, draws its own.
- Histories are `SeriesRing`s (`History`, `ProcHistory`).
- A setting's explanation is a `Hint`.
- New and timer-updated UI is AppKit, wrapped where a SwiftUI screen hosts it.

## Profiling refresh ticks

- `ProcXRay --bench` times each stage of a refresh: the snapshot's per-process reads, a steady-state timer tick (`tick:` lines), and the table's tree build per grouping and column set (`nodes(…)`). Run the release build (`swift build -c release`, `.build/release/ProcXRay --bench`).
- `ProcXRay --bench-tick` loops steady-state snapshots for 15 s (`BENCH_NODES=Smart|Flat|…` loops the table's tree build instead, `BENCH_COLUMNS=all` with every column), to attach `sample` to. `sample` can't attach to processes on the host with SIP on; run the binary and `sample` as another user (the Atlas helper: `atlas job start`, `atlas run -- /usr/bin/sample <pid> 8 -file /tmp/x.txt`) or in the VM.
- A second login never puts windows on screen, so the app stops refreshing there as it does when hidden; `PROCXRAY_ASSUME_VISIBLE=1` in its environment (`atlas open --env …`) keeps it refreshing, for profiling the live app.
