#!/bin/bash

# ----------------------------------------------------------------------------
# ⚓ COMPONENT: revisions.sh
# 📜 PURPOSE: Lists pushed image revisions (kc<ver>-<NNNNN>) newest-first, joined
#             with their timestamp-commit tag and digest, so you can identify the
#             last-good build on a given Keycloak base and roll back to it when a
#             base-image bump breaks something.
# 🔗 RELATES: [[push.sh]], [[build.sh]], [[rollback.sh]], [[deploy.sh]]
# ⚡ FLOW: [./revisions.sh] -> [gcloud artifacts docker tags list] -> [group by digest]
# ----------------------------------------------------------------------------

set -e

# Registry coordinates — kept in sync with build.sh (single image, one repo).
PROJECT_ID="your-gcp-project-id"
REGION="your-region"
REPO_NAME="idp"
IMAGE_NAME="keycloak"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}"

echo "Revisions in ${REGISTRY}"
echo "(newest first — roll back with: ./rollback.sh <tag>)"
echo ""

# `value(tag,version)` emits one line per tag: "<tag-resource>\t<version-resource>".
# Multiple tags share a digest (version), so we group by digest to line up each
# monotonic revision with its timestamp-commit sibling.
gcloud artifacts docker tags list "${REGISTRY}" --format='value(tag,version)' 2>/dev/null \
  | python3 <<'PY'
import re, sys, collections

by_digest = collections.defaultdict(list)
for line in sys.stdin:
    parts = line.split()
    if not parts:
        continue
    tag = parts[0].rsplit("/", 1)[-1]
    ver = (parts[1] if len(parts) > 1 else "").rsplit("/", 1)[-1]
    by_digest[ver].append(tag)

rev_re = re.compile(r'^kc([0-9.]+)-([0-9]{5})$')
ts_re = re.compile(r'^[0-9]{14}-[0-9a-f]{7}$')

rows = []
for digest, tags in by_digest.items():
    rev = next((t for t in tags if rev_re.match(t)), None)
    if not rev:
        continue
    m = rev_re.match(rev)
    kcver, num = m.group(1), int(m.group(2))
    ts = next((t for t in tags if ts_re.match(t)), "")
    latest = "latest" in tags
    rows.append((num, kcver, rev, ts, digest, latest))

rows.sort(reverse=True)
if not rows:
    print("  (no kc<ver>-<NNNNN> revisions yet — push one with ./push.sh)")
else:
    print(f"  {'REV':>5}  {'KC BASE':<9}  {'ROLLBACK TAG':<16}  {'TIMESTAMP-COMMIT':<22}  {'DIGEST':<20}")
    for num, kcver, rev, ts, digest, latest in rows:
        mark = "  <- latest" if latest else ""
        print(f"  {num:05d}  {kcver:<9}  {rev:<16}  {ts:<22}  {digest[:19]}{mark}")
    print("")
    print("  To recover from a bad base bump: pick the highest REV whose KC BASE is")
    print("  the last-known-good version, then:  ./rollback.sh <ROLLBACK TAG>")
PY
