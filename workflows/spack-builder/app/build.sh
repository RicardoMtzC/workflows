#!/usr/bin/env bash
# build.sh — render, concretize, install and publish the Spack MPI stack.
#
# Runs on the build node (the login node by default: it has internet for source
# fetches and is not subject to a queue walltime). It does NOT bootstrap Spack
# and it does NOT probe hardware -- controller.sh has already set up the install
# and detect-fabric.sh has already reported what the COMPUTE nodes look like.
# This script only consumes those results.
#
# Consumes (from the sourced inputs.sh):
#   app_dir                  workflows/spack-builder/app, relative to the run dir
#   service_install_prefix   Spack root
#   service_buildcache_path  binary mirror to install from and push to
#   service_build_jobs       -j for builds
#   service_build_gpu        "true" to add the CUDA-aware path
#   fabric_env               path to the fabric.env produced by detection/overrides
#
# The stack compiler version is NOT an input: it is read from
# templates/spack.yaml.in so the environment definition stays the only place it
# is written down.

set -euo pipefail
set -o pipefail

APP_DIR="${app_dir:?app_dir is required}"
SPACK_ROOT="${service_install_prefix:?service_install_prefix is required}"
BUILDCACHE_PATH="${service_buildcache_path:?service_buildcache_path is required}"
JOBS="${service_build_jobs:-$(nproc)}"
BUILD_GPU="${service_build_gpu:-false}"
FABRIC_ENV="${fabric_env:-${PWD}/fabric.env}"
ENV_DIR="${env_dir:-${PWD}/spack-env}"
MIRROR_NAME="local-buildcache"

log() { printf '\n=== [build] %s ===\n' "$*"; }

# Record the real exit status where the workflow can read it.
# script_submitter's UNSCHEDULED path (scheduler: false -> ssh_job) detaches this
# script with setsid and then polls `kill -0`, so it can see that the process
# ended but never why: a failed build otherwise reports a COMPLETED run. Verified
# on gce2 -- ucx failed to compile, build.sh aborted before the push and module
# steps, and the platform still recorded the run as completed.
BUILD_STATUS_FILE="${PWD}/BUILD_STATUS"
rm -f "$BUILD_STATUS_FILE"
trap 'rc=$?; printf "%s\n" "$rc" > "$BUILD_STATUS_FILE";
      [ "$rc" -eq 0 ] || echo "::error title=Error::build.sh exited $rc -- see the last === [build] === section above for the step that failed"' EXIT

# ---------------------------------------------------------------------------
# 0. Cancellation hook, written FIRST so a cancel at any later moment finds it.
#    script_submitter runs this on teardown; `spack install` leaves a lock in
#    the environment that would block the next run if it is killed mid-flight.
# ---------------------------------------------------------------------------
cat > cancel.sh <<EOF
#!/bin/bash
echo "[cancel] stopping spack build"
pkill -u "\$(id -u)" -f "spack-python|spack install" 2>/dev/null || true
rm -f "${ENV_DIR}/.lock" "${ENV_DIR}/spack.lock.lock" 2>/dev/null || true
exit 0
EOF
chmod +x cancel.sh

# shellcheck disable=SC1091
. "$SPACK_ROOT/share/spack/setup-env.sh"
log "Spack $(spack --version) at $SPACK_ROOT, -j${JOBS}"

# ---------------------------------------------------------------------------
# 1. Load the resolved profile. Produced either by detect-fabric.sh on a worker
#    or synthesized by resolve-profile.sh from complete overrides.
# ---------------------------------------------------------------------------
[ -f "$FABRIC_ENV" ] || { echo "::error title=Error::No fabric profile at $FABRIC_ENV" >&2; exit 1; }
# shellcheck disable=SC1091
. "$FABRIC_ENV"
FRAG="$APP_DIR/templates/fabric-${FABRIC_PROFILE}.yaml"
[ -f "$FRAG" ] || { echo "::error title=Error::No fabric fragment $FRAG" >&2; exit 1; }
log "Fabric profile: $FABRIC_PROFILE (cloud=${CLOUD:-?}, detected on ${DETECT_HOST:-?})"

