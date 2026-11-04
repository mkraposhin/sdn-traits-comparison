# plots-efficiency.gp - OVS vs OpenSDN vs Cilium:
#   1) parallel efficiency E vs number of pairs N
#   2) harmonic mean H of the per-pair throughput vs N
# Usage: gnuplot plots-efficiency.gp   (needs efficiency.dat in the same folder)
#
# efficiency.dat columns (line 1 = comment, line 2 = header -> skip 2):
#  1 N   2 E_ovs  3 E_sdn  4 E_cil   5 H_ovs  6 H_sdn  7 H_cil
#
# E = H / G_1, G_1 = single-pair throughput of the same platform at
# 1.0 Gbit/s offered load. Points only: nothing is known between the
# measured values of N, so they are not connected.

set terminal pngcairo size 1000,640 font "Sans,13" background rgb "white"

# Same series styling as plots.gp: colour + distinct marker.
ovs = "#2a78d6"   # OVS     - blue,   filled circle
sdn = "#eb6834"   # OpenSDN - orange, filled square
cil = "#1b9e77"   # Cilium  - green,  filled triangle

set style line 1 lc rgb ovs pt 7 ps 1.4
set style line 2 lc rgb sdn pt 5 ps 1.4
set style line 3 lc rgb cil pt 9 ps 1.5

set border lw 1 lc rgb "#555555"
set tics textcolor rgb "#333333"
set grid lc rgb "#dddddd" lw 1
set key top right box lc rgb "#cccccc" opaque
set xlabel "Number of pairs, N"
set xrange [0.5:8.5]
set xtics 1
set yrange [0:*]

# 1) Efficiency ---------------------------------------------------------
set output "efficiency_vs_pairs.png"
set title "Parallel efficiency vs number of pairs"
set ylabel "Efficiency E = H / G_1 (own single-pair baseline)"
set ytics 0.1
plot "efficiency.dat" skip 2 using 1:2 with points ls 1 title "OVS", \
     ""               skip 2 using 1:3 with points ls 2 title "OpenSDN", \
     ""               skip 2 using 1:4 with points ls 3 title "Cilium"

# 2) Harmonic mean of per-pair throughput -------------------------------
set output "harmonic_mean_vs_pairs.png"
set title "Harmonic mean of per-pair throughput vs number of pairs"
set ylabel "Harmonic mean H, Gbit/s"
set ytics autofreq
plot "efficiency.dat" skip 2 using 1:5 with points ls 1 title "OVS", \
     ""               skip 2 using 1:6 with points ls 2 title "OpenSDN", \
     ""               skip 2 using 1:7 with points ls 3 title "Cilium"

unset output
