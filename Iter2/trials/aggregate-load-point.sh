#!/bin/bash
#
# aggregate-load-point.sh
#
# Averages latency_summary.txt and throughput_summary.txt (as produced by
# the earlier benchmark scripts) for a single offered-load data point, and
# prints one summary line.
#
# Usage:
#   ./aggregate-load-point.sh <F> <L> <N>
#
#   F = folder containing latency_summary.txt and throughput_summary.txt
#   L = offered load (Gbit/s) - passed through verbatim into the output
#       line as a label; not read from the data files
#   N = number of pairs (cont<i>a/cont<i>b) present in both files
#
# Input file formats (whitespace-separated, first line = header, skipped):
#
#   latency_summary.txt:
#     trial  pair<i>_min(ms) pair<i>_mean(ms) pair<i>_max(ms) pair<i>_loss(pct)   for i=1..N
#
#   throughput_summary.txt:
#     trial  cont<i>a(Gbit/s) cont<i>b(Gbit/s)   for i=1..N
#
# Calculation:
#   Latency  - for each pair, average min/mean/max separately over all
#              trials; then average each of those three per-pair averages
#              over all N pairs -> one overall min, mean, max.
#   Throughput - for each pair, average cont<i>a over all trials (cont<i>b
#              is ignored - it duplicates cont<i>a for the same flow);
#              then SUM (not average) those N per-pair averages, giving
#              one aggregate throughput across all pairs.
#
# Output (stdout, one comma-separated line):
#   L,N,latency_min,latency_mean,latency_max,throughput_aggregated

set -euo pipefail
export LC_ALL=C   # force '.' as decimal separator for awk parsing/printf,
                   # regardless of the system locale (otherwise a locale
                   # using ',' as decimal separator breaks both numeric
                   # parsing of the input files and the output formatting)

F="${1:?usage: $0 <data_folder> <offered_load> <num_pairs>}"
L="${2:?usage: $0 <data_folder> <offered_load> <num_pairs>}"
N="${3:?usage: $0 <data_folder> <offered_load> <num_pairs>}"

LAT_FILE="${F}/latency_summary.txt"
THR_FILE="${F}/throughput_summary.txt"

[ -f "$LAT_FILE" ] || { echo "ERROR: $LAT_FILE not found" >&2; exit 1; }
[ -f "$THR_FILE" ] || { echo "ERROR: $THR_FILE not found" >&2; exit 1; }
if ! [[ "$N" =~ ^[0-9]+$ ]] || [ "$N" -lt 1 ]; then
    echo "ERROR: N (pairs) must be a positive integer" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Latency: per-pair average of min/mean/max over trials, then average those
# per-pair averages over all N pairs.
# ---------------------------------------------------------------------------
LAT_RESULT=$(awk -v n="$N" '
    NR == 1 { next }   # skip header
    NF == 0 { next }   # skip blank lines
    {
        # columns: $1=trial, then 4 columns per pair starting at $2:
        #   pair<i>_min, pair<i>_mean, pair<i>_max, pair<i>_loss
        for (i = 1; i <= n; i++) {
            base = 2 + (i - 1) * 4
            min_sum[i]  += $(base)
            mean_sum[i] += $(base + 1)
            max_sum[i]  += $(base + 2)
        }
        trials++
    }
    END {
        if (trials == 0) {
            print "ERROR: no data rows in latency file" > "/dev/stderr"
            exit 1
        }
        min_total = 0; mean_total = 0; max_total = 0
        for (i = 1; i <= n; i++) {
            min_total  += min_sum[i]  / trials
            mean_total += mean_sum[i] / trials
            max_total  += max_sum[i]  / trials
        }
        printf "%.4f %.4f %.4f", min_total / n, mean_total / n, max_total / n
    }
' "$LAT_FILE") || { echo "ERROR: failed to compute latency averages" >&2; exit 1; }

read -r LAT_MIN LAT_MEAN LAT_MAX <<< "$LAT_RESULT"

# ---------------------------------------------------------------------------
# Throughput: per-pair average of cont<i>a over trials, then SUM those
# per-pair averages over all N pairs (cont<i>b columns are ignored - same
# flow, same reported rate as cont<i>a).
# ---------------------------------------------------------------------------
THR_RESULT=$(awk -v n="$N" '
    NR == 1 { next }
    NF == 0 { next }
    {
        # columns: $1=trial, then 2 columns per pair starting at $2:
        #   cont<i>a, cont<i>b - only the "a" column (base) is used
        for (i = 1; i <= n; i++) {
            base = 2 + (i - 1) * 2
            a_sum[i] += $(base)
        }
        trials++
    }
    END {
        if (trials == 0) {
            print "ERROR: no data rows in throughput file" > "/dev/stderr"
            exit 1
        }
        total = 0
        for (i = 1; i <= n; i++) {
            total += a_sum[i] / trials
        }
        printf "%.4f", total
    }
' "$THR_FILE") || { echo "ERROR: failed to compute throughput aggregate" >&2; exit 1; }

echo "${L},${N},${LAT_MIN},${LAT_MEAN},${LAT_MAX},${THR_RESULT}"
