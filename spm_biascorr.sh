#!/usr/bin/env bash
#
# spm_biascorr.sh - bias field correction using SPM unified segmentation
#
# Thin wrapper around SPM's spm_preproc_run (SPM12 / SPM25) with parameters
# tuned for strong, spatially fast varying bias fields (e.g. 7T images):
#   bias FWHM 18 mm, bias regularization 1e-4 (very light), sampling 2 mm.
#
# No SPM code is included here. SPM must be installed separately, either as
# a MATLAB toolbox (needs MATLAB R2019a+ for -batch), as SPM source with
# compiled mex files for GNU Octave (free), or as SPM standalone (compiled,
# needs only the free MATLAB Runtime).
#

set -eu

# ---------------------------------------------------------------- defaults
BIASFWHM=18         # FWHM of bias field smoothness (mm), SPM default 60
BIASREG=1e-4        # bias regularization, SPM default 1e-3
SAMP=2              # sampling distance (mm), SPM default 3
KEEP_TMP=0

SPM_DIR="${SPM_DIR:-}"
MATLAB_CMD="${MATLAB_CMD:-matlab}"
OCTAVE_CMD="${OCTAVE_CMD:-octave-cli}"
USE_OCTAVE=0
SPM_STANDALONE="${SPM_STANDALONE:-}"
MCR_ROOT="${MCR_ROOT:-}"

usage() {
  cat <<EOF

Usage: $(basename "$0") [options] <input> <corrected> [<biasfield>]

  <input>      input image (.nii or .nii.gz, 3D)
  <corrected>  output bias corrected image (.nii or .nii.gz)
  <biasfield>  optional output bias field (.nii or .nii.gz)

Parameters:
  --biasfwhm <mm>   bias field FWHM in mm, or Inf  (default: $BIASFWHM)
  --biasreg <val>   bias regularization            (default: $BIASREG)
  --samp <mm>       sampling distance in mm        (default: $SAMP)

MATLAB mode (default):
  --spm <dir>       SPM12/SPM25 directory          (or env SPM_DIR)
  --matlab <cmd>    MATLAB executable              (or env MATLAB_CMD, default: matlab)

Octave mode (used if --octave is given; SPM source with mex files built for Octave):
  --octave          run SPM with GNU Octave instead of MATLAB (needs --spm)
  --octave-cmd <cmd> Octave executable             (or env OCTAVE_CMD, default: octave-cli)

Standalone mode (used if --standalone is given):
  --standalone <sh> SPM standalone launcher, e.g. .../run_spm12.sh or .../run_spm25.sh,
                    or the spm executable itself   (or env SPM_STANDALONE)
  --mcr <dir>       MATLAB Runtime root directory  (or env MCR_ROOT), passed as
                    first argument to run_spmXX.sh; omit if the runtime is already
                    set up (e.g. in the SPM docker image)

Other:
  --keep-tmp        do not delete the temporary working directory
  -h, --help        print this help

All SPM processing happens in a temporary directory (\$TMPDIR or /tmp),
so no write access to the input directory is needed.

Memory and run time: SPM solves for the bias field with a dense matrix of
(number of basis functions)^2 values, with about 2*FOV/biasfwhm basis
functions per axis. With the default biasfwhm of 18 mm, a 256 mm FOV gives
29^3 = 24389 functions, i.e. a 4.8 GB matrix plus temporaries of the same
size: expect well over 10 GB of RAM and long run times. Cropping the input
to the head reduces this considerably (e.g. 166x231x207 mm: 11362
functions, about 1 GB).

EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# absolute path of a (possibly not yet existing) file in an existing directory
abspath() {
  local d
  d=$(cd -- "$(dirname -- "$1")" 2>/dev/null && pwd) || die "directory not found: $(dirname -- "$1")"
  echo "$d/$(basename -- "$1")"
}

# quote a string for use inside a MATLAB single-quoted string
mq() { printf '%s' "$1" | sed "s/'/''/g"; }

NUMRE='^[+]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][+-]?[0-9]+)?$'
is_number() { [[ "$1" =~ $NUMRE ]]; }

check_nii() {
  case "$1" in
    *.nii|*.nii.gz) ;;
    *) die "$2 must be .nii or .nii.gz: $1" ;;
  esac
}

