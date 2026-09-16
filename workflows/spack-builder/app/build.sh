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
eval "$(spack python "$APP_DIR/resolve-target.py" "$WANTED_TARGET")"
case "$TARGET_STATUS" in
  exact)    log "Target: $TARGET (matches compute node ${DETECT_HOST:-?})" ;;
  fallback) log "::warning::Target: $TARGET -- $TARGET_NOTE" ;;
  host)     log "::warning::Target: $TARGET -- $TARGET_NOTE" ;;
esac

# --- GPU decision ----------------------------------------------------------
GPU_ACTIVE=0
EFFECTIVE_ARCH=""
if [ "$BUILD_GPU" = "true" ]; then
  if [ "${HAS_GPU:-0}" = "1" ] && [ -n "${GPU_ARCH:-}" ]; then
    GPU_ACTIVE=1; EFFECTIVE_ARCH="$GPU_ARCH"
    log "GPU path ENABLED (cuda_arch=$EFFECTIVE_ARCH, cuda_prefix=${CUDA_PREFIX:-<spack-built>})"
  else
    log "WARNING: GPU requested but none detected (HAS_GPU=${HAS_GPU:-0}, arch='${GPU_ARCH:-}'). Building CPU-only."
  fi
fi

if [ "$GPU_ACTIVE" = "1" ] && [ -n "${CUDA_PREFIX:-}" ]; then
  log "Registering external CUDA at $CUDA_PREFIX"
  CUDA_VER="$("$CUDA_PREFIX/bin/nvcc" --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | awk '{print $2}')"
  spack config --scope site add "packages:cuda:externals:[{spec: cuda@${CUDA_VER:-12.4.0}, prefix: $CUDA_PREFIX}]"
  spack config --scope site add "packages:cuda:buildable:false"
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
  spack buildcache push --unsigned --update-index --private "$MIRROR_NAME" "$GCC_SPEC" || true
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
spack -e "$ENV_DIR" install --no-check-signature -j"$JOBS"

log "Pushing to the build cache at $BUILDCACHE_PATH"
spack -e "$ENV_DIR" buildcache push --unsigned --update-index --private "$MIRROR_NAME" || true

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
