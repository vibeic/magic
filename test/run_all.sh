#!/bin/bash
#
# Run every regression gate under test/*/ and report what actually happened.
#
# WHY THIS FILE EXISTS
# --------------------
# The nine gates in test/ were written as FAIL->PASS proofs for the vibeic
# LEF/DEF/GDS/extraction fixes, and until this runner existed NOTHING invoked
# them: not the Makefile, not a workflow, not the image build. Worse than
# "nothing", magic's top level made that state look healthy --
#
#     $ make test
#     make: Nothing to be done for 'test'.        <-- exit 0, ran nothing
#
# because `test` is a DIRECTORY here, so make matched it as an up-to-date file
# target. A post-merge check written as `make test` would have gone green on a
# tree whose entire regression suite was inert. `test:` is .PHONY in Makefile.in
# now, and it runs this script.
#
# WHAT IT GUARANTEES
# ------------------
#   * every SELECTED gate is INVOKED, and its exit status is the verdict;
#   * the number of gates that reported back MUST equal the number selected,
#     or the run is an ERROR (exit 2) -- see "THE COUNTING INVARIANT" below;
#   * a gate that cannot run because a TOOL is absent is reported as a NAMED
#     SKIP naming the missing thing -- never as a pass, and never silently;
#   * a gate that decides for itself that its preconditions do not hold (it
#     prints "SKIP:" and exits 0) is surfaced as SKIP, not counted as a pass;
#   * a run in which EVERY gate skipped is an ERROR (exit 2): a suite that
#     exercised nothing has proven nothing, whatever its exit code says;
#   * exit 1 if any gate failed, so CI cannot read a red suite as green.
#
# The subject under test is the INSTALLED magic: this is a Tcl build, so the
# runnable `magic` only exists after `make install` (the build tree has
# magic/tclmagic.so and no wrapper). Hence `make test` does not build; run it
# after `make install`, or point MAGIC_BIN at any magic you want to test.
#
# Usage:
#   ./test/run_all.sh [MAGIC_BIN] [NETGEN_BIN] [MAGICRC]
#   MAGIC_BIN=... NETGEN_BIN=... PDK_ROOT=... ./test/run_all.sh
#   ./test/run_all.sh --list          # print the gates and their requirements
#
# Environment:
#   MAGIC_BIN   magic executable         (default: $1, else `magic` on PATH)
#   NETGEN_BIN  netgen executable        (default: $2, else `netgen` on PATH)
#   PYTHON      python3 interpreter      (default: python3 on PATH)
#   PDK_ROOT    open_pdks root           (default: /foss/pdks)
#   MAGICRC     sky130A magicrc          (default: $PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc)
#   TESTS       space-separated subset of gate names to run (default: all)
#   VERBOSE=1   stream every gate's output instead of only failures'
#
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# THE GATE LIST.  One entry per gate: "<dir>/run.sh <requirements...>"
# Named explicitly rather than globbed so that adding a directory without
# declaring what it needs cannot silently join the run, and so the list is
# greppable evidence of what the build reaches.
#
#   magic   the tool under test (every gate)
#   python  python3, used to generate the DEF/GDS fixtures
#   netgen  netgen, used for the LVS compare gates
#   pdk     a readable sky130A magicrc (only the zero-width-route gate)
#
# It is a bash ARRAY, and the runner iterates it with `for`, deliberately.
# An earlier version drove the loop from stdin (`while read ... done <<EOF`)
# and that was a REAL, MEASURED defect, not a style point: the gates invoke
# `magic -dnull -noconsole <script>`, magic reads its inherited stdin to EOF,
# and so the FIRST gate drank the heredoc that was feeding the loop. The loop
# then ended silently -- 1 of 9 gates ran and the suite exited 0. Measured:
# def_mfggrid_snap and def_ndr_via_byrule both drain an inherited stdin, and
# they are the first two entries here, so the suite died immediately, every
# time, while printing a cheerful "gates: 1".
# A `for` over an array cannot be drained by anything a gate does, and the
# gate call below additionally gets `</dev/null` so a gate can never consume
# the stdin of whoever invoked `make test` either.
# ---------------------------------------------------------------------------
GATES=(
"test/def_mfggrid_snap/run.sh            magic python"
"test/def_ndr_via_byrule/run.sh          magic python"
"test/ext2spice_hier_ports/run.sh        magic"
"test/gds_foundry_layers/run.sh          magic python"
"test/gds_mfggrid_snap/run.sh            magic python"
"test/lef_extract_tech/run.sh            magic python"
"test/lvs_bridge_tech_multimetal/run.sh  magic python netgen"
"test/lvs_layermap_autodiscover/run.sh   magic python netgen"
"test/lvs_zero_width_route/run.sh        magic netgen pdk"
"test/spef_output/run.sh                 magic python"
)