# copy src (.nii) to dst, compressing if dst ends in .gz
deliver() {
  case "$2" in
    *.gz) gzip -c "$1" > "$2" ;;
    *)    mv -f "$1" "$2" ;;
  esac
}

# ---------------------------------------------------------------- arguments
INPUT=""
OUTPUT=""
OUTBIAS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --biasfwhm|--biasreg|--samp|--spm|--matlab|--octave-cmd|--standalone|--mcr)
      [ $# -ge 2 ] || die "missing value for $1"
      case "$1" in
        --biasfwhm)   BIASFWHM=$2 ;;
        --biasreg)    BIASREG=$2 ;;
        --samp)       SAMP=$2 ;;
        --spm)        SPM_DIR=$2 ;;
        --matlab)     MATLAB_CMD=$2 ;;
        --octave-cmd) OCTAVE_CMD=$2; USE_OCTAVE=1 ;;
        --standalone) SPM_STANDALONE=$2 ;;
        --mcr)        MCR_ROOT=$2 ;;
      esac
      shift 2 ;;
    --octave) USE_OCTAVE=1; shift ;;
    --keep-tmp) KEEP_TMP=1; shift ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      if   [ -z "$INPUT" ];   then INPUT=$1
      elif [ -z "$OUTPUT" ];  then OUTPUT=$1
      elif [ -z "$OUTBIAS" ]; then OUTBIAS=$1
      else die "too many arguments: $1"
      fi
      shift ;;
  esac
done

if [ -z "$OUTPUT" ]; then usage; exit 1; fi

[ -f "$INPUT" ] || die "input not found: $INPUT"
check_nii "$INPUT" "input"
check_nii "$OUTPUT" "corrected output"
[ -z "$OUTBIAS" ] || check_nii "$OUTBIAS" "bias field output"

INPUT=$(abspath "$INPUT")
OUTPUT=$(abspath "$OUTPUT")
[ -z "$OUTBIAS" ] || OUTBIAS=$(abspath "$OUTBIAS")
[ "$INPUT" != "$OUTPUT" ] || die "output must differ from input"

[ "$BIASFWHM" = "Inf" ] || is_number "$BIASFWHM" || die "invalid --biasfwhm: $BIASFWHM"
is_number "$BIASREG" || die "invalid --biasreg: $BIASREG"
is_number "$SAMP"    || die "invalid --samp: $SAMP"

# ---------------------------------------------------------------- SPM setup
if [ -n "$SPM_STANDALONE" ] && [ "$USE_OCTAVE" = 1 ]; then
  die "use either --standalone or --octave"
fi
if [ -n "$SPM_STANDALONE" ]; then
  MODE=standalone
  [ -x "$SPM_STANDALONE" ] || die "SPM standalone launcher not executable: $SPM_STANDALONE"
  [ -z "$MCR_ROOT" ] || [ -d "$MCR_ROOT" ] || die "MATLAB Runtime directory not found: $MCR_ROOT"
else
  if [ "$USE_OCTAVE" = 1 ]; then
    MODE=octave
    command -v "$OCTAVE_CMD" > /dev/null 2>&1 || die "Octave not found: $OCTAVE_CMD (use --octave-cmd or OCTAVE_CMD)"
  else
    MODE=matlab
    command -v "$MATLAB_CMD" > /dev/null 2>&1 || die "MATLAB not found: $MATLAB_CMD (use --matlab or MATLAB_CMD)"
  fi
  [ -n "$SPM_DIR" ]          || die "$MODE mode needs --spm or SPM_DIR"
  [ -f "$SPM_DIR/spm.m" ]    || die "not an SPM directory (spm.m missing): $SPM_DIR"
  [ -f "$SPM_DIR/tpm/TPM.nii" ] || die "SPM tissue priors missing: $SPM_DIR/tpm/TPM.nii"
  SPM_DIR=$(cd -- "$SPM_DIR" && pwd)
