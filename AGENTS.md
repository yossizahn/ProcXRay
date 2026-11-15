# Notes for agents

## Building

`./build-app.sh` builds `build/Proc X-Ray Dev.app` (bundle id `local.procxray.dev`, its own helper and settings); `--release` builds `build/Proc X-Ray.app`, `--install` also replaces the copy in /Applications. It needs full Xcode, not the Command Line Tools. See the script's header.

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
- Syscall trace without the UI: `sudo ProcXRay --trace <pid> <seconds> [--ktrace] [out.tsv]` runs the kdebug reader (or ktrace) in-process with the app's decoder and writes the records for diffing the two; `ProcXRay --helper-call trace <pid> <seconds> [stacks]` goes through the installed helper over XPC (`stacks`: kperf user stacks, printed symbolicated with the top callers). Only the signed bundle can talk to the helper, not the raw `swift build` binary.
- `PROCXRAY_APPLE_TOOLS=1` in the environment of the process doing the reading forces Apple's tools instead of the native readers (`NativeTools.swift`), for comparing the two in the VM.
