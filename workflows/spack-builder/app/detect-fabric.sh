#!/usr/bin/env bash
# detect-fabric.sh
# Detects (1) the cloud provider and (2) whether RDMA-class fabric hardware is
# present, then prints a fabric profile keyword and exports helper vars.
#
# Output: writes KEY=VALUE lines to $1 (default: ./fabric.env), sourceable by build.sh.
#   CLOUD           = aws|azure|gcp|oracle|unknown
#   FABRIC_PROFILE  = aws|azure|gcp|oracle|generic   (which fabric fragment to use)
#   HAS_EFA         = 0|1
#   HAS_VERBS       = 0|1   (InfiniBand / RoCE verbs device present)
#   EFA_PREFIX      = path to vendor libfabric (AWS), if found
#   HAS_GPU         = 0|1   (NVIDIA GPU present)
#   GPU_ARCH        = detected CUDA compute capability as spack cuda_arch (e.g. 80), or empty
#   CUDA_PREFIX     = path to an existing CUDA toolkit, if found (else empty -> Spack builds it)
#   BUILD_TARGET    = spack microarch target of THIS node (e.g. skylake_avx512)
#   BUILD_ARCH      = full spack arch triple of THIS node
#   DETECT_HOST     = hostname this ran on
#   DETECT_NPROC    = cores seen here
#
# The hardware probe is authoritative. Cloud identity only breaks ties on which
# vendor libfabric to prefer. An instance on AWS with no EFA -> generic profile.
# GPU detection is reported but only *acted on* when the caller sets BUILD_GPU=1.

set -euo pipefail
# script_submitter runs a script assembled as `inputs.sh + this file`, so there
# are no positional arguments in the workflow path -- fall back to the
# fabric_env variable that inputs.sh exports.
OUT="${1:-${fabric_env:-./fabric.env}}"

# Written first so a cancel at any later point finds it. Detection touches
# nothing that needs undoing; the file exists because script_submitter warns
# when its cleanup script is missing.
cat > cancel.sh <<'CANCEL'
#!/bin/bash
echo "[cancel] fabric detection stopped; nothing to clean up"
exit 0
CANCEL
chmod +x cancel.sh

