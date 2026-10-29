#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS upstream's gtest suite (test/test_no_tls, built by mayhem/build.sh). Asserts
# behavior through gtest's own EXPECT_*/ASSERT_* checks (HTTP parsing, routing, ranges, multipart,
# compression, ... over loopback sockets). Fails if the runner is missing or reports zero passing tests,
# so a neutered/no-op binary cannot pass. The *_Online tests (httpbin/httpwatch/...) need the internet and
# are excluded: the suite must pass offline (the patch grader has no network).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/test/test_no_tls"
if [ ! -x "$BIN" ]; then
  echo "missing $BIN — mayhem/build.sh should have built it" >&2
  emit_ctrf gtest 0 1
  exit 1
fi

SHARDS="${SHARDS:-4}"
LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT
cd "$SRC/test"   # the suite reads ./www, ./image.jpg, ...
pids=()
for i in $(seq 0 $((SHARDS - 1))); do
  GTEST_TOTAL_SHARDS=$SHARDS GTEST_SHARD_INDEX=$i "$BIN" '--gtest_filter=-*_Online' > "$LOGS/shard_$i.log" 2>&1 &
  pids+=($!)
done
crashed=0
for i in "${!pids[@]}"; do
  wait "${pids[$i]}" || { ec=$?; echo "shard $i exit=$ec" >&2; }
done

# gtest summary lines: "[  PASSED  ] N tests." / "[  SKIPPED ] N tests, listed below:" / "[  FAILED  ] N tests, listed below:"
sum() { cat "$LOGS"/shard_*.log | awk -v pat="$1" '$0 ~ pat { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) { n+=$i; break } } END { print n+0 }'; }
passed=$(sum '^\[  PASSED  \] [0-9]+ test')
failed=$(sum '^\[  FAILED  \] [0-9]+ test')
skipped=$(sum '^\[  SKIPPED \] [0-9]+ test')
ran=$(cat "$LOGS"/shard_*.log | awk '/^\[==========\] [0-9]+ tests? from .* ran\./ { n+=$2 } END { print n+0 }')

# Every shard must have printed its PASSED line; otherwise a shard crashed/was cut short.
shards_ok=$(grep -l '^\[  PASSED  \]' "$LOGS"/shard_*.log | wc -l)
if [ "$shards_ok" -ne "$SHARDS" ] || [ "$passed" -eq 0 ]; then
  echo "only $shards_ok/$SHARDS shards reported PASSED" >&2
  for f in "$LOGS"/shard_*.log; do grep -q '^\[  PASSED  \]' "$f" || { echo "=== $f ==="; tail -40 "$f"; }; done
  [ "$failed" -gt 0 ] || failed=1
fi
[ "$failed" -eq 0 ] || grep -h '^\[  FAILED  \]' "$LOGS"/shard_*.log | sort -u
echo "gtest: ran=$ran passed=$passed failed=$failed skipped=$skipped"
emit_ctrf gtest "$passed" "$failed" "$skipped"
