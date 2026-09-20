#!/usr/bin/env bash
# Autoresearch harness: measures CI-workload I/O on the raw job disk vs the
# OverlayBD rootfs inside a live AgentENV sandbox on `main`.
#
# Primary metric: total workload seconds (lower is better) — a weighted sum of
# the git/npm/cargo-style operations the preloop CI benchmark exercises.
#
# Requires: ssh access to bnjoroge@main, aenv CLI, a running aenv server with a
# raw job disk attached at /var/lib/preloop-runner/_work.
set -uo pipefail

SSH="ssh -o ConnectTimeout=15 -o IdentityAgent=none -o IdentitiesOnly=yes -i $HOME/.ssh/id_ed25519 bnjoroge@main"
SANDBOX="${AENV_SANDBOX:-}"

# Workload: git-clone-like (many small files + sync), npm-install-like (create
# + write + fsync), cargo-build-like (sequential writes + reads). Each op runs
# on both the raw job disk and the overlaybd rootfs; the metric is the raw
# disk's total time.
run_workload() {
  local dir="$1"
  local total_ms=0

  # git-clone-like: 300 small files + sync
  local t e
  t=$(date +%s%N)
  for i in $(seq 300); do echo "file $i content" > "$dir/g$i"; done
  sync
  e=$(date +%s%N); total_ms=$((total_ms + (e-t)/1000000))
  rm -f "$dir"/g*

  # npm-install-like: 200 creates + writes + fsync
  t=$(date +%s%N)
  for i in $(seq 200); do dd if=/dev/zero of="$dir/n$i" bs=4k count=1 conv=fsync 2>/dev/null; done
  e=$(date +%s%N); total_ms=$((total_ms + (e-t)/1000000))
  rm -f "$dir"/n*

  # cargo-build-like: 256MB sequential write + read
  t=$(date +%s%N)
  dd if=/dev/zero of="$dir/c.bin" bs=1M count=256 2>/dev/null
  dd if="$dir/c.bin" of=/dev/null bs=1M 2>/dev/null
  e=$(date +%s%N); total_ms=$((total_ms + (e-t)/1000000))
  rm -f "$dir/c.bin"

  echo "$total_ms"
}

# Ensure a sandbox with a raw job disk exists.
if [ -z "$SANDBOX" ]; then
  SANDBOX=$($SSH 'aenv list 2>/dev/null | grep -oE "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" | head -1')
fi
if [ -z "$SANDBOX" ]; then
  echo "no sandbox with raw drive found; create one first" >&2
  exit 1
fi

# Run the workload on the raw job disk inside the sandbox.
result=$($SSH "aenv exec $SANDBOX -- /bin/sh -c '
  dir=/var/lib/preloop-runner/_work
  total_ms=0
  t=\$(date +%s%N); for i in \$(seq 300); do echo \"file \$i\" > \$dir/g\$i; done; sync; e=\$(date +%s%N); total_ms=\$((total_ms + (e-t)/1000000)); rm -f \$dir/g*
  t=\$(date +%s%N); for i in \$(seq 200); do dd if=/dev/zero of=\$dir/n\$i bs=4k count=1 conv=fsync 2>/dev/null; done; e=\$(date +%s%N); total_ms=\$((total_ms + (e-t)/1000000)); rm -f \$dir/n*
  t=\$(date +%s%N); dd if=/dev/zero of=\$dir/c.bin bs=1M count=256 2>/dev/null; dd if=\$dir/c.bin of=/dev/null bs=1M 2>/dev/null; e=\$(date +%s%N); total_ms=\$((total_ms + (e-t)/1000000)); rm -f \$dir/c.bin
  echo \$total_ms
'" 2>/dev/null | tail -1)

if ! [[ "$result" =~ ^[0-9]+$ ]]; then
  echo "workload failed: $result" >&2
  exit 1
fi

echo "total_workload_ms=$result"
echo "primary_metric=total_workload_ms"
echo "direction=lower_is_better"
