#!/bin/bash

# SPDX-FileCopyrightText: 2021 Markus Linnala <markus.linnala@cybercom.com>
#
# SPDX-License-Identifier: Apache-2.0

set -epu -o pipefail

(( $# )) || exit 0

D=sl

set +e
grep -El '^# found:' -- "$@" > "$D"/found.txt
grep -El '^# no:' -- "$@" > "$D"/no.txt
grep -El '^# some:' -- "$@" > "$D"/some.txt
while read -r a; do
    printf "# file: %s\n%s\n" "$a" "$(<"$a")"
done < <(grep -Fvf "$D"/no.txt "$D"/found.txt | grep -Fvf "$D"/some.txt)
exit 0
