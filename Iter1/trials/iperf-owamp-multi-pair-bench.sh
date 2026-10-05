#!/bin/bash
#
# iperf-owamp-multi-pair-bench.sh
#
# Dataplane-agnostic: assumes N container pairs already exist, wired up and
# flow-configured by whichever setup you're testing (OVS, OpenSDN vRouter
# Forwarder, or anything else later) - this script touches ONLY the
# containers themselves (iperf/owamp processes inside them), never
# bridges, vifs, flows, or tc. Apply the relevant setup scripts and
# tc-queue-setup.sh BEFORE running this.
#
# Naming convention (already shared by both dataplanes): cont<i>a / cont<i>b
# for i in 1..N, with cont<i>a always the client/sender, cont<i>b the
# server/receiver.
#
# Per trial:
#   t=0          iperf client on cont<i>a starts sending UDP load to cont<i>b
#   t=0.5        owping on cont<i>a starts one-way probing to cont<i>b
#                (Poisson-spaced - this is owping's own default behavior,
#                the script does not pass any flag that would force
#                uniform/periodic spacing instead)
#   t~=D-0.5     owping's packet count is chosen so it stops naturally here
#   t=D          iperf client stops
# (Per your call: drift around the 0.5s marks is fine - we're measuring
# latency, not synchronizing to the millisecond.)
#
# The iperf UDP server and owampd are started ONCE at the top of the run
# and stay up across all M trials - they are only stopped at the very end.
#
# NOTE: unlike iperf-udp-multi-pair-bench.sh, this script does NOT restart
# containers at startup to clear orphaned processes from a previous
# Ctrl+C - that restart risks tearing down the manually-injected veth/IP
# networking these containers depend on (Docker doesn't know that
# networking exists, since it was added outside of Docker's own tooling).
# If a previous run left stray iperf/owping/owampd processes behind,
# clear them by hand first, e.g.:
#   docker exec cont1a pkill -f iperf; docker exec cont1a pkill -f owping
#   docker exec cont1b pkill -f iperf; docker exec cont1b pkill -f owampd
#
# Usage:
#   ./iperf-owamp-multi-pair-bench.sh <N_PAIRS> <M_TRIALS> [duration_sec] \
#       [load_gbps] [owamp_interval] [iperf_port] [output_dir]
#
#   duration_sec    default 10   (must be > 1.0 - the owamp window is
#                                 duration_sec - 1.0 and must be positive)
#   load_gbps       default 1    (plain Gbit/s decimal, e.g. 0.5, 2.5)
#   owamp_interval  default 0.1  (mean seconds between owamp probes;
#                                 Poisson-distributed by owping itself)
#   iperf_port      default 25600
#   output_dir      default ./bench-owamp-<timestamp>
#
# CAVEATS - things I could not verify end-to-end from this environment
# (no network access here to install/run owamp myself) - check these
# against your actual output and tell me if anything doesn't match:
#   - owampd is invoked as `owampd -Z -R /tmp`: -Z (foreground, don't
#     self-daemonize) and -R (pid-file directory) ARE both confirmed
#     against owampd's own documented option list, so backgrounding it
#     ourselves via `docker exec -d ... & echo $!` and killing that exact
#     PID later should be correct - just not confirmed by an actual run.
#   - owampd's default config (whatever owamp-server's package postinst
#     sets up under /etc) is assumed to allow an open/anonymous test with
#     no extra -A/-k auth flags. If owping's control handshake gets
#     rejected, that config is the first thing to check.
#   - "mean" latency is computed here from owping's own per-packet -v
#     output ("seq_no=N  delay=X ms  (sync, err=...)"), NOT from owping's
#     summary "median" - that summary value is derived from a histogram
#     with a default 0.1ms bucket width, which on this same-host/virtual-
#     switch setup (true delays mostly well under 0.1ms) collapses nearly
#     every sample into one bin, making the reported median come out as
#     a constant ~0.1ms regardless of the real distribution. min/max in
#     the summary line are NOT bucketed (taken directly from the raw
#     samples), so those are still parsed from the summary as before.

set -uo pipefail
export LC_ALL=C

