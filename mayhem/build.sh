#!/usr/bin/env bash
#
# mayhem/build.sh — builds the five upstream libFuzzer harnesses (test/fuzzing/*_fuzzer.cc, the same set
# OSS-Fuzz builds) sanitized, each with a -standalone reproducer, plus upstream's gtest suite
# (test/test_no_tls) with NORMAL flags for mayhem/test.sh.
# httplib is header-only, so "instrumenting the project" = compiling the harness TU with the flags.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT=/mayhem
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1) The test suite, project's NORMAL flags (no sanitizers, no DWARF pin). gtest is vendored in test/gtest.
#    No TLS backend: the oracle needs no certificates, so nothing gitignored has to be generated.
TFLAGS="-std=c++11 -O0 -w -DCPPHTTPLIB_USE_NON_BLOCKING_GETADDRINFO -DCPPHTTPLIB_ZLIB_SUPPORT -DCPPHTTPLIB_BROTLI_SUPPORT -DCPPHTTPLIB_ZSTD_SUPPORT -I$SRC -I$SRC/test -I$SRC/test/gtest -I$SRC/test/gtest/include $COVERAGE_FLAGS"
(
  cd test
  printf '%s\0' test.cc include_httplib.cc gtest/src/gtest-all.cc gtest/src/gtest_main.cc |
    xargs -0 -P "$MAYHEM_JOBS" -I{} bash -c \
      "$CXX $TFLAGS -c {} -o $WORK/t_\$(basename {} .cc).o"
  $CXX $TFLAGS $COVERAGE_FLAGS "$WORK"/t_*.o -o test_no_tls -lz -lbrotlicommon -lbrotlienc -lbrotlidec -lzstd -lcurl -lpthread -lanl
)

# 2) Harnesses (zlib on, as upstream's test/fuzzing/Makefile). Leak detection off at link time (lsan_off.cc).
HFLAGS="-std=c++11 -O1 -DCPPHTTPLIB_ZLIB_SUPPORT -I$SRC"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$WORK/lsan_off.o"
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$WORK/standalone_main.o"

HARNESSES="server_fuzzer client_fuzzer header_parser_fuzzer url_parser_fuzzer multipart_parser_fuzzer"
build_one() {
  local h="$1" src="$SRC/test/fuzzing/$1.cc"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $HFLAGS $LIB_FUZZING_ENGINE "$src" "$WORK/lsan_off.o" \
       -o "$OUT/$h" -lz -pthread
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $HFLAGS "$src" "$WORK/standalone_main.o" "$WORK/lsan_off.o" \
       -o "$OUT/$h-standalone" -lz -pthread
}
export -f build_one
export WORK OUT SRC HFLAGS
printf '%s\n' $HARNESSES | xargs -P "$MAYHEM_JOBS" -I{} bash -c 'build_one {}'

for h in $HARNESSES; do ls -l "$OUT/$h" "$OUT/$h-standalone"; done
