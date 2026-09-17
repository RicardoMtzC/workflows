#!/usr/bin/env bash
# controller.sh — login-node setup for the Spack MPI-stack build.
#
# Runs on the login/controller node (the node with internet) before anything is
# submitted, and is idempotent: safe to re-run against an existing install.
#
#   1. bootstrap Spack at ${service_install_prefix}
#   2. warm the package repo (Spack v1.2 fetches it lazily on first use)
#   3. reconcile site externals against this image
#   4. register the system compiler that bootstraps the stack compiler
#   5. create and register the binary build cache mirror
#
# Consumes (from the sourced inputs.sh):
#   app_dir                        workflows/spack-builder/app, relative to the run dir
#   service_install_prefix         Spack root (must be on a shared filesystem)
#   service_spack_version          git tag; must be v1.x
#   service_buildcache_path        directory-backed binary mirror
#   service_use_public_buildcache  "true" to also register Spack's public binary cache
#
# Every config write is pinned to the *site* scope ($SPACK_ROOT/etc/spack) rather
# than the default user scope (~/.spack). Two reasons: the user scope would leak
# between separate install prefixes on the same account, and the site scope
# travels with the shared install so worker nodes read the same settings.

set -euo pipefail

SPACK_ROOT="${service_install_prefix:?service_install_prefix is required}"
SPACK_VERSION="${service_spack_version:?service_spack_version is required}"
BUILDCACHE_PATH="${service_buildcache_path:?service_buildcache_path is required}"
APP_DIR="${app_dir:?app_dir is required}"
MIRROR_NAME="local-buildcache"

log() { printf '\n=== [controller] %s ===\n' "$*"; }

# ---------------------------------------------------------------------------
# 0. Site facts. Printed before anything can fail, because every later question
#    ("why did it rebuild everything?", "why is the cache truncated?") is asked
#    from the log alone, on a cluster the reader may have no shell on. Free space
#    is here because a full filesystem is the usual cause of a half-written build
#    cache, and it is invisible in every other message.
# ---------------------------------------------------------------------------
log "Site facts"
printf 'host           : %s\n' "$(hostname)"
printf 'os / kernel    : %s / %s\n' \
       "$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")" "$(uname -r)"
printf 'cores / memory : %s / %s\n' "$(nproc)" "$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
# The CPU model, because the build host's microarchitecture decides what the
# whole stack is compiled for. Without it, "can this login node emit the compute
# nodes' target?" is answered by looking up instance-type trivia instead of by
# reading the log -- and an Intel login node with AMD compute nodes is the case
# that silently produces binaries that SIGILL (see resolve-target.py).
printf 'cpu            : %s\n' "$(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -1)"
printf 'spack root     : %s\n' "$SPACK_ROOT"
printf 'build cache    : %s\n' "$BUILDCACHE_PATH"
for _p in "$HOME" "$(dirname "$SPACK_ROOT")" "$BUILDCACHE_PATH"; do
  [ -d "$_p" ] && df -h "$_p" | tail -n +2
done | sort -u

# ---------------------------------------------------------------------------
# 1. Bootstrap Spack. Shallow-at-tag: the full history is ~1 GB and buys nothing.
# ---------------------------------------------------------------------------
if [ ! -d "$SPACK_ROOT/.git" ]; then
  log "Cloning Spack $SPACK_VERSION -> $SPACK_ROOT"
  mkdir -p "$(dirname "$SPACK_ROOT")"
  git clone -c feature.manyFiles=true -c advice.detachedHead=false \
      --quiet --depth 1 --branch "$SPACK_VERSION" \
      https://github.com/spack/spack.git "$SPACK_ROOT"
else
  # Compare commits, not `git describe` output: several tags can point at the
  # same commit (v1.2.2 and releases/latest do), so describe returns whichever
  # it likes and a name comparison re-checks-out the same commit every run.
  want="$(git -C "$SPACK_ROOT" rev-parse -q --verify "refs/tags/${SPACK_VERSION}^{commit}" 2>/dev/null || echo "")"
  have="$(git -C "$SPACK_ROOT" rev-parse HEAD)"
  if [ -z "$want" ] || [ "$want" != "$have" ]; then
    # Re-point an existing shallow clone without unshallowing it.
    log "Re-pointing $SPACK_ROOT to $SPACK_VERSION"
    git -C "$SPACK_ROOT" fetch --depth 1 origin \
        "refs/tags/${SPACK_VERSION}:refs/tags/${SPACK_VERSION}"
    git -C "$SPACK_ROOT" checkout "$SPACK_VERSION"
  else
    log "Spack $SPACK_VERSION already present at $SPACK_ROOT"
  fi
fi

# shellcheck disable=SC1091
. "$SPACK_ROOT/share/spack/setup-env.sh"
SPACK_SEEN="$(spack --version)"
log "Spack version: $SPACK_SEEN (build host target: $(spack arch -t 2>/dev/null || echo unknown))"

case "$SPACK_SEEN" in
  1.*) : ;;
  *) echo "::error title=Error::This workflow requires Spack v1.x (compilers are dependencies there); got $SPACK_SEEN" >&2
     exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 2. Warm the package repo. Spack v1.2 clones spack-packages on first use; doing
