#!/bin/zsh
# usage: run.sh <out dir> <name>…  — builds the harness against the app sources under nice and runs the recordings
# one after another; <out dir>/<name>/ gets transcript.md, the app's transcript-app.md, lines.json and metrics.json.
set -e
OUT=${1:A}; shift
T=${0:A:h}
APP=$T/../..
TQ2=$APP/..
rsync -a --delete --exclude main.swift $APP/Sources/Minutes/ $T/Sources/transcript-eval/
cp $T/src/main.swift $T/Sources/transcript-eval/main.swift
cd $T && nice -n 15 swift build -c release 2>&1 | grep -E "error|Build complete" | sort -u
mkdir -p $OUT
nice -n 15 $T/.build/release/transcript-eval $TQ2 $OUT "$@" 2>&1 | tee -a $OUT/run.log
