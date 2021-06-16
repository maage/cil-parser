#!/bin/bash

set -epux -o pipefail

(( $# ))
D="$1"

f=()
while IFS='' read -d '' -r a && [ "$a" ]; do
    ok=export/"$(basename "$a")".ok
    err=export/"$(basename "$a")".err
    [ ! -f "$ok" ] || continue
    [ ! -f "$err" ] || continue
    rm -rf split_lines
    ./split_te.sh "$a"
    make -j"$(nproc)" -k || make -j"$(nproc)"  # || { touch "$err"; continue; }
    touch "$ok"
done < <(find "$D" -name '*.te' -type f -print0 | shuf -z)
