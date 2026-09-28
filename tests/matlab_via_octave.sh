#!/bin/bash
# test shim: emulate "matlab -batch <code>" with Octave
[ "$1" = "-batch" ] || { echo "shim: only -batch supported" >&2; exit 2; }
exec octave-cli --no-gui --eval "$2"
