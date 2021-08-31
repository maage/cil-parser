#!/bin/bash

set -epu -o pipefail

declare -A all_te=()
while IFS='' read -d '' -r a && [ "$a" ]; do
    f="${a##*/}"
    all_te["$f"]="$a"
done < <(find . -name '*.te' -type f -print0)

get_te() {
    local a f te
    echo "# dupes"
    < "$1"
    for a in "$@"; do
        echo "$a"
        f="${a##*/}"
        f="${f%.cil.tosum}".te
        grep -E --with-filename -- ^ "${all_te[$f]}"
    done
}

cursum=
dupefiles=()
while read -r sum f; do
    if [ "$cursum" = "$sum" ]; then
        dupefiles+=("$f")
        continue
    fi
    if [ "$cursum" ]; then
        get_te "${dupefiles[@]}"
        dupefiles=()
    fi
    dupefiles+=("$f")
    cursum="$sum"
done < <(grep -Ff tmp/dupes.txt tmp/sums.txt|sort)
if [ "$cursum" ]; then
    get_te "${dupefiles[@]}"
fi
