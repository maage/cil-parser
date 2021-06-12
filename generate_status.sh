#!/bin/bash

set -epu -o pipefail

(( $# )) || exit 0

D=split_lines

set +e
grep -El '^# found:' -- "$@" > "$D"/found.txt
grep -El '^# no:' -- "$@" > "$D"/no.txt
grep -El '^# some:' -- "$@" > "$D"/some.txt
grep -Fvf "$D"/no.txt "$D"/found.txt | grep -Fvf "$D"/some.txt
exit 0
