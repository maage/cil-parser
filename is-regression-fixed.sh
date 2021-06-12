#!/bin/bash

set -epu -o pipefail

src=
not_src=
tgt=
not_tgt=
cls=
perm=
perms=()
typ="allow"
declare -i OPT_resolveattr=0
declare -i OPT_reverse_source=0
declare -i OPT_reverse_target=0

while (( $# )); do
	case "$1" in
		--allow|--auditallow|--dontaudit|--neverallow|--allowxperm|--auditallowxperm|--dontauditxperm|--neverallowxperm) typ="${1#--}"; shift ;;
		--attr) typ="typeattributeset"; shift ;;
		--resolveattr) typ="typeattributeset"; OPT_resolveattr=1; shift ;;
		--reverse[-_]source) OPT_reverse_source=1; shift ;;
		--reverse[-_]target) OPT_reverse_target=1; shift ;;
		-s|--source) (( $# >= 2 )) || exit 1; src="$2"; shift 2 ;;
		-s|--not[-_]source) (( $# >= 2 )) || exit 1; not_src="$2"; shift 2 ;;
		-t|--target) (( $# >= 2 )) || exit 1; tgt="$2"; shift 2 ;;
		-t|--not[-_]target) (( $# >= 2 )) || exit 1; not_tgt="$2"; shift 2 ;;
		-c|--class) (( $# >= 2 )) || exit 1; cls="$2"; shift 2 ;;
		-p|--perm) (( $# >= 2 )) || exit 1; perm="$2"; shift 2 ;;
		--) shift; break ;;
		*) echo "ERROR: param $*"; exit 2 ;;
	esac
done

if [ "$perm" ]; then
	IFS=', ' read -r -a perms <<< "$perm"
fi

#
#
#

rx_escape() {
	sed 's/[^^a-zA-Z0-9_]/[&]/g; s/\^/\\^/g' <<< "$1"
}

get_typeattributeset() {
	declare -n attrs="$1"; shift
	local rx="$1"; shift
	local -i reverse="${1:-0}"
	local -A aah=()
	attrs+=("$rx")
	aah["$rx"]=1

	if (( reverse )); then

		while read -r attr; do
			aa="$(rx_escape "$attr")"
			 [ ! "${aah[$aa]:-}" ] || continue
			aah["$aa"]=1
			attrs+=("$aa")
		done < <(
			grep -Erh '[(]typeattributeset ' export | \
			sed -nr '/ cil_gen_require /d;/[(]typeattributeset '"$rx"' /!d;s/[(]typeattributeset '"$rx"' //;s/[() ]/\n/g;p' | \
			sed '/./!d'
		)
		return

	fi

	while read -r tas attr rest; do
		if [ "$tas" != "(typeattributeset" ]; then
			echo "ERROR: Parse error: $tas $attr $rest"
			exit 1
		fi
		aa="$(rx_escape "$attr")"
		 [ ! "${aah[$aa]:-}" ] || continue
		aah["$aa"]=1
		attrs+=("$aa")
	done < <(grep -Erh '[(]typeattributeset ' export | sed '/ cil_gen_require /d;/[( ]'"$rx"'[) ]/!d;s/^[[:space:]]*//')
}

if [ ! -d export ]; then
	mkdir -p export
	pushd export
	args=() # --verbose)
	for a in $(sudo semodule -l); do
		args+=(--cil --extract="$a")
	done

	sudo semodule "${args[@]}"

	popd
	# chown -R "$SUDO_USER": export
fi

if [ "$typ" = "typeattributeset" ]; then

	rx="/[(]$(rx_escape "$typ") /!d;"
	rx+="/[(]$(rx_escape "$typ") cil_gen_require /d;"

	if [ "$src" ]; then
		rx+="/[(]$(rx_escape "$typ") $(rx_escape "$src") /!d;"
	fi

	if [ "$tgt" ]; then
		rx+="/[( ]$(rx_escape "$tgt")[) ]/!d;"
	fi

	grep -r ^ export | sed -r "$rx" | \
	if (( OPT_resolveattr )); then
		sed -r 's/.*[(]typeattributeset //;s/[() ]/\n/g' | sed '/./!d' | sort -u
	else
		cat
	fi
	exit 0
fi

rx="/[(]$(rx_escape "$typ") ("

if [ "$src" ]; then
	src_attrs=()
	get_typeattributeset src_attrs "$(rx_escape "$src")" $OPT_reverse_source
	for a in "${src_attrs[@]}"; do
		rx+="${a}|"
	done
else
	rx+="[^ ]*|"
fi

rx="${rx%|}) ("

if [ "$tgt" ]; then
	tgt_attrs=()
	get_typeattributeset tgt_attrs "$(rx_escape "$tgt")" $OPT_reverse_target
	for a in "${tgt_attrs[@]}"; do
		rx+="${a}|"
	done
else
	rx+="[^ ]*|"
fi

rx="${rx%|}) [(]"

if [ "$cls" ]; then
	rx+="$(rx_escape "$cls") "
else
	rx+="[^ ]* "
fi

if (( ${#perms[@]} )); then
	# This makes multiple prefix matches, much simpler than permutations
	frx="$rx[(]"
	rx+="/!d;"
	for a in "${perms[@]}"; do
		rx+="$frx([^()]* )?$(rx_escape "$a")[ )]/!d;"
	done
else
	rx+="[(][^)]*[)]/!d;"
fi

not_rx="/[(]$(rx_escape "$typ") ("
has_not=0

if [ "$not_src" ]; then
	has_not=1
	not_src_attrs=()
	get_typeattributeset not_src_attrs "$(rx_escape "$not_src")" $OPT_reverse_source
	for a in "${not_src_attrs[@]}"; do
		not_rx+="${a}|"
	done
else
	not_rx+="[^ ]*|"
fi

not_rx="${not_rx%|}) ("

if [ "$not_tgt" ]; then
	has_not=1
	not_tgt_attrs=()
	get_typeattributeset not_tgt_attrs "$(rx_escape "$not_tgt")" $OPT_reverse_target
	for a in "${not_tgt_attrs[@]}"; do
		not_rx+="${a}|"
	done
else
	not_rx+="[^ ]*|"
fi

not_rx="${not_rx%|}) [(]/d;"
if (( has_not )); then
	rx+="$not_rx"
fi

exec grep -r ^ export | sed -r "$rx" | awk '!seen[$0]++'
