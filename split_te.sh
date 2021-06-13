#!/bin/bash

set -epu -o pipefail

D=split_lines

mkdir -p "$D"

filter_require() {
    sed -r '
s/^ *//;
s/ *$//;
/./!d;
/^ZZZ$/d;
/^dir$/d;
' | sed -r '
/_r$/{
    s/^/role /;
}
/_roles$/{
    s/^/attribute_role /;
}
/_t$/{
    s/^/type /;
}
/^user$/{
    s/^.*$/type user_t/;
}
t x;
s/^/attribute /;
:x;
/./{
    s/$/;\n/;
}
'
}

rr_str='s/ *"[^"]*" */ /;'
rr1='
s/, *s0 - mcs_systemhigh//;
'
# s/^[^(), :;{}-]*//;
rr2='s/[() ,{}]/\n/g;'

gen_require() {
    local line="$1"; shift
    local ll l3
    (
        # KLUDGE, seems dev_ macros miss type device_t
        if [[ "$line" =~ ^dev_ ]]; then
            echo "type device_t;"
        fi

        if [[ "$line" =~ \(.*\) ]]; then
            # M4 macro
            line="${line#*\(}"
            line="${line%)*}"
            sed -r "${rr_str}${rr1}${rr2}" <<< "$line" | filter_require
        elif [[ "$line" =~ ^(role|type)_transition ]]; then
            # role / type_transition
            line="${line#role_transition}"
            line="${line#type_transition}"
            # class
            sed -r  "${rr_str}"'s/^ *[^ ]* [^ :]*:([^ ]*) .*/class \1 getattr;/;' <<< "$line"
            # rest
            sed -r  "${rr_str}"'s/^ *([^ ]*) ([^ :]*):[^ ]* ([^ ;]*);$/\1\n\2\n\3/;' <<< "$line" | filter_require
        else
            if [[ "$line" =~ :\ *\{ ]]; then
                # handle class with group
                local l3 l4 l2=()
                ll="${line##*:}"
                l3="${ll#*\}}"
                ll="${ll#*\{}"
                readarray -d ' ' l2 <<< "${ll%%\}*}"
                for l4 in "${l2[@]}"; do
                    l4="$(printf "%s" "$l4" | sed 's/^ *//;s/ *$//;/./!d')"
                    [ "$l4" ] || continue
                    printf "class %s %s\n" "$l4" "$l3" | sed -r 's/ *~ */ /;s/\*/getattr/'
                done
                line="${line%%:*}"
            elif [[ "$line" =~ : ]]; then
                # handle normal class
                printf "class %s\n" "${line##*:}" | sed -r 's/ *~ */ /;s/\*/getattr/'
                line="${line%%:*}"
            fi
            if [[ "$line" =~ \{.*\} ]]; then
                # handle groups
                ll="$line"
                while [[ "$ll" =~ \{.*\} ]]; do
                    ll="${ll#*\{}"
                    printf "%s\n" "${ll%%\}*}" | sed 's/ /\n/g;' | filter_require
                    ll="${ll#*\}}"
                done
                line="$(sed -r 's/[{][^}]*[}]/ZZZ/g;' <<< "$line")"
            fi
            # sed -r 's/^[^ ]* [^ ]* [^ ]*:(.*;)$/class \1/;' <<< "$line"
            sed -r '
            s/^[^ ]* //;
            s/^([^ ]*) self/\1/;
            s/ alias / /;
            s/^([^ ]*) ([^ ]*)/\1\n\2/;
            ' <<< "$line" | filter_require
        fi
    ) | sed '
    /^class [^ ]*_class_set /d;
    '| sort -u
}

declare -A old_files=()
outdel=()

for a in "$@"; do
    while IFS= read -d '' -r old && [ "$old" ]; do
        old_files["$old"]=1
    done < <(find "$D" -type f -name "$(basename -- "$a" .te)_*.te" -print0)

	lineno=0
    state=line
    macrono=0
    macroskip=-1
    meta=()
	while read -r line; do
		(( lineno++ )) || :
        out="$D"/"$(basename -- "$a" .te)"_"$lineno".te
        unset old_files["$out"]

        if [ ! "$line" ]; then
            outdel+=("$out")
            continue
        fi

        skip=0
        if (( macrono < 0 )); then
            printf "$state macrono < 0: error(%s:%d): %s\n" "$a" "$lineno" "$line"
            exit 1
        fi

        if [[ "$line" =~ ^(optional_policy|gen_require)\(\`$ ]]; then
            (( macrono++ )) || :
        elif [[ "$line" =~ ^(tunable_policy|ifdef|ifndef)\(\`[^\']*\',\ *\`$ ]]; then
            (( macrono++ )) || :
        elif [[ "$line" =~ ^(tunable_policy)\(\`[^\']*\',\ *\`\',\ *\`$ ]]; then
            # only else definition
            (( macrono++ )) || :
        elif [[ "$line" =~ ^\'\)$ ]]; then
            (( macrono-- )) || :
        elif [[ "$line" =~ ^(optional_policy|tunable_policy|ifdef|ifndef|gen_require)\( ]]; then
            printf "$state bad error(%s:%d): %s\n" "$a" "$lineno" "$line"
            exit 1
        elif [[ "$line" =~ \'\) ]]; then
            printf "$state bad error(%s:%d): %s\n" "$a" "$lineno" "$line"
            exit 1
        fi

        if [[ "$line" =~ ^\',\ *\` ]]; then
            if [ "${meta[$macrono]:-}" = tunable_policy ]; then
                # handle both sides
                :
            elif [ "${meta[$macrono]:-}" = ifdef ]; then
                # false else part of ifded
                state=macroskip
                macroskip="$macrono"
                unset meta["$macrono"]
            elif [ "$state" = macroskip ]; then
                # true else part of ifded
                meta["$macrono"]=ifdef
                state=line
            else
                printf "$state else error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            skip=1
        elif [ "$state" = line ]; then
            if [[ "$line" =~ ^policy_module ]]; then
                skip=1
            elif [[ "$line" =~ ^optional_policy ]]; then
                skip=1
            elif [[ "$line" =~ ^tunable_policy ]]; then
                skip=1
                meta["$macrono"]=tunable_policy
            elif [[ "$line" =~ ^ifdef ]]; then
                if [[ "$line" =~ ^ifdef\(\`([^\)]*)\',\ *\`define\([^\)]*\)\'\)$ ]]; then
                    :
                elif [[ "$line" =~ ^ifdef\(\`(distro_redhat|enable_mcs|hide_broken_symptoms|enable_ubac|ipa_helper_noatsecure|targeted_policy)\',\ *\`$ ]]; then
                    meta["$macrono"]=ifdef
                elif [[ "$line" =~ ^ifdef\(\`(distro_debian|distro_gentoo|distro_rhel4|distro_suse|distro_ubuntu|direct_sysadm_daemon|enable_mls|sulogin_no_pam|TODO)\',\ *\`$ ]]; then
                    if (( macroskip != -1 )); then
                        # printf "error(%s:%d): %s\n" "$a" $lineno "$line"
                        exit 1
                    fi
                    state=macroskip
                    macroskip="$macrono"
                else
                    printf "$state ifdef error(%s:%d): %s\n" "$a" "$lineno" "$line"
                    exit 1
                fi
                skip=1
            elif [[ "$line" =~ ^ifndef ]]; then
                # printf "error(%s:%d): %s\n" "$a" $lineno "$line"
                if [[ "$line" =~ ^ifndef\(\`(distro_debian|distro_gentoo|distro_rhel4|distro_suse|distro_ubuntu|direct_sysadm_daemon|enable_mls|sulogin_no_pam|TODO)\',\ *\`$ ]]; then
                    # defines false
                    meta["$macrono"]=ifdef
                elif [[ "$line" =~ ^ifndef\(\`(distro_redhat|enable_mcs|hide_broken_symptoms|enable_ubac|ipa_helper_noatsecure|targeted_policy)\',\ *\`$ ]]; then
                    # defines true
                    if (( macroskip != -1 )); then
                        # printf "error(%s:%d): %s\n" "$a" $lineno "$line"
                        exit 1
                    fi
                    state=macroskip
                    macroskip="$macrono"
                else
                    printf "$state ifndef error(%s:%d): %s\n" "$a" "$lineno" "$line"
                    exit 1
                fi
                skip=1
            elif [[ "$line" =~ ^\'\) ]]; then
                if (( ${#meta[@]} == 0 )); then
                    :
                elif [ "${meta["$(((macrono+1)))"]:-}" ]; then
                    unset meta["$macrono"]
                else
                    :
                    # printf "$state ) error(%s:%d): %d %s %s\n" "$a" "$lineno" "$macrono" "${meta[*]}" "$line"
                    # exit 1
                fi
                skip=1
            elif [[ "$line" =~ ^# ]]; then
                skip=1
            elif [[ "$line" =~ ^(type|attribute|role|typeattribute|typealias|class|attribute_role|roleattribute)\  ]]; then
                skip=1
            elif [[ "$line" =~ ^(sid|portcon|fs_use_trans|genfscon|fs_use_xattr|fs_use_task)\  ]]; then
                # maybe could handle these, but it is used only on /kerne/
                skip=1
            elif [[ "$line" =~ ^gen_tunable ]]; then
                skip=1
            elif [[ "$line" =~ ^require\ \{ ]]; then
                state=require
                skip=1
            elif [[ "$line" =~ ^if\(.*\)\ *\{ ]]; then
                # maybe could handle this, but it is used only on kernel.te and such
                state=if
                skip=1
            elif [[ "$line" =~ ^gen_require\( ]]; then
                state=gen_require
                skip=1
            elif [[ "$line" =~ ^[a-zA-Z0-9_]+\( ]]; then
                :
            elif [[ "$line" =~ ^(allow|auditallow|dontaudit|neverallow|allowxperm|auditallowxperm|dontauditxperm|neverallowxperm|type_transition|role_transition)\  ]]; then
                :
            else
                printf "$state unk error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
        elif [ "$state" = require ]; then
            if [ "$line" = "}" ]; then
                state=line
            fi
            skip=1
        elif [ "$state" = if ]; then
            if [ "$line" = "}" ]; then
                state=line
            fi
            skip=1
        elif [ "$state" = gen_require ]; then
            if [[ "$line" =~ ^\'\) ]]; then
                state=line
            fi
            skip=1
        elif [ "$state" = macroskip ]; then
            # printf "error(%s:%d): %d:%d %s\n" "$a" $lineno $macrono $macroskip "$line"
            if (( macrono == macroskip )); then
                state=line
                macroskip=-1
            fi
            skip=1
        fi

        if (( skip )); then
            outdel+=("$out")
            continue
        fi

        if [ "$out" -nt "$a" ] && [ "$out" -nt "$0" ]; then
            continue
        fi
        requires="$(gen_require "$line")"
        if [ "$requires" ]; then
            requires="$(printf "require {\n%s\n}\n" "$requires")"
        fi
		printf "policy_module(%s_%d, 1.0.0)\n%s\n%s\n" "$(basename -- "$a" .te)" "$lineno" "$requires" "$line" > "$out".tmp
        if [ ! -f "$out" ] || ! cmp -s "$out".tmp "$out"; then
            mv -- "$out".tmp "$out"
        else
            outdel+=("$out".tmp)
        fi
	done < <(sed -r 's/^[[:space:]]*//;s/[[:space:]]*#.*//' "$a")
done

if (( ${#outdel[@]} + ${#old_files[@]} )); then
    rm -f -- "${outdel[@]}" "${!old_files[@]}"
fi
rm -f "$D"/tokens.txt "$D"/requires.txt