# Target: what detection saw on a COMPUTE node, reconciled against what this
# build host can actually emit. `packages: all: target:` is only a preference, so
# an unsupported target is silently dropped rather than rejected -- resolve-target.py
# makes that decision explicit and loud. See its docstring for the two directions.
WANTED_TARGET="${OVERRIDE_TARGET:-${BUILD_TARGET:-}}"
# Captured rather than `eval "$(...)"`: the resolver now exits non-zero when no
# target can serve both machines, and a command substitution inside eval swallows
# that -- eval would succeed on empty output and leave TARGET unset.
if ! TARGET_RESOLUTION="$(spack python "$APP_DIR/resolve-target.py" "$WANTED_TARGET")"; then
  echo "::error title=Error::cannot choose a build target for compute node '${WANTED_TARGET}' from this build host" >&2
  exit 1
fi
eval "$TARGET_RESOLUTION"
case "$TARGET_STATUS" in
  exact)    log "Target: $TARGET (matches compute node ${DETECT_HOST:-?})" ;;
  fallback) log "::warning::Target: $TARGET -- $TARGET_NOTE" ;;
  common)   log "::warning::Target: $TARGET -- $TARGET_NOTE" ;;
  host)     log "::warning::Target: $TARGET -- $TARGET_NOTE" ;;
esac

# --- GPU decision ----------------------------------------------------------
GPU_ACTIVE=0
EFFECTIVE_ARCH=""
if [ "$BUILD_GPU" = "true" ]; then
  if [ "${HAS_GPU:-0}" = "1" ] && [ -n "${GPU_ARCH:-}" ]; then
    GPU_ACTIVE=1; EFFECTIVE_ARCH="$GPU_ARCH"
    log "GPU path ENABLED: ${GPU_COUNT:-?}x ${GPU_NAME:-NVIDIA GPU}, cuda_arch=${EFFECTIVE_ARCH}, driver ${DRIVER_VERSION:-?}, driver CUDA ${CUDA_VERSION:-?}, toolkit ${CUDA_PREFIX:-<spack-built>} (nvcc ${NVCC_VERSION:-?})"
  else
    # Refuse rather than quietly build the CPU stack. Someone who ticked "build
    # the GPU path" and waited two hours for a stack with no CUDA in it has been
    # given the wrong answer slowly, which is worse than the right answer now.
    # The usual causes are an inspection job that landed on a GPU-less node, and
    # a node whose GPUs are hidden from the job because no GPU was requested.
    echo "::error title=Error::GPU build requested but the inspected node reported no usable GPU (HAS_GPU=${HAS_GPU:-0}, cuda_arch='${GPU_ARCH:-}', detected on ${DETECT_HOST:-?}). See the [detect] section above for what nvidia-smi said. Request a GPU for the inspection job (cluster.slurm.gpus), point it at a partition whose nodes have one, or turn off 'Build the GPU path'." >&2
    exit 1
  fi
fi

if [ "$GPU_ACTIVE" = "1" ] && [ -n "${CUDA_PREFIX:-}" ]; then
  # nvcc is the authority on the toolkit version; NVCC_VERSION from detection is
  # the same number read on the compute node, kept as the fallback.
  CUDA_VER="$("$CUDA_PREFIX/bin/nvcc" --version 2>/dev/null |
              grep -oE 'release [0-9]+\.[0-9]+' | awk '{print $2}')"
  CUDA_VER="${CUDA_VER:-${NVCC_VERSION:-}}"
  log "Registering external CUDA ${CUDA_VER:-<unknown version>} at $CUDA_PREFIX"
  [ -n "$CUDA_VER" ] || { echo "::error title=Error::cannot read a CUDA version from $CUDA_PREFIX/bin/nvcc" >&2; exit 1; }

  # Written as a YAML file rather than passed to `spack config add` as a path
  # expression. That form cannot express this value: `config add` splits its
  # argument on ':', so the colons inside `spec:` and `prefix:` are read as more
  # path components and Spack rejects the result with
  #   {'[{spec': {' cuda@13.2, prefix': '/usr/local/cuda}]'}} is not of type 'array'
  # (gce2 run moral-ghost -- the first run ever to reach this line).
  cat > "${PWD}/cuda-external.yaml" <<YAML
packages:
  cuda:
    buildable: false
    externals:
    - spec: cuda@${CUDA_VER}
      prefix: ${CUDA_PREFIX}
YAML
  spack config --scope site add -f "${PWD}/cuda-external.yaml"
  spack config --scope site get packages | sed -n '/^  cuda:/,/^  [a-z]/p'
fi

# ---------------------------------------------------------------------------
# 2. Render spack.yaml from the template + the fabric fragment.
#    render-env.py runs under Spack's bundled Python so PyYAML is available
#    without adding a dependency to the cluster image. It is a real file because
#    `spack python -` does not read a script from stdin.
# ---------------------------------------------------------------------------
log "Rendering environment -> $ENV_DIR/spack.yaml"
mkdir -p "$ENV_DIR"
MODULE_ROOT="$SPACK_ROOT/share/spack/modules"

