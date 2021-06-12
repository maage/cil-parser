#!/bin/bash

# Directory can be made running somehing like this:
# mkdir -p "$DIR"/var/lib/selinux/targeted
# make DISTRO=redhat UBAC=n DIRECT_INITRC=n MONOLITHIC=n MLS_CATS=1024 MCS_CATS=1024 UNK_PERMS=allow NAME=targeted TYPE=mcs DESTDIR=tmp/install 'SEMODULE=/usr/sbin/semodule -v -p '"$DIR"' -X 100 ' load

(( $# ))

DIR="$(readlink -f -- "$1")"
SEMODULE=(semodule -p "$DIR")

mkdir -p export
cd export

oldfiles=()
args=()
for a in $("${SEMODULE[@]}" -l); do
    if [ -f "$a".cil ]; then
        oldfiles+=("$a".cil)
        mv -- "$a".cil "$a".cil.old
    fi
    args+=(--cil --extract="$a")
done
"${SEMODULE[@]}" "${args[@]}"
olddel=()
for a in "${oldfiles[@]}"; do
    if [ -f "$a" ] && cmp -s "$a".old "$a"; then
        # Use old file if no change
        mv -- "$a".old "$a"
    else
        olddel+=("$a".old)
    fi
done
if (( ${#olddel[@]} )); then
    rm -f -- "${olddel[@]}"
fi
