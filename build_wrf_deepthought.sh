#!/bin/bash
#SBATCH --job-name=build_wrf
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=02:00:00
#SBATCH --output=build_wrf_%j.log
#SBATCH --partition=general         # compute partition; check with: sinfo
#
# Download and compile WRF (2D-UrbFrac-AH, branch dev-v4.8-Flinders)
# on Flinders University DeepThought HPC.
#
# Usage (WRF is downloaded into the folder containing this script):
#   cd /path/to/this/folder
#   bash build_wrf_deepthought.sh
#
# The script runs in two stages:
#   1. On the login node : download the source + submodules (needs internet),
#                          then submit itself with sbatch.
#   2. On a general node : load modules, configure and compile (no internet needed).
# Progress of stage 2: squeue -u $USER ; tail -f build_wrf_<jobid>.log
#
# Before running, check the module names below with `module avail WRF`
# and edit the USER SETTINGS section if needed.

set -euo pipefail

########################## USER SETTINGS ##########################
# Where to put the source code and build: the folder this script is in.
# Under sbatch the script runs from a spool copy, so use the submit directory.
if [[ $(basename "${BASH_SOURCE[0]}") == slurm_script && -n ${SLURM_SUBMIT_DIR:-} ]]; then
  WORKDIR=${WORKDIR:-$SLURM_SUBMIT_DIR}
