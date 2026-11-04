#!/bin/bash
#
# efficiency-sweep.sh
#
# Runs efficiency-load-point.sh over a whole series of run folders.
# Folders are taken from <parent> by glob pattern, sorted by name
# (= chronological, because the names contain a timestamp).
#
# Usage:
#   ./efficiency-sweep.sh <parent> <baseline_idx> <first_multi_idx> [pattern] [load_per_pair]
#
#   parent          directory holding the run folders
#   baseline_idx    1-based position of the N=1, 1 Gbit/s folder      (e.g. 3)
#   first_multi_idx 1-based position of the N=2 folder; the following
#                   folders are N=3, N=4, ...                          (e.g. 7)
#   pattern         glob for the run folders, default 'bench-*'
#   load_per_pair   offered load per pair in Gbit/s, default 1.0;
#                   the L column printed is N * load_per_pair
#
# Output (stdout, CSV with header): L,N,G_1,H,E
# The line for N=1 (the baseline folder against itself, E = 1) comes first.

set -euo pipefail
export LC_ALL=C

USAGE="usage: $0 <parent> <baseline_idx> <first_multi_idx> [pattern] [load_per_pair]"
PARENT="${1:?$USAGE}"
BIDX="${2:?$USAGE}"
MIDX="${3:?$USAGE}"
PATTERN="${4:-bench-*}"
LPP="${5:-1.0}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POINT="${HERE}/efficiency-load-point.sh"
[ -x "$POINT" ] || { echo "ERROR: $POINT not found or not executable" >&2; exit 1; }
[ -d "$PARENT" ] || { echo "ERROR: $PARENT is not a directory" >&2; exit 1; }

# sorted list of run folders
mapfile -t DIRS < <(find "$PARENT" -maxdepth 1 -mindepth 1 -type d -name "$PATTERN" | sort)
TOTAL=${#DIRS[@]}
echo "found $TOTAL folders matching '$PATTERN' in $PARENT" >&2
[ "$BIDX" -ge 1 ] && [ "$BIDX" -le "$TOTAL" ] || { echo "ERROR: baseline_idx out of range 1..$TOTAL" >&2; exit 1; }
[ "$MIDX" -ge 1 ] && [ "$MIDX" -le "$TOTAL" ] || { echo "ERROR: first_multi_idx out of range 1..$TOTAL" >&2; exit 1; }

BASE_DIR="${DIRS[$((BIDX - 1))]}"
echo "baseline (N=1): $BASE_DIR" >&2

echo "L,N,G_1,H,E"
L1=$(awk -v n=1 -v l="$LPP" 'BEGIN { printf "%g", n * l }')
"$POINT" "$BASE_DIR" "$L1" 1 "$BASE_DIR"

N=2
for ((i = MIDX - 1; i < TOTAL; i++)); do
    D="${DIRS[$i]}"
    echo "N=$N: $D" >&2
    L=$(awk -v n="$N" -v l="$LPP" 'BEGIN { printf "%g", n * l }')
    "$POINT" "$D" "$L" "$N" "$BASE_DIR"
    N=$((N + 1))
done
