#!/bin/bash

set -epu -o pipefail

get_te() {
    local a f te
    echo "# dupes"
    cat "$1"
    for a in "$@"; do
        echo "$a"
        f="$(basename -- "$a" .cil.tosum)"
        for te in */"$f".te; do
            egrep ^ "$te" /dev/null
        done
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