#    it here keeps that network fetch on the node that is guaranteed internet,
#    and off whatever node runs detection or the build.
# ---------------------------------------------------------------------------
log "Warming the package repository"
# Spack clones spack-packages here (20k objects). Git writes a progress line per
# percent to stderr even with no TTY, and those ~200 lines are the bulk of this
# job's log -- they bury the externals, the compiler and the cache inventory
# that a reader actually came for. Keep them, but only show them if it fails.
if ! spack list --count >/dev/null 2>package-repo.log; then
  echo "::error title=Error::could not fetch the Spack package repository" >&2
  tail -n 40 package-repo.log >&2
  exit 1
fi
spack repo list

# ---------------------------------------------------------------------------
# 3. Site externals. The checked-in packages.yaml is the baseline — what MUST be
#    external on any image so the MPIs bind to the real launcher. `external find`
#    then reconciles it against what this image actually ships.
# ---------------------------------------------------------------------------
log "Registering site externals"
mkdir -p "$SPACK_ROOT/etc/spack"
# The baseline goes to the lower-precedence spack scope and `external find`
# writes the site scope, so a real discovery always wins over the baseline.
cp "$APP_DIR/packages.yaml" "$SPACK_ROOT/etc/spack/packages.yaml"

# slurm and rdma-core must match the running cluster and kernel, so they are
# pinned not-buildable. libfabric and ucx are registered but left buildable on
# purpose: the fabric profile decides whether to bind the vendor library (the
# aws fragment pins it external) or let Spack build one with its own variants.
spack external find --scope site --not-buildable slurm rdma-core || true
spack external find --scope site libfabric ucx || true

# gmake is a build tool, not part of the delivered stack, and compiling it is
# where padded install paths bite: with config:install_tree:padded_length set,
# gmake@4.4.1's config.status intermittently dies with
#   mv: cannot move './confXXXXXX/out' to 'doc/Makefile': No such file or directory
#   config.status: error: could not create doc/Makefile
# It is genuinely intermittent rather than deterministic -- the same padded build
# failed on two clusters and succeeded on a third attempt with identical settings
# -- so registering the system make and letting Spack reuse it removes the
# flakiest package from the build entirely.
#
# Deliberately NOT --not-buildable: if some package ever needs a newer make than
# the image ships, Spack should still be free to build one rather than failing to
# concretize.
spack external find --scope site gmake || true

# Drop any external that has libraries but no headers. `external find` detects a
# package from its libraries, but Spack then compiles against it -- and an image
# that ships the runtime without the -devel package yields an external that looks
# valid and fails at configure time. Seen three times now (slurm, rdma-core,
# libfabric), and it is image-specific: the AWS EFA libfabric under
# /opt/amazon/efa has headers, the GCE /usr one does not. So it must be probed
# here rather than decided in a fabric fragment.
log "Pruning externals that lack development headers"
spack python "$APP_DIR/prune-headerless-externals.py" \
    "$SPACK_ROOT/etc/spack/site/packages.yaml" 

# ---------------------------------------------------------------------------
# 4. System compiler. This is only the bootstrap compiler: it builds the stack
#    compiler that spack.yaml requires. build.sh registers that one afterwards.
# ---------------------------------------------------------------------------
log "Registering system compilers"
spack compiler find --scope site
spack compiler list

# ---------------------------------------------------------------------------
# 5. Binary build cache. Unsigned on purpose: this is a private, filesystem-local
#    mirror, and demanding a GPG keyring would make every fresh cluster a manual
#    step for no security gain on a path only this account can write.
# ---------------------------------------------------------------------------
log "Configuring build cache at $BUILDCACHE_PATH"
mkdir -p "$BUILDCACHE_PATH"
spack mirror remove --scope site "$MIRROR_NAME" >/dev/null 2>&1 || true
spack mirror add --scope site --unsigned "$MIRROR_NAME" "file://${BUILDCACHE_PATH}"

# Spack cannot index a mirror with no entries in it ("Failed to get list of
# entries"), so on a cold cache the concretizer warns "cannot be used in
# concretization (no index found)" and ignores the mirror. That is expected and
# harmless — build.sh creates the index when it pushes the first package. Only
# refresh it here when there is already something to index.
# Test for any content rather than a specific layout directory: Spack 1.2 writes
# a v3/ + blobs/ tree, older versions wrote build_cache/, and hardcoding either
# silently skips the refresh on the other.
if [ -n "$(ls -A "$BUILDCACHE_PATH" 2>/dev/null)" ]; then
  # Report the outcome instead of swallowing it: a mirror that fails to index is
  # silently ignored by the concretizer, and the only symptom is that everything
  # rebuilds. That has to be visible in the log.
  if spack buildcache update-index "$MIRROR_NAME"; then
    log "Build cache index refreshed"
  else
    echo "::warning::could not index the build cache at $BUILDCACHE_PATH; the concretizer will ignore it and every package will be compiled" >&2
  fi
else
  log "Build cache is empty (cold); its index appears after the first push"
fi

# What is actually in the cache, and is it intact? This is the report that tells
# a reader with no shell on the cluster whether a redeployed cache arrived whole.
log "Build cache inventory"
python3 "$APP_DIR/inspect-buildcache.py" "$BUILDCACHE_PATH" || true

if [ "${service_use_public_buildcache:-false}" = "true" ]; then
  log "Registering Spack's public binary cache"
  spack mirror remove --scope site spack-public-binaries >/dev/null 2>&1 || true
  spack mirror add --scope site --unsigned --type binary \
      spack-public-binaries "https://binaries.spack.io/v${SPACK_SEEN%.*}" || true
fi
spack mirror list

log "Controller setup complete"
