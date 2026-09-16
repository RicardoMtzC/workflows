"""Reconcile the target detected on a compute node with what this build host can emit.

    spack python resolve-target.py [WANTED_TARGET]

Prints shell-sourceable KEY=VALUE lines:

    TARGET          the microarchitecture to build for
    TARGET_STATUS   exact | fallback | host
    TARGET_NOTE     human-readable explanation

Why this exists
---------------
The build runs on the login node while the stack is meant for the compute nodes,
and the two are routinely different instance types. Spack will only emit code the
BUILD HOST can run, and `packages: all: target: [...]` is a *preference*, so a
target the host cannot support is silently dropped instead of failing. On the
cluster this was written for, the login node is skylake_avx512 and the workers are
cascadelake: asking for cascadelake quietly produced skylake_avx512 binaries.

Two directions, two very different consequences:

  * worker target is OLDER than the host (e.g. host cascadelake, worker skylake):
    the host can emit it, so build exactly for the worker. Correct and optimal.

  * worker target is NEWER than the host (this cluster): the host cannot emit it
    at all. Fall back to the host's own target. Those binaries still RUN on the
    worker -- a newer microarchitecture is a superset -- they just leave the newer
    instructions unused. That is a performance trade, not a correctness bug, but
    it must be said out loud rather than discovered in a benchmark. Build on a
    worker node instead if the last few percent matter.

The dangerous case the fallback prevents is the reverse of what people expect:
building for a target the compute node does NOT implement yields SIGILL at run
time, which is why the wanted target is never trusted blindly.
"""

import shlex
import sys

from spack.vendor.archspec import cpu


def main(argv):
    wanted = (argv[1] if len(argv) > 1 else "").strip()
    host = cpu.host()

    def emit(target, status, note):
        # Shell-quoted: the note contains spaces and parentheses, and the caller
        # consumes this with `eval`.
        print("TARGET=%s" % shlex.quote(target))
        print("TARGET_STATUS=%s" % shlex.quote(status))
        print("TARGET_NOTE=%s" % shlex.quote(note))

    if not wanted:
        emit(host.name, "host",
             "no target from detection; using this build host's own target")
        return

    if wanted not in cpu.TARGETS:
        emit(host.name, "host",
             "unknown target %r; using this build host's own target" % wanted)
        return

    target = cpu.TARGETS[wanted]
    if target <= host:
        emit(wanted, "exact",
             "build host (%s) can emit the compute-node target" % host.name)
    else:
        emit(host.name, "fallback",
             "build host (%s) cannot emit %s; building for %s instead, which RUNS on "
             "%s but does not use its newer instructions. Build on a worker node to "
             "target it exactly." % (host.name, wanted, host.name, wanted))


if __name__ == "__main__":
    main(sys.argv)