gate_name() {   # $1 = "test/<dir>/run.sh <reqs...>"  ->  <dir>
    local rel
    read -r rel _ <<< "$1"
    basename "$(dirname "$rel")"
}

if [ "${1:-}" = "--list" ]; then
    printf '%s\n' "${GATES[@]}"
    exit 0
fi

MAGIC_BIN="${MAGIC_BIN:-${1:-}}"
NETGEN_BIN="${NETGEN_BIN:-${2:-}}"
PY="${PYTHON:-python3}"
PDK_ROOT="${PDK_ROOT:-/foss/pdks}"
MAGICRC="${MAGICRC:-${3:-$PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc}}"

# sky130A.magicrc resolves its own tech file through $PDK_ROOT and falls back to
# the absolute path baked in at PDK build time, so PDK_ROOT must be EXPORTED for
# the gate that uses it -- not merely set in this shell.
export PDK_ROOT

resolve() {   # $1 = candidate path, $2 = name to look up on PATH
    if [ -n "$1" ] && [ -x "$1" ]; then echo "$1"; return 0; fi
    found="$(command -v "$2" 2>/dev/null || true)"
    # Say so when a named path did not resolve: silently testing whatever was on
    # PATH instead of the binary the caller asked for is how a typo in MAGIC_BIN
    # turns into a result about the wrong tool.
    if [ -n "$1" ] && [ -n "$found" ]; then
        echo "note: '$1' is not executable; using '$found' from PATH instead" >&2
    fi
    echo "$found"
}
MAGIC_BIN="$(resolve "$MAGIC_BIN" magic)"
NETGEN_BIN="$(resolve "$NETGEN_BIN" netgen)"

# ---------------------------------------------------------------------------
# The subject itself is not optional.  A suite that "passes" without the tool it
# tests proves nothing, so a missing magic is an ERROR, never a skip.
# ---------------------------------------------------------------------------
if [ -z "$MAGIC_BIN" ]; then
    echo "ERROR: no magic executable found."
    echo "       This is a Tcl build: the runnable 'magic' appears only after"
    echo "       'make install'.  Install it first, or run:"
    echo "           make test MAGIC_BIN=/path/to/magic"
    exit 2
fi

have_python=0; "$PY" -c '' >/dev/null 2>&1 && have_python=1
have_netgen=0; [ -n "$NETGEN_BIN" ] && have_netgen=1
have_pdk=0;    [ -r "$MAGICRC" ] && have_pdk=1

# ---------------------------------------------------------------------------
# SELECTION -- decide what is supposed to run BEFORE anything runs, so that the
# expected count is fixed up front and cannot be quietly re-derived from
# whatever happened to execute.  That number is the invariant checked at the end.
# ---------------------------------------------------------------------------
want="${TESTS:-}"

if [ -n "$want" ]; then
    for t in $want; do
        known=0
        for entry in "${GATES[@]}"; do
            [ "$(gate_name "$entry")" = "$t" ] && { known=1; break; }
        done
        # A typo in TESTS must not select zero gates and call that success.
        [ "$known" = 1 ] || {
            echo "ERROR: TESTS names a gate that does not exist: '$t'"
            echo "       known gates: $(for e in "${GATES[@]}"; do printf '%s ' "$(gate_name "$e")"; done)"
            exit 2
        }
    done
fi

selected=()
for entry in "${GATES[@]}"; do
    if [ -n "$want" ]; then
        case " $want " in *" $(gate_name "$entry") "*) ;; *) continue ;; esac
    fi
    selected+=("$entry")