N_PAIRS="${1:?Usage: $0 <N_PAIRS> <M_TRIALS> [duration_sec] [load_gbps] [owamp_interval] [iperf_port] [output_dir]}"
M_TRIALS="${2:?Usage: $0 <N_PAIRS> <M_TRIALS> [duration_sec] [load_gbps] [owamp_interval] [iperf_port] [output_dir]}"
DURATION="${3:-10}"
LOAD_GBPS="${4:-1}"
OWAMP_INTERVAL="${5:-0.1}"
IPERF_PORT="${6:-25600}"
OUTPUT_DIR="${7:-./bench-owamp-$(date +%Y%m%d-%H%M%S)}"

mkdir -p "$OUTPUT_DIR"

# owamp probing window: starts 0.5s after load starts, stops 0.5s before
# load stops -> active window = DURATION - 1.0 seconds.
OWAMP_WINDOW=$(awk -v d="$DURATION" 'BEGIN{print d-1.0}')
if awk -v w="$OWAMP_WINDOW" 'BEGIN{exit !(w<=0)}'; then
    echo "ERROR: duration_sec ($DURATION) must be > 1.0 so the owamp window (duration-1.0) is positive." >&2
    exit 1
fi
OWAMP_COUNT=$(awk -v w="$OWAMP_WINDOW" -v i="$OWAMP_INTERVAL" 'BEGIN{c=int(w/i+0.5); if (c<1) c=1; print c}')

set_pair_vars() {
    local i="$1"
    CONT1="cont${i}a"
    CONT2="cont${i}b"
    IP2="10.1.${i}.22"
}

echo "== Starting persistent iperf UDP servers and owampd (kept up across all $M_TRIALS trials) =="
for i in $(seq 1 "$N_PAIRS"); do
    set_pair_vars "$i"
    docker exec -d "$CONT2" bash -c \
        "stdbuf -oL -eL iperf -s -u -p ${IPERF_PORT} > /iperf_server.log 2>&1 & echo \$! > /iperf_server.pid"
    docker exec -d "$CONT2" bash -c \
        "owampd -Z -f -R /tmp > /owampd_server.log 2>&1 & echo \$! > /owampd_server.pid"
done
sleep 1

echo "== Running $M_TRIALS trials: duration=${DURATION}s load=${LOAD_GBPS}Gbit/s owamp=${OWAMP_COUNT} probes @ mean ${OWAMP_INTERVAL}s (Poisson) =="

THROUGHPUT_TABLE="${OUTPUT_DIR}/throughput_summary.txt"
LATENCY_TABLE="${OUTPUT_DIR}/latency_summary.txt"

{
    printf "%-6s" "trial"
    for i in $(seq 1 "$N_PAIRS"); do printf " cont%da(Gbit/s) cont%db(Gbit/s)" "$i" "$i"; done
    printf "\n"
} > "$THROUGHPUT_TABLE"

{
    printf "%-6s" "trial"
    for i in $(seq 1 "$N_PAIRS"); do printf " pair%d_min(ms) pair%d_mean(ms) pair%d_max(ms) pair%d_loss(pct)" "$i" "$i" "$i" "$i"; done
    printf "\n"
} > "$LATENCY_TABLE"

to_gbit() {
    # "123 Mbits/sec" | "1.23 Gbits/sec" -> Gbit/s, 3 decimals
    awk '{
        val=$1; unit=$2;
        if (unit ~ /^K/) val/=1e6;
        else if (unit ~ /^M/) val/=1e3;
        printf "%.3f", val;
    }'
}

DATA_LINE_RE='^\[ *[0-9]+\] +[0-9.]+-[0-9.]+ +sec.*[0-9.]+ [KMG]bits/sec'

