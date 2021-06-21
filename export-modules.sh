#!/bin/bash

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
