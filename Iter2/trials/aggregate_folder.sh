#!/usr/bin/bash

offered_loads=("0.25" "0.5" "0.75" "1.0" "1.25" "1.5" "2" "3" "4" "5" "6" "7" "8")
pairs=("1" "1" "1" "1" "1" "1" "2" "3" "4" "5" "6" "7" "8")
dirs=`ls $1`
i=0
echo "Offered load (Gbit/s), N pairs, Min latency (ms), Mean latency (ms), Max latency (ms), Throughput (Gbit/s)"
for d in $dirs
do
	./aggregate-load-point.sh $1/$d ${offered_loads[$i]} ${pairs[$i]} 
	i=`expr $i + 1`
done


