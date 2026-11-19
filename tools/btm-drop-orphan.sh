#!/bin/bash
# Removes one orphaned daemon record from the background-items (BTM) store, instead of `sfltool resetbtm` + restart.
#   sudo tools/btm-drop-orphan.sh [identifier]       default: 16.local.procxray.dev.helper
#   tools/btm-drop-orphan.sh --dry-run [identifier]  no root needed: checks the record and writes nothing
# Orphaned means the daemon record's parent app record (2.<bundle id>) is gone, e.g. after the Atlas login registered
# the helper from a copy of the bundle it then deleted. launchd then fails every 10 s with "copy_bundle_path(<uuid>…)
# error 0x6f", and re-registering reuses the record, so the parent never comes back. Check with `sfltool dumpbtm`.
# The script refuses unless it finds exactly one such record and its parent is missing. It boots out the launchd job,
# keeps a backup of the store next to it (.bak-<date>), writes the store without that record, and SIGKILLs
# backgroundtaskmanagementd so it can't write its old in-memory copy back (launchd restarts it on demand).
# Afterwards run `ProcXRay --helper-register` from the bundle and approve it in System Settings > Login Items.
# The store is an undocumented NSKeyedArchiver plist (BackgroundItems-v18-<user uuid>.btm, macOS 27.2). To undo, copy
# the backup back over the store and `sudo killall -9 backgroundtaskmanagementd`.
set -euo pipefail

DRY=0
[[ "${1:-}" == --dry-run ]] && { DRY=1; shift; }
ID="${1:-16.local.procxray.dev.helper}"
D=${BTM_DIR:-/private/var/db/com.apple.backgroundtaskmanagement}   # BTM_DIR: a copy, for testing
(( DRY )) || [[ $EUID -eq 0 ]] || { echo "run with sudo (or --dry-run)" >&2; exit 1; }

# Prints the store's records in "identifier<TAB>parent app identifier" form; parent is empty for non-daemons.
records() {
  /usr/bin/python3 -I -c '
import plistlib, sys
o = plistlib.load(open(sys.argv[1], "rb"))["$objects"]
U = lambda x: x.data if isinstance(x, plistlib.UID) else x
for r in o[U(o[1]["records"])]["NS.objects"]:
    rec = o[U(r)]; ids = o[U(rec["associatedBundleIdentifiers"])] if "associatedBundleIdentifiers" in rec else None
    bundles = [o[U(b)] for b in ids["NS.objects"]] if isinstance(ids, dict) else []
    print(o[U(rec["identifier"])], "2." + bundles[0] if bundles else "", sep="\t")
' "$1"
}

STORE=""
for f in "$D"/BackgroundItems-v18-*-*.btm; do
  recs=$(records "$f")
  n=$(awk -F'\t' -v id="$ID" '$1 == id' <<<"$recs" | wc -l | tr -d ' ')
  (( n == 0 )) && continue
  (( n == 1 )) || { echo "$f: $n records named $ID, refusing" >&2; exit 1; }
  parent=$(awk -F'\t' -v id="$ID" '$1 == id { print $2 }' <<<"$recs")
  [[ -n "$parent" ]] || { echo "$f: $ID has no associated bundle, refusing" >&2; exit 1; }
  if awk -F'\t' -v p="$parent" '$1 == p { found = 1 } END { exit !found }' <<<"$recs"; then
    echo "$f: $ID has its parent $parent; not orphaned"
    continue
  fi
  [[ -z "$STORE" ]] || { echo "orphaned $ID in more than one store, refusing" >&2; exit 1; }
  STORE=$f
done
[[ -n "$STORE" ]] || { echo "no orphaned $ID found"; exit 0; }
echo "orphaned: $ID (parent missing) in $STORE"
(( DRY )) && exit 0

launchctl bootout "system/${ID#*.}" 2>/dev/null || true
BAK="$STORE.bak-$(date +%Y%m%d%H%M%S)"
cp -p "$STORE" "$BAK"
/usr/bin/python3 -I -c '
import plistlib, sys
src, dst, ident = sys.argv[1:4]
p = plistlib.load(open(src, "rb")); o = p["$objects"]
U = lambda x: x.data if isinstance(x, plistlib.UID) else x
recs = o[U(o[1]["records"])]["NS.objects"]
hits = [r for r in recs if o[U(o[U(r)]["identifier"])] == ident]
assert len(hits) == 1, hits
recs.remove(hits[0])
plistlib.dump(p, open(dst, "wb"), fmt=plistlib.FMT_BINARY)
' "$STORE" "$STORE.new" "$ID"
chown root:wheel "$STORE.new"; chmod 644 "$STORE.new"
mv "$STORE.new" "$STORE"
killall -9 backgroundtaskmanagementd
echo "dropped $ID; backup: $BAK"
