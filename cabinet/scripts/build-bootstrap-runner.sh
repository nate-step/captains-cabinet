#!/bin/bash
# build-bootstrap-runner.sh — Build the cabinet-bootstrap-runner image (FW-085 Path A)
#
# Path A architecture (Captain msg 2281): bootstrap-runner is a privileged
# ephemeral container with docker-cli + psql, used ONLY when cabinet-bootstrap.sh
# needs container-engine ops from a context that lacks docker. Officer image
# stays clean (no docker-cli, no socket mount).
#
# Idempotent: if image exists and Dockerfile.bootstrap-runner SHA hasn't changed,
# skip rebuild. Force-rebuild via --force.
#
# Usage:
#   bash cabinet/scripts/build-bootstrap-runner.sh           # idempotent build
#   bash cabinet/scripts/build-bootstrap-runner.sh --force   # always rebuild

set -euo pipefail

CABINET_ROOT="${CABINET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DOCKERFILE="$CABINET_ROOT/cabinet/Dockerfile.bootstrap-runner"
IMAGE_TAG="cabinet-bootstrap-runner:latest"

FORCE=0
for arg in "$@"; do
  [ "$arg" = "--force" ] && FORCE=1
done

if [ ! -f "$DOCKERFILE" ]; then
  echo "ERROR: $DOCKERFILE not found" >&2
  echo "  Captain action required: apply Dockerfile staged at /tmp/fw085-bootstrap-runner.dockerfile-content" >&2
  echo "  to $DOCKERFILE before running this script (FW-085 Path A — Captain msg 2281)." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker CLI not in PATH — cannot build bootstrap-runner image" >&2
  echo "  This script is host-side. Run from a context with docker installed." >&2
  exit 1
fi

# Compute Dockerfile SHA, compare against image label if exists.
EXPECTED_SHA=$(sha256sum "$DOCKERFILE" | awk '{print $1}')

if [ "$FORCE" = "0" ] && docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  CURRENT_SHA=$(docker image inspect "$IMAGE_TAG" --format '{{ index .Config.Labels "dockerfile_sha" }}' 2>/dev/null || echo "")
  if [ "$CURRENT_SHA" = "$EXPECTED_SHA" ]; then
    echo "[build-bootstrap-runner] $IMAGE_TAG is up-to-date (SHA=$EXPECTED_SHA)"
    exit 0
  fi
  echo "[build-bootstrap-runner] $IMAGE_TAG SHA mismatch — rebuilding"
fi

echo "[build-bootstrap-runner] Building $IMAGE_TAG from $DOCKERFILE"
docker build \
  -f "$DOCKERFILE" \
  -t "$IMAGE_TAG" \
  --label "dockerfile_sha=$EXPECTED_SHA" \
  --label "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$CABINET_ROOT/cabinet"

echo "[build-bootstrap-runner] Built $IMAGE_TAG (SHA=$EXPECTED_SHA)"