log() { printf '[detect] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Cloud identity via metadata endpoints (short timeouts; all are link-local).
# ---------------------------------------------------------------------------
detect_cloud() {
  # AWS IMDSv2 (token-based) then IMDSv1 fallback.
  local t
  if t=$(curl -s --max-time 1 -X PUT "http://169.254.169.254/latest/api/token" \
          -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) && [ -n "$t" ]; then
    if curl -s --max-time 1 -H "X-aws-ec2-metadata-token: $t" \
         "http://169.254.169.254/latest/meta-data/instance-id" >/dev/null 2>&1; then
      echo aws; return
    fi
  fi
  # Azure IMDS requires the Metadata:true header and a distinct path.
  if curl -s --max-time 1 -H "Metadata:true" \
       "http://169.254.169.254/metadata/instance?api-version=2021-02-01" \
       >/dev/null 2>&1; then
    echo azure; return
  fi
  # GCP metadata server, distinct host header.
  if curl -s --max-time 1 -H "Metadata-Flavor: Google" \
       "http://metadata.google.internal/computeMetadata/v1/instance/id" \
       >/dev/null 2>&1; then
    echo gcp; return
  fi
  # Oracle OCI instance metadata (v2).
  if curl -s --max-time 1 -H "Authorization: Bearer Oracle" \
       "http://169.254.169.254/opc/v2/instance/" >/dev/null 2>&1; then
    echo oracle; return
  fi
  echo unknown
}

# ---------------------------------------------------------------------------
# 2. Hardware probes — independent of cloud identity.
# ---------------------------------------------------------------------------
probe_efa() {
  # EFA shows up as an ib_device via the efa kernel driver, and the installer
  # drops libfabric under /opt/amazon/efa.
  if [ -d /sys/class/infiniband ] && ls /sys/class/infiniband/ 2>/dev/null | grep -qi '^rdmap\|efa'; then
    return 0
  fi
  # fi_info from the vendor libfabric is the definitive check when present.
  if [ -x /opt/amazon/efa/bin/fi_info ] && \
     /opt/amazon/efa/bin/fi_info -p efa >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

probe_verbs() {
  # Any verbs-capable device (Mellanox IB/RoCE on Azure HB/ND, Oracle cluster
  # networks, GCP RoCE) exposes /sys/class/infiniband/<dev> with a uverbs char dev.
  if [ -d /sys/class/infiniband ] && [ -n "$(ls -A /sys/class/infiniband 2>/dev/null)" ]; then
    # Exclude the pure-EFA case (efa has no traditional verbs QP semantics for UCX).
    for d in /sys/class/infiniband/*; do
      [ -e "$d" ] || continue
      case "$(basename "$d")" in
        efa*) continue ;;
        *)    return 0 ;;
      esac
    done
  fi
  # ibv_devinfo, if the rdma-core userspace is installed.
  if command -v ibv_devinfo >/dev/null 2>&1 && ibv_devinfo >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# GPU detection. Returns 0 if an NVIDIA GPU is present. Sets globals GPU_ARCH,
# CUDA_PREFIX as side effects.
GPU_ARCH=""; CUDA_PREFIX=""
probe_gpu() {
  local found=1
  # PCI enumeration works even without the driver loaded.
  if command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi 'nvidia'; then
    found=0
  fi
  # nvidia-smi is authoritative when the driver is up, and gives the arch directly.
  # It must be checked by EXIT STATUS, not by whether it printed something: with
  # the toolkit installed but no GPU (or no driver) it exits 9 and writes its
  # complaint to STDOUT, so `2>/dev/null` does not hide it. Capturing that blindly
  # set HAS_GPU=1 and made the error text the cuda_arch on a GPU-less node.
  if command -v nvidia-smi >/dev/null 2>&1; then
    local cc
    # compute_cap is like "8.0"; strip the dot -> spack cuda_arch "80".
    if cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | tr -d ' ') \
       && [[ "$cc" =~ ^[0-9]+\.[0-9]+$ ]]; then
      GPU_ARCH="${cc//./}"
      found=0
    fi
  fi
  # Locate an existing CUDA toolkit so we can register it external (faster builds).
  for p in /usr/local/cuda "${CUDA_HOME:-}" /opt/cuda; do
    [ -n "$p" ] || continue
    if [ -x "$p/bin/nvcc" ]; then CUDA_PREFIX="$(cd "$p" && pwd)"; break; fi
  done
  return $found
}

# ---------------------------------------------------------------------------
# 2b. Microarchitecture of THIS node.
# The build runs on the login node, which is frequently a different instance
# type from the compute nodes. `spack arch -t` there would bake the login
# node's ISA into every package -- either leaving compute performance on the
# table or emitting instructions that SIGILL on the worker. So the whole reason
# this script is submitted to a worker is to carry that value back.
# ---------------------------------------------------------------------------
probe_target() {
  local root="${service_install_prefix:-}"
  if [ -z "$root" ] || [ ! -f "$root/share/spack/setup-env.sh" ]; then
    log "WARNING: no Spack at '${root:-<unset>}'; cannot report a build target"
    return 0
  fi
  # shellcheck disable=SC1091
  . "$root/share/spack/setup-env.sh"
  BUILD_TARGET="$(spack arch -t 2>/dev/null || echo "")"
  BUILD_ARCH="$(spack arch 2>/dev/null || echo "")"
  log "build target: ${BUILD_TARGET:-<unknown>} (arch=${BUILD_ARCH:-<unknown>})"
}

# ---------------------------------------------------------------------------
# 3. Decide the profile.
# ---------------------------------------------------------------------------
BUILD_TARGET=""; BUILD_ARCH=""
probe_target
log "detected on host $(hostname) with $(nproc) cores"
CLOUD=$(detect_cloud)
log "cloud identity: $CLOUD"

HAS_EFA=0; HAS_VERBS=0; EFA_PREFIX=""; HAS_GPU=0
if probe_efa;   then HAS_EFA=1;   EFA_PREFIX="/opt/amazon/efa"; log "EFA fabric detected"; fi
if probe_verbs; then HAS_VERBS=1; log "verbs (IB/RoCE) fabric detected"; fi
if probe_gpu;   then HAS_GPU=1;   log "NVIDIA GPU detected (arch=${GPU_ARCH:-unknown}, cuda=${CUDA_PREFIX:-none})"; fi

# Profile selection: hardware first, cloud identity as the tie-breaker.
FABRIC_PROFILE="generic"
if   [ "$HAS_EFA" -eq 1 ]; then
  FABRIC_PROFILE="aws"                     # OFI/EFA path regardless of reported cloud
elif [ "$HAS_VERBS" -eq 1 ]; then
  case "$CLOUD" in
    azure)  FABRIC_PROFILE="azure"  ;;     # UCX + verbs, Mellanox tuned
    oracle) FABRIC_PROFILE="oracle" ;;     # UCX + verbs on cluster network
    gcp)    FABRIC_PROFILE="gcp"    ;;     # verbs/RoCE path
    *)      FABRIC_PROFILE="azure"  ;;     # generic verbs -> UCX profile
  esac
elif [ "$CLOUD" = "gcp" ]; then
  # GCP H3/C3 Titanium exposes OFI without a classic verbs device; prefer OFI.
  FABRIC_PROFILE="gcp"
fi

log "selected fabric profile: $FABRIC_PROFILE"

cat > "$OUT" <<EOF
CLOUD=$CLOUD
FABRIC_PROFILE=$FABRIC_PROFILE
HAS_EFA=$HAS_EFA
HAS_VERBS=$HAS_VERBS
EFA_PREFIX=$EFA_PREFIX
HAS_GPU=$HAS_GPU
GPU_ARCH=$GPU_ARCH
CUDA_PREFIX=$CUDA_PREFIX
BUILD_TARGET=$BUILD_TARGET
BUILD_ARCH=$BUILD_ARCH
DETECT_HOST=$(hostname)
DETECT_NPROC=$(nproc)
EOF
log "wrote $OUT"
