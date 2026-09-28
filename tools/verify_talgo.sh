#!/usr/bin/env bash
# Acceptance sweep for TheAlgorithms/TypeScript: lower the 19 ORIGINAL
# sources (imports intact so cross-file parents resolve whole-program,
# SLA-style) and `sa check` each result. Dual-caliber: zero `^error` lines
# from both stages. Exit nonzero on any failure.
set -u
SA=${SA:-/content/sa_all/sci/zig-out/bin/sa}
export SA_PLUGINS_PATH=${SA_PLUGINS_PATH:-/content/sa_all/sa_plugin_ts/zig-out/lib} SA_PLUGIN_DEV=1
TALGO=${TALGO:-/tmp/talgo/data_structures}
OUT=${OUT:-/tmp/talgo_sweep}
FILES=(
  map/map map/hash_map queue/queue set/set list/linked_list
  queue/array_queue list/singly_linked_list queue/linked_queue
  list/doubly_linked_list set/map_set stack/stack tries/tries
  tree/binary_search_tree queue/circular_queue disjoint_set/disjoint_set
  set/hash_map_set heap/heap stack/linked_list_stack queue/stack_queue
)
pass=0; fail=0; failed=""
for b in "${FILES[@]}"; do
  n=$(basename "$b")
  lerr=$(timeout 25 $SA ts lower "$TALGO/$b.ts" -o "$OUT/$n.sai" 2>&1 | grep -c "^error")
  cerr=$(timeout 30 $SA check "$OUT/$n.sai" 2>&1 | grep -c "^error")
  if [ "$lerr" = "0" ] && [ "$cerr" = "0" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); failed="$failed $n(L$lerr/C$cerr)"
  fi
done
echo "PASS=$pass FAIL=$fail"
[ -n "$failed" ] && echo "FAILED:$failed"
[ "$fail" = "0" ]
