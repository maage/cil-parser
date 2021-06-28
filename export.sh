#!/bin/bash

# Directory can be made running somehing like this:
# export DESTDIR="$(pwd)"/tmp/install
# printf "export DESTDIR=%q\n" "$DESTDIR"
# mkdir -p "$DESTDIR"/var/lib/selinux/targeted
# make DISTRO=redhat UBAC=n DIRECT_INITRC=n MONOLITHIC=n MLS_CATS=1024 MCS_CATS=1024 UNK_PERMS=allow NAME=targeted TYPE=mcs DESTDIR="$DESTDIR" 'SEMODULE=/usr/sbin/semodule -v -p '"$DESTDIR"' -X 100 ' conf
# make -j$(nproc) DISTRO=redhat UBAC=n DIRECT_INITRC=n MONOLITHIC=n MLS_CATS=1024 MCS_CATS=1024 UNK_PERMS=allow NAME=targeted TYPE=mcs DESTDIR="$DESTDIR" 'SEMODULE=/usr/sbin/semodule -v -p '"$DESTDIR"' -X 100 ' load

set -epu -o pipefail

(( $# ))

DESTDIR="$(readlink -f -- "$1")"
SEMODULE=(semodule -p "$DESTDIR")

mkdir -p export/tmp
pushd export/tmp

oldfiles=()
args=()
for a in $("${SEMODULE[@]}" -l); do
    args+=(--cil --extract="$a")
done
"${SEMODULE[@]}" "${args[@]}"
for a in *.cil; do
    [ -f "$a" ] || continue
    if [ -f "$a" ] && cmp -s "$a" ../"$a"; then
        :
    else
        mv -- "$a" ../"$a"
    fi
done
popd
rm -rf -- export/tmp