RENDER_OUT="$(spack python "$APP_DIR/render-env.py" \
      "$FRAG" "$APP_DIR/templates/spack.yaml.in" "$ENV_DIR/spack.yaml" \
      "$TARGET" "$GPU_ACTIVE" "$EFFECTIVE_ARCH" "$MODULE_ROOT")"
echo "$RENDER_OUT"
GCC_SPEC="$(printf '%s\n' "$RENDER_OUT" | sed -n 's/^GCC_SPEC=//p')"
[ -n "$GCC_SPEC" ] || { echo "::error title=Error::render-env.py did not report a stack compiler" >&2; exit 1; }
log "Stack compiler (from spack.yaml): $GCC_SPEC"

# ---------------------------------------------------------------------------
# 3. Build the stack compiler with the system compiler, then register it.
#    This must happen OUTSIDE the environment: the environment requires this
#    compiler for every package, so it cannot also build it.
# ---------------------------------------------------------------------------
# Resolve the BUILT gcc by filtering to the install tree. `spack location -i
# "$GCC_SPEC"` cannot be used here: once the compiler is registered below there
# are two gcc@<version> entries -- the built package and the external entry that
# points at its prefix -- and location fails with "matches multiple packages".
gcc_built_prefix() {
  spack find --format '{prefix}' "$GCC_SPEC" 2>/dev/null | grep "^${SPACK_ROOT}/opt/" | head -1
}

if [ -z "$(gcc_built_prefix)" ]; then
  log "Installing stack compiler $GCC_SPEC (long; cached after the first run)"
  spack install --no-check-signature -j"$JOBS" "$GCC_SPEC"
  # --allow-missing: the push walks the whole DAG, and when gcc itself came from
  # the build cache its build-only dependencies were never installed. Without the
  # flag that prints a 27-line "Error: ... PackageNotInstalledError" block for a
  # push that did exactly what it should.
  spack buildcache push --unsigned --update-index --private --allow-missing "$MIRROR_NAME" "$GCC_SPEC" || true
else
  log "Stack compiler $GCC_SPEC already installed"
fi

GCC_PREFIX="$(gcc_built_prefix)"
[ -n "$GCC_PREFIX" ] || { echo "::error title=Error::$GCC_SPEC not present under $SPACK_ROOT/opt after install" >&2; exit 1; }

# Register the built compiler as an external. REQUIRED, not cosmetic. Without it
# the environment fails to concretize with
#   Only external, or concrete, compilers are allowed for the c language
#   Cannot use gcc for the c virtual, but that is required
# even though `spack compiler list` already lists the built gcc.
#
# The governing rule is Spack's own solver, concretize.lp (v1.2.2, ~line 1930):
#
#   error(10, "Only external, or concrete, compilers are allowed for the {0} language", Language)
#     :- provider(ProviderNode, node(_, Language)), language(Language), build(ProviderNode).
#
# It names no package: it is scoped to the language virtuals (c, cxx, fortran,
# cuda-lang, hip-lang) and fires whenever a node PROVIDING one of them would have
# to be built in that solve. So it is not an Intel-specific quirk, though
# intel-oneapi-mpi is where it was observed here -- intel-oneapi-compilers has an
# explicit `depends_on gcc`, which forces a gcc node that must be built. For
# other packages an already-installed gcc can often be reused as "concrete" and
# the rule never fires, so which specs break without this registration depends on
# what reuse can supply. Maintainers have reported hitting it with OpenMPI too.
#
# "External" here does not mean "installed outside Spack" -- the prefix points
# back into Spack's own install tree. It means "a compiler Spack may use as a
# toolchain". Registering it adds a second gcc entry sharing that prefix, which
# is expected, and is why gcc_built_prefix() exists rather than
# `spack location -i` (which then fails with "matches multiple packages").
#
# Test for the external ENTRY (by prefix), not for the name in `spack compiler
# list`: the installed package already appears there, so a name check would
# always skip the registration and reintroduce the concretization failure.
if ! spack config --scope site get packages 2>/dev/null | grep -q "$GCC_PREFIX"; then
  log "Registering $GCC_SPEC as a site compiler"
  spack compiler find --scope site "$GCC_PREFIX"
fi
spack compiler list

