#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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


# Oracle: (1) known-input -> exact-output probes against the normal-flags build, (2) upstream's golden-file
# format suite (tests/*.test: 2522 input/expected-output pairs across C, C++, C#, D, Java, ObjC, Pawn, Vala, ECMAScript).
BIN="$SRC/build/oracle/uncrustify"
[ -x "$BIN" ] || { echo "missing $BIN - mayhem/build.sh did not build it" >&2; emit_ctrf "uncrustify-oracle" 0 1; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passed=0 failed=0

cat > "$work/kat.cfg" <<'CFG'
indent_columns=2
indent_with_tabs=0
sp_assign=force
sp_arith=force
sp_after_comma=force
nl_after_brace_open=true
mod_full_brace_if=add
nl_if_brace=force
nl_fdef_brace=force
CFG

# kat <name> <language> <input> <expected output>
kat() {
  local got
  got="$(printf '%s\n' "$3" | "$BIN" -q -c "$work/kat.cfg" -l "$2" 2>/dev/null)"
  if [ "$got" == "$4" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "KAT FAIL: $1" >&2; printf 'expected:\n%s\ngot:\n%s\n' "$4" "$got" >&2
  fi
}

kat spacing-and-braces C 'if(x==1)y=2;' 'if(x==1)
{
  y = 2;
}'
kat function-body C 'int f(int a,int b){return a*b+1;}' 'int f(int a, int b)
{
  return a * b + 1;
}'
kat cpp-class CPP 'class A{public:int f(int a,int b){return a*b;}};' 'class A {
public: int f(int a, int b)
{
  return a * b;
}
};'

# An unbalanced brace must be rejected with EX_SOFTWARE (74) and no formatted output.
out="$(printf '{{(\n' | "$BIN" -q -c "$work/kat.cfg" -l C 2>/dev/null)"; rc=$?
if [ "$rc" -eq 74 ] && [ -z "$out" ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "KAT FAIL: unbalanced input rc=$rc" >&2; fi

# --version names the program (the suffix after the name depends on git describe).
ver="$("$BIN" --version 2>/dev/null)"
if [[ "$ver" == Uncrustify*-[0-9]* ]]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "KAT FAIL: --version" >&2; fi

suite="$(python3 tests/run_format_tests.py -e "$BIN" -j "$MAYHEM_JOBS" --result-dir "$work/results" 2>&1)"
echo "$suite" | tail -n 40
if [[ "$(echo "$suite" | tail -n 1)" =~ ^([0-9]+)\ /\ ([0-9]+)\ tests\ passed$ ]]; then
  sp="${BASH_REMATCH[1]}" st="${BASH_REMATCH[2]}"
  passed=$((passed + sp)); failed=$((failed + st - sp))
else
  failed=$((failed + 1))
fi

emit_ctrf "uncrustify-oracle" "$passed" "$failed"
