#!/bin/bash

set -epu -o pipefail

D=split_lines
SD=tmp
EXT=.log

# Is there any logs to analyze
logs=("$SD"/*"$EXT")
if [ ! -f "${logs[0]}" ]; then
    exit 0
fi

set +e
grep -El '^# found:' "$SD"/*"$EXT" > "$D"/found.txt
grep -El '^# no:' "$SD"/*"$EXT" > "$D"/no.txt
grep -El '^# some:' "$SD"/*"$EXT" > "$D"/some.txt
grep -Fvf "$D"/no.txt "$D"/found.txt | grep -Fvf "$D"/some.txt
exit 0