# ---------------------------------------------------------------------------
# 4. Concretize. This is the gate: everything above is setup, and a clean DAG
#    here is what says the spec set is actually coherent.
# ---------------------------------------------------------------------------
log "Concretizing"
spack -e "$ENV_DIR" concretize -f
spack -e "$ENV_DIR" find -c || true

# Which of those specs the build cache can actually supply. Printed here, before
# the install, because it is the difference between "this run takes four minutes"
# and "this run takes two hours" -- and because a miss names the cached spec it
# collided with, which is what distinguishes a damaged cache from one built for a
# different fabric profile, image or microarchitecture.
log "Build cache coverage for this environment"
python3 "$APP_DIR/inspect-buildcache.py" "$BUILDCACHE_PATH" --lock "$ENV_DIR/spack.lock" || true

if [ "${service_concretize_only:-false}" = "true" ]; then
  log "concretize_only set; stopping before the install"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Install, then publish every result to the build cache. --private is
#    required: intel-oneapi-mpi is non-redistributable and is skipped silently
#    without it, which would leave a hole in the cache exactly where the
#    slowest-to-fetch package is.
# ---------------------------------------------------------------------------
log "Installing stack (this is the long part)"
INSTALL_LOG="${PWD}/spack-install.log"
if ! spack -e "$ENV_DIR" install --no-check-signature -j"$JOBS" 2>&1 | tee "$INSTALL_LOG"; then
  # Spack points at a per-package build log that lives on the node. Nobody
  # reading the workflow log has a shell there, so inline the tails: without
  # this, every compile failure costs a round trip to the cluster to learn which
  # header was missing.
  log "::error title=Error::spack install failed; tails of the failing build logs follow"
  grep -oE 'See build log for details: .*' "$INSTALL_LOG" | awk '{print $NF}' | sort -u |
  while read -r build_log; do
    printf '\n----- last 80 lines of %s -----\n' "$build_log"
    tail -n 80 "$build_log" 2>/dev/null || echo "(build log not readable)"
  done
  exit 1
fi

# Did the cache do its job? The forecast above is a prediction; this is what
# happened, and the two disagreeing is itself worth seeing.
# Every number comes from this one install log, so they add up. Mixing in a
# `spack find` count does not: it reports the environment's view (43 on aws)
# against a DAG the forecast counted whole (66), and two disagreeing totals in
# one log read as a bug in the run. "fetching from build cache" is Spack 1.2's
# wording for a binary install, "==> Installing <name>-<version>-<hash>" for a
# source build, and "[e]" for an external.
extracted="$(grep -c 'fetching from build cache' "$INSTALL_LOG" || true)"
compiled="$(grep -cE '^==> Installing ' "$INSTALL_LOG" || true)"
external="$(grep -cE '^\[e\] ' "$INSTALL_LOG" || true)"
log "Install complete: ${extracted} specs from the build cache, ${compiled} compiled from source, ${external} external"

log "Pushing to the build cache at $BUILDCACHE_PATH"
spack -e "$ENV_DIR" buildcache push --unsigned --update-index --private --allow-missing "$MIRROR_NAME" || true

# ---------------------------------------------------------------------------
# 6. Modules.
# ---------------------------------------------------------------------------
log "Refreshing modules"
# Externals have no modulefile, and `autoload: direct` would still list them as
# requirements -- one missing requirement aborts the entire `module load`, leaving
# the user silently on the system MPI. Exclude exactly what this site resolved as
# external.
MODULE_EXCLUDES="$(spack python "$APP_DIR/external-modules.py" "$ENV_DIR/spack.lock")"
log "Excluding from modules (externals): $MODULE_EXCLUDES"
spack -e "$ENV_DIR" config add "modules:default:tcl:exclude:[${MODULE_EXCLUDES}]"
spack -e "$ENV_DIR" module tcl refresh --delete-tree -y

MODROOT="$MODULE_ROOT/$(spack arch)"
cat <<EOF

=== DONE ===
Stack built for target: $TARGET  (fabric=$FABRIC_PROFILE, cloud=${CLOUD:-?})
GPU path: $( [ "$GPU_ACTIVE" = "1" ] && echo "ENABLED (cuda_arch=${EFFECTIVE_ARCH})" || echo "disabled" )

    export MODULEPATH=$MODROOT:\$MODULEPATH
    module load openmpi      # or mpich / intel-oneapi-mpi
    module load gromacs

(There is no gcc module: the stack compiler is registered as an external and
externals are excluded from the module tree. Use 'spack load gcc' if you need
the compiler itself on PATH.)
EOF
