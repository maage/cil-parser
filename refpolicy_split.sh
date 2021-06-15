#!/bin/bash

set -epux -o pipefail

(( $# ))
D="$1"

f=()
while IFS='' read -d '' -r a && [ "$a" ]; do
    if (( ${#f[@]} >= 10 )); then
        break
    fi
    rm -rf split_lines
    ./split_te.sh "$a"
    make -j"$(nproc)" -k || make -j"$(nproc)"
done < <(find "$D" -name '*.te' -type f -print0 | shuf -z)
