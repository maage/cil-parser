#!/bin/bash

set -epux -o pipefail

f=()
while IFS='' read -d '' -r a && [ "$a" ]; do
    if (( ${#f[@]} >= 10 )); then
        break
    fi
    f+=("$a")
done < <(find ../fedora-selinux/selinux-policy/policy/modules -name '*.te' -type f -print0 | shuf -z)
./split_te.sh "${f[@]}"
make -j$(nproc)
