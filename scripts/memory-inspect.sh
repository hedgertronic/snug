#!/bin/bash
# memory-inspect.sh PID LABEL DIR: run by `Snug --memory-steps DIR` after each step. Writes PID's footprint, vmmap summary and heap
# summary to DIR/LABEL-*.txt and lists its live blocks of 1000 KiB or more. When the process runs with MallocStackLogging (which
# this script inherits), it adds their allocation stacks, and after the overlay closes and at cycles 1 and 10, the stacks of the last
# three NSKeyValueDependency records.
set -euo pipefail
pid=$1
name=$2
out=$3
mkdir -p "$out"
footprint -p "$pid" > "$out/$name-footprint.txt" 2>&1
vmmap --summary "$pid" > "$out/$name-vmmap.txt" 2>&1
heap -s "$pid" > "$out/$name-heap.txt" 2>&1
heap -s --addresses='.*[1000k-]' "$pid" > "$out/$name-large.txt" 2>&1
[ -n "${MallocStackLogging:-}" ] || exit 0
{ grep -oE '^0x[0-9a-f]+' "$out/$name-large.txt" || true; } | while read -r address; do
    echo "=== $address"
    malloc_history "$pid" "$address" 2>&1 | head -80
done > "$out/$name-large-stacks.txt"
case $name in
    *overlay-closed|*cycle-1|*cycle-10)
        heap --addresses='NSKeyValueDependency$' --noContent "$pid" > "$out/$name-kvo.txt" 2>&1
        { grep -oE '^0x[0-9a-f]+' "$out/$name-kvo.txt" || true; } | tail -3 | while read -r address; do
            echo "=== $address"
            malloc_history "$pid" "$address" 2>&1 | head -80
        done > "$out/$name-kvo-stacks.txt"
        ;;
esac
