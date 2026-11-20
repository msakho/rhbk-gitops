#!/usr/bin/env bash
# Moves both repositories (rhbk-gitops and its sibling rhbk-platform) to a new cluster: replaces
# the cluster base domain everywhere (hostnames, Vault route, Grafana route, docs) and, if given,
# the storage class and the cert-manager ClusterIssuer. Current values are read from the files,
# so the script can be run again for the next cluster. Nothing is committed: review with
# "git diff" in both repositories, then commit and push. Guide: docs/reconstruction.md.
#
# Usage: tools/change-cluster.sh <new apps domain> [storage class] [cluster issuer]
#   e.g. tools/change-cluster.sh apps.cluster-abcde.abcde.sandbox123.opentlc.com
set -euo pipefail

NEW_APPS=${1:?usage: $0 <new apps domain> [storage class] [cluster issuer]}
NEW_SC=${2:-}
NEW_ISSUER=${3:-}

GITOPS=$(cd "$(dirname "$0")/.." && pwd)
PLATFORM=$(cd "$GITOPS/../rhbk-platform" && pwd)

case $NEW_APPS in
  apps.*) ;;
  *) echo "the domain must start with 'apps.' (wildcard domain of the routes)" >&2; exit 1 ;;
esac

# Current values, read from the repositories.
OLD_HOST=$(sed -n 's/^  value: prod-rhbk\.//p' "$GITOPS/overlays/prod/patch-routes.yaml")
OLD_BASE=${OLD_HOST#apps.}
NEW_BASE=${NEW_APPS#apps.}
OLD_SC=$(sed -n 's/^ *storageClassName: //p' "$GITOPS/tools/postgresql/pvc.yaml")
OLD_ISSUER=$(sed -n '/issuerRef:/,/name:/s/^ *name: //p' "$GITOPS/overlays/prod/certificate.yaml")

[ -n "$OLD_BASE" ] || { echo "current domain not found in overlays/prod/patch-routes.yaml" >&2; exit 1; }

# Replaces a literal string in every tracked file of a repository that contains it.
replace() {  # repo old new
  local repo=$1 old=$2 new=$3 files
  files=$(git -C "$repo" grep -lF -- "$old" || true)
  [ -n "$files" ] || return 0
  (cd "$repo" && OLD="$old" NEW="$new" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' $files)
  echo "  $(basename "$repo"): $(echo "$files" | wc -l | tr -d ' ') file(s)"
}

echo "Domain: $OLD_BASE -> $NEW_BASE"
for r in "$GITOPS" "$PLATFORM"; do replace "$r" "$OLD_BASE" "$NEW_BASE"; done

if [ -n "$NEW_SC" ] && [ "$NEW_SC" != "$OLD_SC" ]; then
  echo "Storage class: $OLD_SC -> $NEW_SC"
  for r in "$GITOPS" "$PLATFORM"; do replace "$r" "$OLD_SC" "$NEW_SC"; done
fi

if [ -n "$NEW_ISSUER" ] && [ "$NEW_ISSUER" != "$OLD_ISSUER" ]; then
  echo "ClusterIssuer: $OLD_ISSUER -> $NEW_ISSUER"
  for r in "$GITOPS" "$PLATFORM"; do replace "$r" "$OLD_ISSUER" "$NEW_ISSUER"; done
fi

echo "Done. Review, then commit and push in both repositories:"
echo "  git -C $GITOPS diff --stat; git -C $PLATFORM diff --stat"
