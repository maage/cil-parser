#!/bin/bash
# To ensure split_te works for all kinds of policies, this iterates over
# refpolicy variant for example:
# - SELinuxProject/refpolicy
# - fedora-selinux/selinux-policy
# If pass is fully done, then we can deduct our parsing is reasonable
# fleshed out.

set -epux -o pipefail

tgt=(dupes.txt)

(( $# ))
D="$1"

[ "$D" ]
[ -d "$D" ]
mkdir -p "$D"/tmp/install
export DESTDIR="$(readlink -f -- "$D"/tmp/install)"
[ "$DESTDIR" ]
[ -d "$DESTDIR" ]
mkdir -p "$DESTDIR"/var/lib/selinux/targeted

make_refpolicy() {
    make DESTDIR="$DESTDIR" 'SEMODULE=/usr/sbin/semodule -v -p '"$DESTDIR"' -X 100 ' "$@"
}

if [ ! -f "$DESTDIR"/usr/share/selinux/devel/Makefile ]; then
    pushd "$D"
    sed -ri '
s/^[# ]*?(TYPE *=).*/\1 mcs/;
s/^[# ]*?(NAME *=).*/\1 targeted/;
s/^[# ]*?(DISTRO *=).*/\1 redhat/;
s/^[# ]*?(UNK_PERMS *=).*/\1 allow/;
s/^[# ]*?(DIRECT_INITRC *=).*/\1 n/;
s/^[# ]*?(SYSTEMD *=).*/\1 y/;
s/^[# ]*?(MONOLITHIC *=).*/\1 n/;
s/^[# ]*?(UBAC *=).*/\1 n/;
s/^[# ]*?(WERROR *=).*/\1 y/;
' build.conf
    make_refpolicy conf
    make_refpolicy -j$(nproc) load
    make_refpolicy NAME=devel install-headers
    cp /usr/share/selinux/devel/Makefile "$DESTDIR"/usr/share/selinux/devel/Makefile
    sed -ri 's,(SHAREDIR :=).*,\1 '"$DESTDIR"/usr/share/selinux',' "$DESTDIR"/usr/share/selinux/devel/Makefile
    popd
    ./export.sh "$DESTDIR"
fi

rm -rf split_lines
make DESTDIR="$DESTDIR" -j"$(nproc)" -k

f=()
while IFS='' read -d '' -r a && [ "$a" ]; do

    ok=export/"$(basename "$a")".ok
    err=export/"$(basename "$a")".err

    [ ! -f "$ok" ] || continue
    [ ! -f "$err" ] || continue

    rm -rf split_lines tmp/all_interfaces.conf

    make DESTDIR="$DESTDIR" tmp/all_interfaces.conf

    declare -i rc=0
    ./split_te.sh "$a" || rc=$?
    if (( rc )); then
        ./split_te.sh "$a" > "$err" 2>&1 || :
    fi

    if (( ! rc )); then
        make DESTDIR="$DESTDIR" -j"$(nproc)" -k "${tgt[@]}" || rc=$?
        if (( rc )); then
            make DESTDIR="$DESTDIR" "${tgt[@]}" > "$err" 2>&1 || :
        fi
    fi

    if (( ! rc )); then
        touch "$ok"
    fi

done < <((find "$D" -name '*.te' -type f -print0;find "$DESTDIR"/usr/share/selinux/devel -name '*.if' -type f -print0) | shuf -z)
