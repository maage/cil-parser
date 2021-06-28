#!/bin/bash
# To ensure split_te works for all kinds of policies, this iterates over
# refpolicy variant for example:
# - SELinuxProject/refpolicy
# - fedora-selinux/selinux-policy
# If pass is fully done, then we can deduct our parsing is reasonable
# fleshed out.

set -epux -o pipefail

(( $# ))
D="$1"

export DESTDIR="$(readlink -f -- "$D"/tmp/install)"
mkdir -p "$DESTDIR"/var/lib/selinux/targeted

make_refpolicy() {
    make DISTRO=redhat SYSTEMD=y WERROR=y UBAC=n DIRECT_INITRC=n MONOLITHIC=n MLS_CATS=1024 MCS_CATS=1024 UNK_PERMS=allow NAME=targeted TYPE=mcs DESTDIR="$DESTDIR" 'SEMODULE=/usr/sbin/semodule -v -p '"$DESTDIR"' -X 100 ' "$@"
}

if [ ! -f "$DESTDIR"/usr/share/selinux/devel/Makefile ]; then
    pushd "$D"
    make_refpolicy conf
    make_refpolicy -j$(nproc) load
    make_refpolicy NAME=devel install-headers
    cp /usr/share/selinux/devel/Makefile "$DESTDIR"/usr/share/selinux/devel/Makefile
    sed -ri 's,(SHAREDIR :=).*,\1 '"$DESTDIR"/usr/share/selinux',' "$DESTDIR"/usr/share/selinux/devel/Makefile
    popd
fi

f=()
while IFS='' read -d '' -r a && [ "$a" ]; do
    ok=export/"$(basename "$a")".ok
    err=export/"$(basename "$a")".err
    [ ! -f "$ok" ] || continue
    [ ! -f "$err" ] || continue
    rm -rf split_lines
    ./split_te.sh "$a"
    make DESTDIR="$DESTDIR" tmp/all_interfaces.conf
    if [ -f "$D"/tmp/all_interfaces.conf ]; then
        cp "$D"/tmp/all_interfaces.conf tmp/all_interfaces.conf
        touch tmp/all_interfaces.conf
    fi
    make DESTDIR="$DESTDIR" -j"$(nproc)" -k || make DESTDIR="$DESTDIR" -j"$(nproc)"  # || { touch "$err"; continue; }
    touch "$ok"
done < <(find "$D" -name '*.te' -type f -print0 | shuf -z)
