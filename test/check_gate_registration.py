#!/usr/bin/env python3
"""Every regression gate in test/ is reachable by the thing that runs them.

WHY THIS EXISTS
---------------
The nine gates under test/ were each written as a FAIL->PASS proof for a fork
patch, and for a month NOTHING ran them: not the Makefile, not a workflow, not
the image build.  A tenth gate arriving with no line in the runner's list would
be the same defect again, and it is invisible -- the suite still says
"gates: 9/9 ... FAILED: 0" and exits 0, because a gate nobody selected does not
report a failure, it reports nothing at all.

So this asks the one question the suite cannot ask about itself: is every gate
that EXISTS also a gate that RUNS, and is the entry point still an entry point?

It is deliberately STATIC -- it parses files and starts no process.  That is
what lets it run in a merge worktree, before anything is built, which is where
an unregistered gate has to be caught: after the merge is pushed, the only
thing that notices is the next person to go looking.

  usage:  python3 test/check_gate_registration.py [repo-root]
  exit 0  every gate is declared, every declaration resolves, `make test` runs
          the runner
  exit 1  something is unreachable; the message names it
"""
import os
import re
import sys

KNOWN_REQS = {"magic", "python", "netgen", "pdk"}


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def declared_gates(runner_src):
    """The GATES array of test/run_all.sh, as [(relpath, [reqs...])]."""
    m = re.search(r"^GATES=\((.*?)^\)", runner_src, re.S | re.M)
    if m is None:
        return None
    out = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if not (line.startswith('"') and line.endswith('"')):
            return None            # an entry this parser does not understand
        parts = line[1:-1].split()
        if not parts:
            return None
        out.append((parts[0], parts[1:]))
    return out


def main(argv):
    root = os.path.abspath(argv[1] if len(argv) > 1 else ".")
    testdir = os.path.join(root, "test")
    runner = os.path.join(testdir, "run_all.sh")
    problems = []

    if not os.path.isdir(testdir):
        print(f"FAIL: no test/ directory under {root}")
        return 1
    if not os.path.isfile(runner):
        print("FAIL: test/run_all.sh is missing -- the gates have no runner at all")
        return 1

    gates = declared_gates(read(runner))
    if gates is None:
        print("FAIL: could not parse the GATES array in test/run_all.sh.  Not a "
              "style complaint: this check reads that array to know what runs, "
              "and a form it cannot read is a form it cannot verify.")
        return 1

    # ---- 1. everything on disk is declared --------------------------------
    on_disk = sorted(
        name for name in os.listdir(testdir)
        if os.path.isfile(os.path.join(testdir, name, "run.sh"))
    )
    declared_names = {os.path.basename(os.path.dirname(rel)) for rel, _ in gates}
    for name in on_disk:
        if name not in declared_names:
            problems.append(
                f"test/{name}/run.sh exists but is not in the GATES array of "
                f"test/run_all.sh -- it will never run, and the suite will "
                f"still report every gate it does know about as passing")

    # ---- 2. every declaration resolves ------------------------------------
    for rel, reqs in gates:
        target = os.path.join(root, rel)
        if not os.path.isfile(target):
            problems.append(f"{rel} is declared in GATES but does not exist")
            continue
        if not os.access(target, os.X_OK):
            problems.append(f"{rel} is declared in GATES but is not executable "
                            f"(the runner reports it as a SKIP, not a failure)")
        for req in reqs:
            if req not in KNOWN_REQS:
                problems.append(
                    f"{rel} declares requirement '{req}', which the runner does "
                    f"not know: unknown requirements are silently ignored, so "
                    f"the gate runs without the precondition it asked for "
                    f"(known: {', '.join(sorted(KNOWN_REQS))})")

    # ---- 3. `make test` still reaches the runner --------------------------
    # `test` is also a DIRECTORY here, so without .PHONY make matches it as an
    # up-to-date file target and `make test` exits 0 having run nothing.  That
    # is not hypothetical -- it is what this repo shipped.
    mk = os.path.join(root, "Makefile.in")
    if not os.path.isfile(mk):
        problems.append("Makefile.in is missing; cannot confirm `make test` "
                        "reaches the gates")
    else:
        src = read(mk)
        phony = re.search(r"^\.PHONY:.*\btest\b", src, re.M)
        rule = re.search(r"^test:.*?(?=^\S|\Z)", src, re.S | re.M)
        if not phony:
            problems.append(
                "Makefile.in does not declare `test` .PHONY.  `test` is a "
                "DIRECTORY in this repo, so make treats the target as an "
                "up-to-date file: `make test` prints \"Nothing to be done\" "
                "and exits 0 without running one gate")
        if not rule or "run_all.sh" not in rule.group(0):
            problems.append(
                "the `test:` rule in Makefile.in does not invoke "
                "test/run_all.sh -- `make test` no longer runs the gates")

    if problems:
        for p in problems:
            print(f"FAIL: {p}")
        return 1

    print(f"PASS: {len(on_disk)} gate(s) on disk, all declared in "
          f"test/run_all.sh; every declaration resolves to an executable with "
          f"known requirements; `make test` reaches the runner.")
    for rel, reqs in gates:
        print(f"  {os.path.basename(os.path.dirname(rel)):<28} needs: "
              f"{' '.join(reqs) if reqs else '(nothing but magic)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
