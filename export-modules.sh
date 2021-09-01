#!/bin/bash

# SPDX-FileCopyrightText: 2021 Markus Linnala <markus.linnala@cybercom.com>
#
# SPDX-License-Identifier: Apache-2.0

set -epu -o pipefail

mkdir -p export/tmp

pushd export/tmp

args=() # --verbose)
for a in $(sudo semodule -l); do
    args+=(--cil --extract="$a")
done

sudo semodule "${args[@]}"

popd

sudo chown -R "$USER": export

pushd export/tmp
for a in *.cil; do
    [ -f "$a" ] || continue
    if [ -f ../"$a" ] && cmp -s "$a" ../"$a"; then
        :
    else
        mv -- "$a" ..
    fi
done
popd

rm -rf export/tmp