done
nexpected=${#selected[@]}

if [ "$nexpected" -eq 0 ]; then
    echo "ERROR: no gate selected to run."
    exit 2
fi

echo "=== magic regression gates ==============================================="
echo "magic   : $MAGIC_BIN"
echo "netgen  : ${NETGEN_BIN:-<not found>}"
echo "python  : $($PY -V 2>&1 || echo '<not found>')"
echo "magicrc : $MAGICRC$([ "$have_pdk" = 1 ] || echo '   <not readable>')"
echo "declared: ${#GATES[@]}   selected: $nexpected"
echo "=========================================================================="

LOGDIR="${LOGDIR:-${TMPDIR:-/tmp}/magic-test-logs.$$}"
mkdir -p "$LOGDIR"

npass=0; nfail=0; nskip=0
failed=""; skipped=""

run_one() {   # $1 = relative path to run.sh, $2.. = requirements
    rel="$1"; shift
    name="$(basename "$(dirname "$rel")")"
    script="$HERE/../$rel"

    if [ ! -x "$script" ]; then
        printf 'SKIP  %-28s (missing or not executable: %s)\n' "$name" "$rel"
        nskip=$((nskip + 1)); skipped="$skipped $name(missing)"; return
    fi

    for req in "$@"; do
        case "$req" in
        python) [ "$have_python" = 1 ] || {
                printf 'SKIP  %-28s (needs python3; PYTHON=%s not runnable)\n' "$name" "$PY"
                nskip=$((nskip + 1)); skipped="$skipped $name(no-python)"; return; } ;;
        netgen) [ "$have_netgen" = 1 ] || {
                printf 'SKIP  %-28s (needs netgen; not on PATH and NETGEN_BIN unset)\n' "$name"
                nskip=$((nskip + 1)); skipped="$skipped $name(no-netgen)"; return; } ;;
        pdk)    [ "$have_pdk" = 1 ] || {
                printf 'SKIP  %-28s (needs a readable sky130A magicrc: %s)\n' "$name" "$MAGICRC"
                nskip=$((nskip + 1)); skipped="$skipped $name(no-pdk)"; return; } ;;
        esac
    done

    log="$LOGDIR/$name.log"
    start=$(date +%s)
    # rc is captured from the gate itself, BEFORE any pipe: a `| tee` here would
    # hand back tee's status and turn every failure into a pass.
    #
    # `</dev/null` IS LOAD-BEARING.  The gates run `magic -dnull -noconsole`,
    # and magic reads whatever stdin it inherits to EOF.  Without this the gate
    # eats the caller's stdin -- which is exactly how the first version of this
    # runner executed 1 gate out of 9 and exited 0.
    "$script" "$MAGIC_BIN" "$NETGEN_BIN" "$MAGICRC" >"$log" 2>&1 </dev/null
    rc=$?
    elapsed=$(( $(date +%s) - start ))

    if [ "$rc" -eq 77 ] || { [ "$rc" -eq 0 ] && grep -q '^SKIP:' "$log"; }; then
        # The gate decided its own preconditions do not hold.  Surface that as a
        # SKIP with the gate's own reason -- an exit 0 here is NOT a pass.
        reason="$(grep -m1 '^SKIP:' "$log" | sed 's/^SKIP:[[:space:]]*//')"
        printf 'SKIP  %-28s %s\n' "$name" "${reason:-gate reported exit 77}"
        nskip=$((nskip + 1)); skipped="$skipped $name(self)"
    elif [ "$rc" -eq 0 ]; then
        printf 'PASS  %-28s (%ss)\n' "$name" "$elapsed"
        npass=$((npass + 1))
    else
        printf 'FAIL  %-28s (rc=%s, %ss)\n' "$name" "$rc" "$elapsed"
        nfail=$((nfail + 1)); failed="$failed $name"
        sed 's/^/        | /' "$log" | tail -n 12
    fi
    [ "${VERBOSE:-0}" = 1 ] && sed 's/^/        | /' "$log"
    return 0
}

for entry in "${selected[@]}"; do
    read -r rel reqs <<< "$entry"
    # shellcheck disable=SC2086
    run_one "$rel" $reqs
done

ntotal=$((npass + nfail + nskip))
echo "=========================================================================="
echo "gates: $ntotal/$nexpected   passed: $npass   FAILED: $nfail   skipped: $nskip"
[ -n "$failed" ]  && echo "  failed :$failed"
[ -n "$skipped" ] && echo "  skipped:$skipped"
echo "  logs   : $LOGDIR"

# ---------------------------------------------------------------------------
# THE COUNTING INVARIANT.
#
# The invariant is EXECUTED == SELECTED, not "executed > 0".  A guard that only
# catches ntotal == 0 lets any PARTIAL run through silently, and a partial run
# is precisely the failure this suite already shipped once: 1 of 9 gates ran,
# the other 8 were not PASS, not FAIL, not SKIP -- they simply never happened,
# and the summary line printed "gates: 1" without complaint.  Anything that
# stops the loop early, or any future edit that lets a gate return without
# recording a verdict, now lands here as exit 2 instead of a green run.
# ---------------------------------------------------------------------------
if [ "$ntotal" -ne "$nexpected" ]; then
    echo "ERROR: $nexpected gate(s) selected but only $ntotal reported a verdict."
    echo "       $((nexpected - ntotal)) gate(s) vanished without PASS/FAIL/SKIP."
    exit 2
fi

# A run in which every gate skipped exercised nothing.  Exit 0 there would be
# the same lie in a different costume.
if [ $((npass + nfail)) -eq 0 ]; then
    echo "ERROR: all $ntotal selected gate(s) skipped; nothing was exercised."
    exit 2
fi

[ "$nfail" -eq 0 ] || exit 1
exit 0