fi

# ---------------------------------------------------------------- work dir
TMPBASE=${TMPDIR:-/tmp}
WORK=$(mktemp -d "${TMPBASE%/}/spm_biascorr.XXXXXX")
cleanup() {
  if [ "$KEEP_TMP" = 1 ]; then
    echo "Keeping temporary directory: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

case "$INPUT" in
  *.gz) gzip -dc "$INPUT" > "$WORK/input.nii" ;;
  *)    cp "$INPUT" "$WORK/input.nii" ;;
esac

# SPM job: only the bias field and the bias corrected image are written,
# tissue classes and deformations are not needed. Output file names are
# taken from what spm_preproc_run reports, so SPM naming changes don't matter.
cat > "$WORK/biascorr_job.m" <<EOF
% generated by spm_biascorr.sh
work = '$(mq "$WORK")';
spm('defaults','fmri');
spm_get_defaults('cmdline',true);
fprintf('SPM version: %s\n', spm('Ver'));
tpm   = fullfile(spm('Dir'),'tpm','TPM.nii');
ngaus = [1 1 2 3 4 2];
job = struct();
job.channel.vols     = {[fullfile(work,'input.nii') ',1']};
job.channel.biasreg  = $BIASREG;
job.channel.biasfwhm = $BIASFWHM;
job.channel.write    = [1 1];
for k = 1:6
    job.tissue(k).tpm    = {sprintf('%s,%d',tpm,k)};
    job.tissue(k).ngaus  = ngaus(k);
    job.tissue(k).native = [0 0];
    job.tissue(k).warped = [0 0];
end
job.warp.mrf     = 1;
job.warp.cleanup = 0;
job.warp.reg     = [0 0.001 0.5 0.05 0.2];
job.warp.affreg  = 'mni';
job.warp.fwhm    = 0;
job.warp.samp    = $SAMP;
job.warp.write   = [0 0];
job.warp.vox     = NaN;
job.warp.bb      = NaN(2,3);
job.savemat      = 0;
vout = spm_preproc_run(job);
movefile(vout.channel(1).biascorr{1},  fullfile(work,'corrected.nii'));
movefile(vout.channel(1).biasfield{1}, fullfile(work,'biasfield.nii'));
EOF

# ---------------------------------------------------------------- run
echo
echo "SPM bias correction ($MODE mode)"
echo "  input:     $INPUT"
echo "  biasfwhm:  $BIASFWHM   biasreg: $BIASREG   samp: $SAMP"
echo "  started:   $(date)"
echo "This is going to take some time ..."
echo

if [ "$MODE" = standalone ] && [ -n "$MCR_ROOT" ]; then
  "$SPM_STANDALONE" "$MCR_ROOT" script "$WORK/biascorr_job.m"
elif [ "$MODE" = standalone ]; then
  "$SPM_STANDALONE" script "$WORK/biascorr_job.m"
elif [ "$MODE" = octave ]; then
  "$OCTAVE_CMD" --no-gui --quiet --eval "addpath('$(mq "$SPM_DIR")'); run('$(mq "$WORK/biascorr_job.m")');"
else
  "$MATLAB_CMD" -batch "addpath('$(mq "$SPM_DIR")'); run('$(mq "$WORK/biascorr_job.m")');"
fi

[ -f "$WORK/corrected.nii" ] || die "SPM did not produce a bias corrected image"
deliver "$WORK/corrected.nii" "$OUTPUT"
echo "Wrote $OUTPUT"
if [ -n "$OUTBIAS" ]; then
  [ -f "$WORK/biasfield.nii" ] || die "SPM did not produce a bias field"
  deliver "$WORK/biasfield.nii" "$OUTBIAS"
  echo "Wrote $OUTBIAS"
fi
echo "Finished:  $(date)"
