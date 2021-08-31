#!/bin/bash

set -epu -o pipefail

(( $# )) || exit 0

D=sl

set +e
grep -El '^# found:' -- "$@" > "$D"/found.txt
grep -El '^# no:' -- "$@" > "$D"/no.txt
grep -El '^# some:' -- "$@" > "$D"/some.txt
for a in $(grep -Fvf "$D"/no.txt "$D"/found.txt | grep -Fvf "$D"/some.txt); do
    printf "# file: %s\n" "$a"
    < "$a"
    echo
done
exit 0
