#!/bin/bash

set -epu -o pipefail

if [ ! -f sums.txt ]; then
    for a in tmp/*.cil;do
        grep -v cil_gen_require "$a" | sort -u > "$a".tosum || :
    done
    sha256sum tmp/*.tosum > sums.txt
    sha256sum tmp/*.tosum | awk '{print $1}' | sort | uniq -c | egrep -v ' 1 ' | awk '{print $2}' > dupes.txt
fi

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
done < <(fgrep -f dupes.txt sums.txt|sort)
if [ "$cursum" ]; then
    get_te "${dupefiles[@]}"
fi
