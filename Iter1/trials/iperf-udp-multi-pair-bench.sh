#!/bin/bash
#
# iperf-udp-multi-pair-bench.sh
#
# For N container pairs (cont<i>a/cont<i>b, matching the OVS/OpenSDN pair
# naming and 10.1.<i>.11/10.1.<i>.22 addressing convention - so this
# script works unmodified against containers from either dataplane) and
# M trials:
#   1) starts a persistent legacy iperf UDP server in each cont<i>b on
#      the given port;
#   2) runs M trials; each trial launches iperf UDP clients in every
#      cont<i>a concurrently (each connecting to its own cont<i>b), and
#      waits for all of them to finish before starting the next trial;
#   3) every server's and every client's raw output goes to its own file
#      under OUTPUT_DIR;
#   4) combines everything into one table: rows = trials, columns =
#      cont<i>a/cont<i>b, values in Gbit/s, each container's own
#      self-reported rate (client reports what it sent, server reports
#      what it received).
#
# Uses legacy `iperf` (v2), not iperf3: v2's UDP mode has no separate
# TCP control channel, so it needs no extra flow rules beyond the UDP
# fat-flow/OVS rule already installed for the test port.
#
# Usage:
#   ./iperf-udp-multi-pair-bench.sh <N> <M> [duration_sec] [load_gbps] [port] [output_dir]
#
# duration_sec = length of each client's iperf session, in seconds (default 10)
# load_gbps    = target send rate per client, in Gbit/s - a plain number,
#                e.g. 0.5 for 500 Mbit/s, 1 for 1 Gbit/s, 2.5 for 2.5 Gbit/s
#                (default 1). Converted internally to iperf's "-b <n>G".
#
# Example: 4 pairs, 5 trials, 10s sessions, 0.5 Gbit/s target load each
#   ./iperf-udp-multi-pair-bench.sh 4 5 10 0.5

set -uo pipefail
export LC_ALL=C

N="${1:?number of pairs required}"
M="${2:?number of trials required}"
DURATION="${3:-10}"
LOAD_GBPS="${4:-1}"
PORT="${5:-25600}"
OUTPUT_DIR="${6:-./iperf-bench-results-$(date +%Y%m%d-%H%M%S)}"

if ! [[ "$N" =~ ^[0-9]+$ ]] || [ "$N" -lt 1 ]; then
    echo "ERROR: N (pairs) must be a positive integer" >&2; exit 1
fi
if ! [[ "$M" =~ ^[0-9]+$ ]] || [ "$M" -lt 1 ]; then
    echo "ERROR: M (trials) must be a positive integer" >&2; exit 1
fi
if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [ "$DURATION" -lt 1 ]; then
    echo "ERROR: duration_sec must be a positive integer" >&2; exit 1
fi
if ! [[ "$LOAD_GBPS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "ERROR: load_gbps must be a positive number (e.g. 0.5, 1, 2.5)" >&2; exit 1
fi
BW="${LOAD_GBPS}G"

mkdir -p "$OUTPUT_DIR"
echo "== N=$N pairs, M=$M trials, duration=${DURATION}s, load=${LOAD_GBPS} Gbit/s per client, port=$PORT =="
echo "== Output directory: $OUTPUT_DIR =="

CONT_SRV_LOG="/tmp/iperf_srv_bench.log"
CONT_SRV_PID="/tmp/iperf_srv_bench.pid"
CONT_CLI_LOG="/tmp/iperf_cli_bench.log"

contA() { echo "cont${1}a"; }
contB() { echo "cont${1}b"; }
ipB()   { echo "10.1.${1}.22"; }

# ---------------------------------------------------------------------------
# Step 1: start a persistent iperf UDP server in every cont<i>b. Any
# leftover server from a previous run of this script is killed first
# (via its own pidfile - no reliance on pkill/ps, which may not be
# installed in a minimal image).
# ---------------------------------------------------------------------------
echo "== Starting iperf servers (UDP port $PORT) on $N pair(s) =="
for i in $(seq 1 "$N"); do
    CB="$(contB "$i")"
    docker exec "$CB" sh -c "
        [ -f $CONT_SRV_PID ] && kill \$(cat $CONT_SRV_PID) 2>/dev/null
        rm -f $CONT_SRV_LOG $CONT_SRV_PID
        true
    "
    docker exec -d "$CB" sh -c "
        stdbuf -oL -eL iperf -s -u -p $PORT > $CONT_SRV_LOG 2>&1 &
        echo \$! > $CONT_SRV_PID
        wait
    "
    echo "   $CB listening"
done

sleep 0.5

# ---------------------------------------------------------------------------
# Step 2: M trials, N concurrent clients per trial. Each trial's client
# runs write to their own per-trial file inside the container, so trials
# never clobber each other.
# ---------------------------------------------------------------------------
for k in $(seq 1 "$M"); do
    echo "== Trial $k/$M: starting $N client(s) =="
    PIDS=()
    for i in $(seq 1 "$N"); do
        CA="$(contA "$i")"
        IB="$(ipB "$i")"
        docker exec "$CA" sh -c "stdbuf -oL -eL iperf -c $IB -u -p $PORT -b $BW -t $DURATION > ${CONT_CLI_LOG}.trial${k} 2>&1" &
        PIDS+=("$!")
    done
    for pid in "${PIDS[@]}"; do
        wait "$pid"
    done
    for i in $(seq 1 "$N"); do
        CA="$(contA "$i")"
        docker exec "$CA" cat "${CONT_CLI_LOG}.trial${k}" > "${OUTPUT_DIR}/client_${CA}_trial${k}.log" 2>/dev/null
    done

    # --- diagnostics: confirm each server is still alive, and snapshot
    # its log as it stands right after this trial (separate from the
    # final end-of-run collection) - lets us tell "data arrived then got
    # lost" apart from "data never arrived" if trials go missing again.
    for i in $(seq 1 "$N"); do
        CB="$(contB "$i")"
        ALIVE="dead"
        docker exec "$CB" sh -c "[ -f $CONT_SRV_PID ] && kill -0 \$(cat $CONT_SRV_PID) 2>/dev/null" && ALIVE="alive"
        LINES=$(docker exec "$CB" sh -c "wc -l < $CONT_SRV_LOG 2>/dev/null" | tr -d '[:space:]')
        docker exec "$CB" cat "$CONT_SRV_LOG" > "${OUTPUT_DIR}/server_${CB}_after_trial${k}.log" 2>/dev/null
        echo "   [diag] $CB: server $ALIVE, log has ${LINES:-0} line(s) so far"
    done

    echo "   trial $k/$M done"
    sleep 1
done

# ---------------------------------------------------------------------------
# Step 3 (cont'd): stop servers, collect their accumulated logs. Each
# server handles exactly M sequential connections (one per trial, always
# from its own cont<i>a), so its log's data lines appear in trial order.
# ---------------------------------------------------------------------------
echo "== Stopping servers and collecting logs =="
for i in $(seq 1 "$N"); do
    CB="$(contB "$i")"
    docker exec "$CB" cat "$CONT_SRV_LOG" > "${OUTPUT_DIR}/server_${CB}.log" 2>/dev/null
    docker exec "$CB" sh -c "[ -f $CONT_SRV_PID ] && kill \$(cat $CONT_SRV_PID) 2>/dev/null; true"
done

# ---------------------------------------------------------------------------
# Step 4: parse and combine into one table.
# ---------------------------------------------------------------------------
to_gbit() {
    # "1.07 Gbits/sec" -> 1.070 ; "512.3 Mbits/sec" -> 0.512 ; "800 Kbits/sec" -> 0.001
    local num unit
    num=$(echo "$1" | awk '{print $1}')
    unit=$(echo "$1" | awk '{print $2}')
    case "$unit" in
        Gbits/sec) awk -v n="$num" 'BEGIN{printf "%.3f", n}' ;;
        Mbits/sec) awk -v n="$num" 'BEGIN{printf "%.3f", n/1000}' ;;
        Kbits/sec) awk -v n="$num" 'BEGIN{printf "%.3f", n/1000000}' ;;
        *) echo "N/A" ;;
    esac
}

