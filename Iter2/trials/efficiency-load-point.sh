#!/bin/bash
#
# efficiency-load-point.sh
#
# Parallel efficiency E of N container pairs for one offered-load data point,
# computed from PER-PAIR throughputs (each averaged over trials):
#
#   E = T_1 / (p * T_p) = p * G_1^-1 / sum_k(G_k^-1) = H / G_1
#
#   G_1 = baseline single-pair throughput (N = 1, 1 Gbit/s offered load)
#   G_k = throughput of pair k, averaged over all trials (cont<k>a column)
#   H   = harmonic mean of G_1..G_p of the N-pair run
#   p   = N
#
# (Derivation: T_1 = M / G_1; every pair moves M/p bytes at its own rate
#  G_k; p*T_p = sum_k (M/p) / G_k.  M cancels, the factor p stays.)
#
# Usage:
#   ./efficiency-load-point.sh <F> <L> <N> <baseline>
#
#   F        = folder containing throughput_summary.txt of the N-pair run
#   L        = offered load (Gbit/s) - passed through into the output line
#   N        = number of pairs (cont<i>a/cont<i>b) in that file
#   baseline = either a number (G_1, Gbit/s), or a folder holding the
#              throughput_summary.txt of the single-pair run (N = 1,
#              1 Gbit/s); then G_1 = mean of its cont1a column over trials
#
# throughput_summary.txt (whitespace-separated, first line = header, skipped):
#   trial  cont<i>a(Gbit/s) cont<i>b(Gbit/s)   for i = 1..N
# Only the cont<i>a columns are used (cont<i>b duplicates them).
#
# Output (stdout, one comma-separated line):
#   L,N,G_1,H,E

set -euo pipefail
export LC_ALL=C   # '.' as decimal separator for awk, whatever the system locale

USAGE="usage: $0 <data_folder> <offered_load> <num_pairs> <baseline_G1_or_folder>"
F="${1:?$USAGE}"
L="${2:?$USAGE}"
N="${3:?$USAGE}"
BASE="${4:?$USAGE}"

THR_FILE="${F}/throughput_summary.txt"
[ -f "$THR_FILE" ] || { echo "ERROR: $THR_FILE not found" >&2; exit 1; }
if ! [[ "$N" =~ ^[0-9]+$ ]] || [ "$N" -lt 1 ]; then
    echo "ERROR: N (pairs) must be a positive integer" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Baseline G_1: a number, or the trial-averaged cont1a of a single-pair run.
# ---------------------------------------------------------------------------
if [ -d "$BASE" ]; then
    BASE_FILE="${BASE}/throughput_summary.txt"
    [ -f "$BASE_FILE" ] || { echo "ERROR: $BASE_FILE not found" >&2; exit 1; }
    G1=$(awk '
        NR == 1 { next }
        NF == 0 { next }
        NF < 2  { print "ERROR: baseline row too short" > "/dev/stderr"; bad = 1; exit 1 }
        { s += $2; t++ }
        END {
            if (bad) exit 1
            if (t == 0) { print "ERROR: no data rows in baseline file" > "/dev/stderr"; exit 1 }
            printf "%.4f", s / t
        }
    ' "$BASE_FILE") || exit 1
elif [[ "$BASE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    G1=$(awk -v g="$BASE" 'BEGIN { printf "%.4f", g }')
else
    echo "ERROR: baseline must be a number or an existing folder: $BASE" >&2
    exit 1
fi
if ! awk -v g="$G1" 'BEGIN { exit !(g > 0) }'; then
    echo "ERROR: baseline G_1 must be > 0 (got $G1)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Per-pair trial averages G_k, harmonic mean H, efficiency E = H / G_1.
# ---------------------------------------------------------------------------
RESULT=$(awk -v n="$N" -v g1="$G1" '
    NR == 1 { next }                      # header
    NF == 0 { next }                      # blank lines
    NF < 1 + 2 * n {
        printf "ERROR: line %d has %d columns, need at least %d for N=%d\n", \
               NR, NF, 1 + 2 * n, n > "/dev/stderr"
        bad = 1; exit 1
    }
    {
        for (i = 1; i <= n; i++) s[i] += $(2 + (i - 1) * 2)   # cont<i>a
        t++
    }
    END {
        if (bad) exit 1
        if (t == 0) { print "ERROR: no data rows in throughput file" > "/dev/stderr"; exit 1 }
        inv = 0
        for (i = 1; i <= n; i++) {
            g = s[i] / t
            if (g <= 0) {
                printf "ERROR: pair %d has non-positive average throughput\n", i > "/dev/stderr"
                exit 1
            }
            inv += 1 / g
        }
        h = n / inv                       # harmonic mean of the G_k
        printf "%.4f %.4f", h, h / g1
    }
' "$THR_FILE") || exit 1

read -r H E <<< "$RESULT"
echo "${L},${N},${G1},${H},${E}"
