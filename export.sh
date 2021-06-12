#!/bin/bash

# Directory can be made running somehing like this:
# mkdir -p "$DIR"/var/lib/selinux/targeted
# make DISTRO=redhat UBAC=n DIRECT_INITRC=n MONOLITHIC=n MLS_CATS=1024 MCS_CATS=1024 UNK_PERMS=allow NAME=targeted TYPE=mcs DESTDIR=tmp/install 'SEMODULE=/usr/sbin/semodule -v -p '"$DIR"' -X 100 ' load

( $# )

DIR="$1"
SEMODULE=(semodule -p "$DIR")

args=()
for a in $("${SEMODULE[@]}" -l); do
    args+=(--cil --extract="$a")
done
mkdir -p export
cd export
"${SEMODULE[@]}" "${args[@]}"
