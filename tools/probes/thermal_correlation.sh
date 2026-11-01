#!/bin/bash
# Read-only sensor identification: reads every temperature while loading E cores, all cores, then the GPU.
# Usage: thermal_correlation.sh <output dir>. Issues no SMC write.
set -u
out="$1"; here="$(cd "$(dirname "$0")" && pwd)"; mkdir -p "$out"
swiftc -O "$here/smcprobe.swift" -o "$out/smcprobe" -framework IOKit
swiftc -O "$here/hidprobe.swift" -o "$out/hidprobe" -framework IOKit
swiftc -O "$here/gpustress.swift" -o "$out/gpustress" -framework Metal
snap() { "$out/smcprobe" | grep -E '^T' > "$out/smc_$1.tsv"; "$out/hidprobe" | sed -n '/== temperature/,/== current/p' > "$out/hid_$1.tsv"; }
burn() { local pids=(); for _ in $(seq 1 "$1"); do $2 yes > /dev/null & pids+=($!); done; sleep "$3"; snap "$4"; kill "${pids[@]}" 2> /dev/null; wait 2> /dev/null; }
snap idle
burn 4 "taskpolicy -b" 25 ecore
sleep 40; snap cool1
burn 14 "" 25 allcpu
sleep 50; snap cool2
"$out/gpustress" 25 & gp=$!; sleep 22; snap gpu; wait $gp
echo done
