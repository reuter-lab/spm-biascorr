# spm_biascorr

Bias field correction of MRI images with strong, spatially fast varying
intensity inhomogeneities (e.g. at 7T), using the *unified segmentation*
of [SPM](https://www.fil.ion.ucl.ac.uk/spm/).

`spm_biascorr.sh` is a single shell script around SPM's segmentation
(`spm_preproc_run`). It runs SPM with bias field settings that are much more
flexible than SPM's defaults and returns just the bias corrected image and,
optionally, the estimated bias field. It works with SPM installed for MATLAB,
for GNU Octave, or as SPM standalone (no MATLAB licence needed), and can be
built into a Docker/Apptainer image on top of the official SPM container.

No SPM code or data is included in this repository. SPM has to be installed
separately.

## Why

SPM estimates the bias field jointly with a tissue segmentation, which makes
it robust also for strong inhomogeneities. Its default settings, however,
assume a smooth field (FWHM 60 mm) and a comparatively strong prior. At 7T
and with multi-channel receive coils the field varies on much shorter
scales. This wrapper uses:

| parameter | spm_biascorr | SPM default |
|---|---|---|
| bias FWHM | **18 mm** | 60 mm |
| bias regularisation | **1e-4** (very light) | 1e-3 |
| sampling distance | **2 mm** | 3 mm |

All three can be changed on the command line. A bias FWHM of 18 mm is not
one of the values offered in SPM's batch interface; the wrapper therefore
calls `spm_preproc_run` directly instead of going through the batch system.

## Requirements

- bash, gzip, mktemp (any Linux or macOS system)
- one of
  - **MATLAB** (R2019a or newer, for `-batch`) with SPM12 or SPM25 (or newer)
  - **GNU Octave** with the SPM source and its mex files compiled for Octave
  - **SPM standalone** with the matching MATLAB Runtime (free)
  - **Docker/Apptainer** (see below)

## Installation

```bash
git clone https://github.com/<owner>/spm-biascorr.git
cd spm-biascorr
./spm_biascorr.sh --help
```

The script is self-contained; copy it anywhere or put the directory in your
`PATH`.

## Usage

```
spm_biascorr.sh [options] <input> <corrected> [<biasfield>]
```

- `<input>`: 3D image, `.nii` or `.nii.gz`
- `<corrected>`: output bias corrected image, `.nii` or `.nii.gz`
- `<biasfield>`: optional output bias field, `.nii` or `.nii.gz`

The corrected image is `input * biasfield` (SPM's `m*.nii`), stored as float32
with the geometry of the input.

### MATLAB

```bash
spm_biascorr.sh --spm /path/to/spm12 --matlab /path/to/matlab \
    input.nii.gz corrected.nii.gz biasfield.nii.gz
```

### Octave

```bash
spm_biascorr.sh --octave --spm /path/to/spm-source input.nii.gz corrected.nii.gz
```

SPM's mex files must be compiled for Octave, e.g.

```bash
git clone https://github.com/spm/spm.git spm-source
cd spm-source/src && make PLATFORM=octave && make PLATFORM=octave install
```

### SPM standalone

```bash
# with the run_spmXX.sh launcher and the MATLAB Runtime root directory
spm_biascorr.sh --standalone /path/to/run_spm25.sh --mcr /path/to/MATLAB_Runtime/R2024b \
    input.nii.gz corrected.nii.gz

# with the spm executable itself, if the runtime is already set up (e.g. in the SPM container)
spm_biascorr.sh --standalone /path/to/spm25 input.nii.gz corrected.nii.gz
```

### Options

| option | environment variable | meaning |
|---|---|---|
| `--biasfwhm <mm>` | | bias FWHM in mm, or `Inf` for no correction (default 18) |
| `--biasreg <value>` | | bias regularisation (default 1e-4) |
| `--samp <mm>` | | sampling distance in mm (default 2) |
| `--spm <dir>` | `SPM_DIR` | SPM directory (MATLAB and Octave mode) |
| `--matlab <cmd>` | `MATLAB_CMD` | MATLAB executable (default `matlab`) |
| `--octave` | | use GNU Octave instead of MATLAB |
| `--octave-cmd <cmd>` | `OCTAVE_CMD` | Octave executable (default `octave-cli`) |
| `--standalone <launcher>` | `SPM_STANDALONE` | SPM standalone launcher or executable |
| `--mcr <dir>` | `MCR_ROOT` | MATLAB Runtime root, passed to `run_spmXX.sh` |
| `--keep-tmp` | | keep the temporary working directory (for debugging) |

The mode is chosen as follows: `--standalone` if given, otherwise `--octave`
if given, otherwise MATLAB.

The exit status is non-zero if anything fails; in that case no output is
written.

## How it works

1. The input is copied (or decompressed) into a temporary directory, so the
   input directory does not need to be writable and nothing is left behind.
2. A small MATLAB script is generated there. It sets up the segmentation job
   (6 tissue classes of SPM's `TPM.nii` with 1, 1, 2, 3, 4, 2 Gaussians, affine
   registration to MNI space, nonlinear warp) and calls `spm_preproc_run`.
   Only the bias field and the bias corrected image are written; no tissue
   maps and no `_seg8.mat` file.
3. SPM runs through MATLAB, Octave or the standalone executable.
4. The results are moved to the requested output files (compressed if the
   names end in `.gz`) and the temporary directory is removed.

The temporary directory is created in `$TMPDIR` (or `/tmp`).

## Memory and run time

SPM solves for the bias field with a dense matrix of (number of basis
functions)² values, with about 2 · FOV / FWHM basis functions per axis. With
a bias FWHM of 18 mm and a 256 mm field of view this is 29³ = 24389 basis
functions, i.e. a 4.8 GB matrix plus temporaries of the same size, so expect
well over 10 GB of RAM and long run times. Cropping the input to the head
reduces this considerably (e.g. 166 × 231 × 207 mm: 11362 functions, about
1 GB). As a reference, a 1 mm 3T image cropped to the head took about 14
minutes with SPM26 under Octave on an Apple M2.

Voxel size does not change the number of basis functions, but the number of
sampled voxels (and hence time) grows with finer sampling (`--samp`).

## Docker / Apptainer

The `Dockerfile` builds on the official SPM standalone container
(`ghcr.io/spm/spm-docker`, MATLAB Runtime included, no licence needed) and adds
`spm_biascorr.sh` as entry point:

```bash
docker build -t spm_biascorr .
# other SPM release:
docker build --build-arg SPM_IMAGE=ghcr.io/spm/spm-docker:docker-matlab-latest -t spm_biascorr:latest .

docker run --rm -u $(id -u):$(id -g) -v $PWD:/data spm_biascorr \
    input.nii.gz corrected.nii.gz biasfield.nii.gz
```

Paths are relative to the mounted directory `/data`. For HPC systems:

```bash
apptainer build spm_biascorr.sif docker-daemon://spm_biascorr:latest
apptainer run -B $PWD:/data --pwd /data spm_biascorr.sif input.nii.gz corrected.nii.gz
```

## Testing

`tests/matlab_via_octave.sh` emulates `matlab -batch` with Octave, which allows
testing the MATLAB code path without a MATLAB licence:

```bash
./spm_biascorr.sh --spm /path/to/spm-source --matlab $PWD/tests/matlab_via_octave.sh \
    input.nii.gz corrected.nii.gz
```

Tested so far:

| mode | SPM | result |
|---|---|---|
| MATLAB code path (via Octave shim) | SPM 26.01.rc1, Octave 11.3 | identical to calling `spm_preproc_run` directly |
| Octave | SPM 26.01.rc1, Octave 11.3 | identical to the MATLAB code path |
| MATLAB | SPM12 | pending |
| standalone / Docker | SPM 25/26 | pending |


## References

If you use this tool, please cite SPM's unified segmentation:

- J. Ashburner, K. J. Friston. Unified segmentation. *NeuroImage* 26(3):839-851, 2005.
- SPM: https://www.fil.ion.ucl.ac.uk/spm/

This project is not affiliated with or endorsed by the SPM developers.

## License

MIT, see [LICENSE](LICENSE). This covers the wrapper and the Dockerfile
only; SPM itself is distributed under the GNU General Public License by its
authors.
