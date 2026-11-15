#!/bin/bash
# Copies a build into a Tart VM's /Applications and launches it there.
#   tools/vm-deploy.sh [--release] [vm]     default vm: pxr-dev
# Not run from the VM's shared folder: after build-app.sh recreates the bundle, the guest's virtiofs mount keeps
# serving the old directories (an empty _CodeSignature), so the helper fails to register with -67023; and
# SMAppService ties the helper registration to the bundle's path.
# One-time key setup: ssh-keygen -t ed25519 -N "" -f ~/.tart/ssh_key && ssh-copy-id -i ~/.tart/ssh_key admin@$(tart ip pxr-dev)
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Proc X-Ray Dev"
case "${1:-}" in
  --release) NAME="Proc X-Ray"; shift ;;
esac
VM="${1:-pxr-dev}"
APP="build/$NAME.app"
[[ -d "$APP" ]] || { echo "no $APP: run ./build-app.sh first" >&2; exit 1; }

SSH=(ssh -i ~/.tart/ssh_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "admin@$(tart ip "$VM")")
"${SSH[@]}" "pkill -U admin -x ProcXRay; sleep 1; rm -rf '/Applications/$NAME.app'" || true
tar -C build -cf - "$NAME.app" | "${SSH[@]}" "tar -C /Applications -xf - && codesign --verify --strict '/Applications/$NAME.app' && open '/Applications/$NAME.app'"
echo "deployed $NAME to $VM"