for k in $(seq 1 "$M_TRIALS"); do
    echo "-- Trial $k --"
    IPERF_PIDS=()
    OWAMP_PIDS=()

    for i in $(seq 1 "$N_PAIRS"); do
        set_pair_vars "$i"
        CLIENT_LOG="${OUTPUT_DIR}/trial${k}_${CONT1}_iperf.log"
        docker exec "$CONT1" bash -c \
            "stdbuf -oL -eL iperf -c ${IP2} -u -p ${IPERF_PORT} -b ${LOAD_GBPS}G -t ${DURATION}" \
            > "$CLIENT_LOG" 2>&1 &
        IPERF_PIDS+=("$!")
    done

    sleep 0.5

    for i in $(seq 1 "$N_PAIRS"); do
        set_pair_vars "$i"
        OWPING_LOG="${OUTPUT_DIR}/trial${k}_${CONT1}_owping.log"
        docker exec "$CONT1" bash -c \
            "owping -c ${OWAMP_COUNT} -i ${OWAMP_INTERVAL} -v -t ${IP2}" \
            > "$OWPING_LOG" 2>&1 &
        OWAMP_PIDS+=("$!")
    done

    wait "${IPERF_PIDS[@]}" "${OWAMP_PIDS[@]}" 2>/dev/null

    # raw data: snapshot server-side iperf log for this trial
    for i in $(seq 1 "$N_PAIRS"); do
        set_pair_vars "$i"
        docker exec "$CONT2" cat /iperf_server.log \
            > "${OUTPUT_DIR}/trial${k}_${CONT2}_iperf_server_snapshot.log" 2>/dev/null
    done

    # -- throughput row --
    row="$k"
    for i in $(seq 1 "$N_PAIRS"); do
        set_pair_vars "$i"
        CLIENT_LOG="${OUTPUT_DIR}/trial${k}_${CONT1}_iperf.log"
        SERVER_SNAP="${OUTPUT_DIR}/trial${k}_${CONT2}_iperf_server_snapshot.log"

        c_val=$(grep -E "$DATA_LINE_RE" "$CLIENT_LOG" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [KMG]bits/sec' | to_gbit)
        s_val=$(grep -E "$DATA_LINE_RE" "$SERVER_SNAP" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [KMG]bits/sec' | to_gbit)

        row="${row} ${c_val:-N/A} ${s_val:-N/A}"
    done
    echo "$row" >> "$THROUGHPUT_TABLE"

    # -- latency row --
    row="$k"
    for i in $(seq 1 "$N_PAIRS"); do
        set_pair_vars "$i"
        OWPING_LOG="${OUTPUT_DIR}/trial${k}_${CONT1}_owping.log"

        minmax=$(grep -oE 'one-way delay min/median/max = [0-9.]+/[0-9.]+/[0-9.]+' "$OWPING_LOG" 2>/dev/null \
                 | grep -oE '[0-9.]+/[0-9.]+/[0-9.]+' | tr '/' ' ')
        loss=$(grep -oE '\([0-9.]+%\)' "$OWPING_LOG" 2>/dev/null | head -1 | tr -d '()%')
        # arithmetic mean from owping's own per-packet -v lines
        # ("seq_no=N   delay=X ms ...") - not histogram-based, so it isn't
        # bucketed like the summary's "median" is (see CAVEATS above).
        dmean=$(grep -oE 'delay=[0-9.]+ ms' "$OWPING_LOG" 2>/dev/null \
                | grep -oE '[0-9.]+' \
                | awk '{s+=$1; n++} END{if (n>0) printf "%.4f", s/n}')

        if [ -n "$minmax" ]; then
            read -r dmin _ dmax <<< "$minmax"
        else
            dmin="N/A"; dmax="N/A"
        fi
        row="${row} ${dmin} ${dmean:-N/A} ${dmax} ${loss:-N/A}"
    done
    echo "$row" >> "$LATENCY_TABLE"

    sleep 1
done

echo "== Stopping persistent iperf servers and owampd =="
for i in $(seq 1 "$N_PAIRS"); do
    set_pair_vars "$i"
    docker exec "$CONT2" bash -c 'kill "$(cat /iperf_server.pid 2>/dev/null)" 2>/dev/null; rm -f /iperf_server.pid'
    docker exec "$CONT2" bash -c 'kill "$(cat /owampd_server.pid 2>/dev/null)" 2>/dev/null; rm -f /owampd_server.pid'
done

echo "Done."
echo "Raw per-trial logs, throughput_summary.txt and latency_summary.txt are in: $OUTPUT_DIR"
