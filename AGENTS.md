# Notes for agents

## Building

`./build-app.sh` builds `build/Proc X-Ray Dev.app` (bundle id `local.procxray.dev`, its own helper and settings); `--release` builds `build/Proc X-Ray.app`, `--install` also replaces the copy in /Applications. It needs full Xcode, not the Command Line Tools. See the script's header.

## The dev helper

- Never install the helper from the Atlas login (or any second login). Atlas opens a copy of the bundle and deletes it afterwards, which leaves the helper's background-item record orphaned under "Unknown Developer": launchd logs "The specified path is not a bundle", unregistering fails with "record not found", and the user's own dev helper is blocked until `sudo sfltool resetbtm` and a restart (which resets every app's background items). Test helper-backed features in the user's login or in the VM.
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
- `PROCXRAY_APPLE_TOOLS=1` in the environment of the process doing the reading forces Apple's tools instead of the native readers (`NativeTools.swift`), for comparing the two in the VM.

## Profiling refresh ticks

- `ProcXRay --bench` times each stage of a refresh: the snapshot's per-process reads, a steady-state timer tick (`tick:` lines), and the table's tree build per grouping and column set (`nodes(…)`). Run the release build (`swift build -c release`, `.build/release/ProcXRay --bench`).
- `ProcXRay --bench-tick` loops steady-state snapshots for 15 s (`BENCH_NODES=Smart|Flat|…` loops the table's tree build instead, `BENCH_COLUMNS=all` with every column), to attach `sample` to. `sample` can't attach to processes on the host with SIP on; run the binary and `sample` as another user (the Atlas helper: `atlas job start`, `atlas run -- /usr/bin/sample <pid> 8 -file /tmp/x.txt`) or in the VM.
- A second login never puts windows on screen, so the app stops refreshing there as it does when hidden; `PROCXRAY_ASSUME_VISIBLE=1` in its environment (`atlas open --env …`) keeps it refreshing, for profiling the live app.