else
  WORKDIR=${WORKDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
fi

# Repository and branch (both repos are public, no SSH key needed)
WRF_REPO=https://github.com/xuelingbo/WRF-2D-UrbFrac-AH.git
WRF_BRANCH=dev-v4.8-Flinders
WRF_DIR=$WORKDIR/WRF-v4.8-Flinders

# Modules: DeepThought's own WRF module is loaded only to get a consistent
# compiler + MPI + NetCDF toolchain; we compile our modified source ourselves.
# Pin a version if several exist (check with `module avail WRF`), e.g. WRF/4.5.2
MODULES=(
  WRF
)

# configure option: 34 = GNU (gfortran/gcc) dmpar
CONFIG_OPT=34
NEST_OPT=${NEST_OPT:-1}            # 1 = basic nesting

NPROC=${SLURM_CPUS_PER_TASK:-8}    # parallel compile jobs
###################################################################

log() { echo -e "\n==== [$(date '+%F %T')] $* ====\n"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ================= Stage 1: download on the login node =================
if [[ -z ${SLURM_JOB_ID:-} ]]; then
  command -v git >/dev/null || die "'git' not found on the login node"
  mkdir -p "$WORKDIR"
  if [[ -d $WRF_DIR/.git ]]; then
    log "Updating existing clone in $WRF_DIR"
    git -C "$WRF_DIR" fetch origin
    git -C "$WRF_DIR" checkout "$WRF_BRANCH"
    git -C "$WRF_DIR" pull --ff-only origin "$WRF_BRANCH"
  else
    log "Cloning $WRF_REPO ($WRF_BRANCH)"
    git clone --branch "$WRF_BRANCH" "$WRF_REPO" "$WRF_DIR"
  fi

  # Submodules (phys/noahmp is our modified Noah-MP with park irrigation)
  log "Fetching submodules"
  git -C "$WRF_DIR" submodule sync --recursive
  git -C "$WRF_DIR" submodule update --init --recursive
  git -C "$WRF_DIR" submodule status

  log "Download done, submitting compile job to the general partition"
  SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
  cd "$WORKDIR"
  sbatch "$SCRIPT_PATH"
  echo "Check progress with: squeue -u \$USER ; tail -f $WORKDIR/build_wrf_<jobid>.log"
  exit 0
fi

# ================= Stage 2: compile on a compute node =================
[[ -d $WRF_DIR/.git ]] || die "$WRF_DIR not found; run 'bash $(basename "$0")' on the login node first"
log "Compiling on $(hostname) (job $SLURM_JOB_ID)"

# 1. Load modules ---------------------------------------------------
log "Loading modules"
module purge || true
for m in "${MODULES[@]}"; do
  module load "$m" || die "module '$m' not found; run 'module avail' and edit MODULES"
done
module list

for cmd in mpif90 mpicc; do
  command -v "$cmd" >/dev/null || die "'$cmd' not found in PATH after loading modules"
done

# 2. Set up NetCDF ---------------------------------------------------
# WRF expects NetCDF-C and NetCDF-Fortran under one $NETCDF prefix.
# If the WRF module already sets a usable $NETCDF, use it as is.
# Otherwise locate both libraries with nc-config/nf-config and, if they
# live in separate directories, merge them with symlinks.
netcdf_ok() {
  [[ -n ${1:-} && -x $1/bin/nf-config ]] && ls "$1"/lib*/libnetcdff.* >/dev/null 2>&1
}
if netcdf_ok "${NETCDF:-}"; then
  echo "Using NETCDF from module: $NETCDF"
else
  command -v nc-config >/dev/null && command -v nf-config >/dev/null \
    || die "NETCDF not set by module and nc-config/nf-config not found; set NETCDF manually"
  NC_C=$(nc-config --prefix)
  NC_F=$(nf-config --prefix)
  if [[ "$NC_C" == "$NC_F" ]]; then
    export NETCDF=$NC_C
  else
    log "Merging NetCDF-C ($NC_C) and NetCDF-Fortran ($NC_F)"
    export NETCDF=$WORKDIR/netcdf_combined
    rm -rf "$NETCDF"
    mkdir -p "$NETCDF"/{bin,include,lib}
    for d in bin include lib; do
      for src in "$NC_C/$d" "$NC_F/$d"; do
        [[ -d $src ]] && ln -sf "$src"/* "$NETCDF/$d/"
      done
    done
    # some installs use lib64 instead of lib
    for src in "$NC_C/lib64" "$NC_F/lib64"; do
      [[ -d $src ]] && ln -sf "$src"/* "$NETCDF/lib/"
    done
  fi
fi
echo "NETCDF=$NETCDF"
[[ -x $NETCDF/bin/nf-config ]] && echo "NetCDF-4 support: $("$NETCDF"/bin/nf-config --has-nc4)"

export WRFIO_NCD_LARGE_FILE_SUPPORT=1
export WRF_EM_CORE=1
export WRF_NMM_CORE=0
ulimit -s unlimited || true

# 3. Configure -----------------------------------------------------
cd "$WRF_DIR"
log "Configuring WRF (option $CONFIG_OPT, nesting $NEST_OPT)"
./clean -a > /dev/null 2>&1 || true
printf "%s\n%s\n" "$CONFIG_OPT" "$NEST_OPT" | ./configure 2>&1 | tee configure.log
[[ -f configure.wrf ]] || die "configure failed, see $WRF_DIR/configure.log"
grep -E "^(SFC|DM_FC|DM_CC)[[:space:]]*=" configure.wrf

# 4. Compile -------------------------------------------------------
log "Compiling em_real with $NPROC jobs (log: $WRF_DIR/compile.log)"
./compile -j "$NPROC" em_real > compile.log 2>&1 || true

# 5. Check result --------------------------------------------------
missing=0
for exe in wrf.exe real.exe ndown.exe tc.exe; do
  if [[ -s main/$exe ]]; then
    echo "OK      main/$exe"
  else
    echo "MISSING main/$exe"; missing=1
  fi
done
if (( missing )); then
  echo "---- first errors in compile.log ----"
  grep -n -i -m 20 -E "error|fatal" compile.log || true
  die "build failed, see $WRF_DIR/compile.log"
fi

# Save the module list so the run script can load the same environment
printf "%s\n" "${MODULES[@]}" > "$WRF_DIR/modules_used.txt"

log "WRF built successfully in $WRF_DIR (run directory: $WRF_DIR/run)"