# A genuine data/summary line looks like:
#   [  1] 0.0000-9.9997 sec  1.25 GBytes  1.07 Gbits/sec   0.001 ms 0/913048 (0%)
# Must require the bandwidth figure on the SAME line, not just the leading
# bracket+timerange+sec: iperf also prints a separate "[N] X-Y sec  NN
# datagrams received out-of-order" line whenever reordering occurs, which
# shares that exact same leading format but carries no bandwidth data -
# without this, that line gets counted as a "trial" of its own and shifts
# every subsequent connection's line off by one.
DATA_LINE_RE='^\[ *[0-9]+\] +[0-9.]+-[0-9.]+ +sec.*[0-9.]+ [KMG]bits/sec'

extract_client_bw() {
    # first data line in a client log = that client's own sent rate
    local f="$1" line bwtok
    line=$(grep -E "$DATA_LINE_RE" "$f" 2>/dev/null | head -1)
    [ -z "$line" ] && { echo "N/A"; return; }
    bwtok=$(echo "$line" | grep -oE '[0-9.]+ [KMG]bits/sec' | head -1)
    [ -z "$bwtok" ] && { echo "N/A"; return; }
    to_gbit "$bwtok"
}

extract_server_bw_nth() {
    # k-th data line in a persistent server's log = trial k's received rate
    local f="$1" k="$2" line bwtok
    line=$(grep -E "$DATA_LINE_RE" "$f" 2>/dev/null | sed -n "${k}p")
    [ -z "$line" ] && { echo "N/A"; return; }
    bwtok=$(echo "$line" | grep -oE '[0-9.]+ [KMG]bits/sec' | head -1)
    [ -z "$bwtok" ] && { echo "N/A"; return; }
    to_gbit "$bwtok"
}

RESULT_TABLE="${OUTPUT_DIR}/combined_results.tsv"
{
    printf "Trial"
    for i in $(seq 1 "$N"); do
        printf "\t%s\t%s" "$(contA "$i")" "$(contB "$i")"
    done
    printf "\n"

    for k in $(seq 1 "$M"); do
        printf "%d" "$k"
        for i in $(seq 1 "$N"); do
            CA="$(contA "$i")"; CB="$(contB "$i")"
            CBW=$(extract_client_bw "${OUTPUT_DIR}/client_${CA}_trial${k}.log")
            SBW=$(extract_server_bw_nth "${OUTPUT_DIR}/server_${CB}.log" "$k")
            printf "\t%s\t%s" "$CBW" "$SBW"
        done
        printf "\n"
    done
} > "$RESULT_TABLE"

echo
echo "== Combined results (Gbit/s, tab-separated) =="
column -t "$RESULT_TABLE" 2>/dev/null || cat "$RESULT_TABLE"
echo
echo "Per-run raw logs saved under: $OUTPUT_DIR"
echo "Combined table: $RESULT_TABLE"
