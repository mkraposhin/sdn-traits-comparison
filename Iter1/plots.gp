# plots.gp - OVS vs OpenSDN: throughput / mean latency / max latency vs offered load
# Usage: gnuplot plots.gp      (needs data.dat in the same folder)
#
# data.dat columns:
#  1 offered  2 N  3 ovs_min  4 ovs_mean  5 ovs_max  6 ovs_thr
#                  7 sdn_min  8 sdn_mean  9 sdn_max 10 sdn_thr

set terminal pngcairo size 1000,640 font "Sans,13" background rgb "white"

# Series colours (colour-blind-safe pair) + distinct markers/dashes, so
# identity never relies on colour alone.
ovs = "#2a78d6"   # OVS     - blue,   circle, solid
sdn = "#eb6834"   # OpenSDN - orange, square, dashed

set style line 1 lc rgb ovs lw 2 dt 1 pt 7 ps 1.3
set style line 2 lc rgb sdn lw 2 dt 2 pt 5 ps 1.3

set border lw 1 lc rgb "#555555"
set tics textcolor rgb "#333333"
set grid lc rgb "#dddddd" lw 1
set key top left box lc rgb "#cccccc" opaque
set xlabel "Offered load, Gbit/s"
set xrange [0:8.5]
set xtics 1
set mxtics 2

# 1) Throughput ---------------------------------------------------------
set output "throughput_vs_load.png"
set title "Achieved throughput vs offered load"
set ylabel "Achieved throughput, Gbit/s"
set yrange [0:*]
plot "data.dat" skip 1 using 1:6  with points ls 1 title "OVS", \
     ""         skip 1 using 1:10 with points ls 2 title "OpenSDN"

# 2) Mean latency -------------------------------------------------------
set output "mean_latency_vs_load.png"
set title "Mean latency vs offered load"
set ylabel "Mean latency, ms"
set yrange [0:*]
plot "data.dat" skip 1 using 1:4 with points ls 1 title "OVS", \
     ""         skip 1 using 1:8 with points ls 2 title "OpenSDN"

# 3) Max latency --------------------------------------------------------
set output "max_latency_vs_load.png"
set title "Maximum latency vs offered load"
set ylabel "Maximum latency, ms"
set yrange [0:*]
plot "data.dat" skip 1 using 1:5 with points ls 1 title "OVS", \
     ""         skip 1 using 1:9 with points ls 2 title "OpenSDN"

unset output
