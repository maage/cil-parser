#!/bin/bash

set -epu -o pipefail

D=split_lines

mkdir -p "$D"

# input: tokens of unknown type, or some bogus tokens
# output: type/role/attribute/etc clauses for each valid token
filter_require() {
    sed -r '
s/^ *//;
s/ *$//;
/./!d;
/^ZZZ$/d;
/^(dir|file|sock_file)$/d;
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

# generate require content for a line
rr_str='s/ *"[^"]*" */ /;'
rr1='
s/, *s0 - mcs_systemhigh//;
'
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
    /./!d;
    '| sort -u
}

declare -A old_files=()
outdel=()

for a in "$@"; do
    while IFS= read -d '' -r old && [ "$old" ]; do
        old_files["$old"]=1
    done < <(find "$D" -type f -name "$(basename -- "$a" .te)_*.te" -print0)

	lineno=0
    # depth increases if we go inside of ( or { and decreases if ) or }
    depth=0
    # if state is true, then print, if false, not
    state=(true)
    # this represents other branch value in if then else or similar structures
    branch=(true)
    # type of structure we are currently in, "", {}, ()
    struct=("")
	while read -r line; do
		(( lineno++ )) || :
        # printf "$state (%s:%d): (%s:%d) %s\n" "$a" "$lineno" "${state[*]}" "$depth" "$line"

        out="$D"/"$(basename -- "$a" .te)"_"$lineno".te
        unset old_files["$out"]

        if [ ! "$line" ]; then
            outdel+=("$out" "${out%.te}".fc "${out%.te}".if)
            continue
        fi

        skip=1

        # first go over different lines where we change state, but do not output
        # last go over known states and output if state allows
        # keep everything in one if/elif and always handle error in else
        if [[ "$line" =~ ^(gen_require|optional_policy)\( ]]; then
            (( depth++ )) || :
            struct["$depth"]="()"
            if [[ "$line" =~ ^(gen_require|optional_policy)\(\`$ ]]; then
                state["$depth"]="${state[$(((depth-1)))]}"
                branch["$depth"]="${state[$depth]}"
            else
                printf "${state[$depth]} bad error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
        elif [[ "$line" =~ ^(ifdef|ifndef)\( ]]; then
            (( depth++ )) || :
            struct["$depth"]="()"
            if [[ "$line" =~ ^ifdef\(\`(distro_redhat|enable_mcs|hide_broken_symptoms|enable_ubac|ipa_helper_noatsecure|targeted_policy)\',\ *\`$ ]]; then
                # define true, value true
                state["$depth"]="${state[$(((depth-1)))]}"
                branch["$depth"]=false
            elif [[ "$line" =~ ^ifdef\(\`(distro_debian|distro_gentoo|distro_rhel4|distro_suse|distro_ubuntu|direct_sysadm_daemon|enable_mls|sulogin_no_pam|TODO)\',\ *\`$ ]]; then
                # define false, value false
                state["$depth"]=false
                branch["$depth"]="${state[$(((depth-1)))]}"
            elif [[ "$line" =~ ^ifndef\(\`(distro_debian|distro_gentoo|distro_rhel4|distro_suse|distro_ubuntu|direct_sysadm_daemon|enable_mls|sulogin_no_pam|TODO)\',\ *\`$ ]]; then
                # define false, value true
                state["$depth"]="${state[$(((depth-1)))]}"
                branch["$depth"]=false
            elif [[ "$line" =~ ^ifndef\(\`(distro_redhat|enable_mcs|hide_broken_symptoms|enable_ubac|ipa_helper_noatsecure|targeted_policy)\',\ *\`$ ]]; then
                # define true, value false
                state["$depth"]=false
                branch["$depth"]="${state[$(((depth-1)))]}"
            elif [[ "$line" =~ ^ifdef\(\`[^\)]*\',\ *\`define\([^\)]*\)\'\)$ ]]; then
                :
            else
                printf "${state[$depth]} ifdef error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
        elif [[ "$line" =~ ^(tunable_policy)\( ]]; then
            (( depth++ )) || :
            struct["$depth"]="()"
            if [[ "$line" =~ ^(tunable_policy)\(\`[^\']*\',\ *\`(\',\ *\`)?$ ]]; then
                state["$depth"]="${state[$(((depth-1)))]}"
                branch["$depth"]="${state[$depth]}"
            else
                printf "${state[$depth]} bad error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
        elif [[ "$line" =~ ^require\ *\{$ ]]; then
            (( depth++ )) || :
            struct["$depth"]="{}"
            state["$depth"]=false
            branch["$depth"]="${state[$(((depth-1)))]}"
        elif [[ "$line" =~ ^if\([^\)]*\)\ *\{$ ]]; then
            (( depth++ )) || :
            struct["$depth"]="{}"
            state["$depth"]=false
            branch["$depth"]="${state[$(((depth-1)))]}"
        elif [ "$line" = "}" ]; then
            if (( depth == 0 )); then
                printf "${state[$depth]} depth < 0: error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            if [ "${struct[$depth]}" != "{}" ]; then
                printf "${state[$depth]} bogus }: error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            unset struct["$depth"]
            unset state["$depth"]
            unset branch["$depth"]
            (( depth-- )) || :
        elif [[ "$line" =~ \'\) ]]; then
            if [[ "$line" =~ ^\'\)$ ]]; then
                if (( depth == 0 )); then
                    printf "${state[$depth]} depth < 0: error(%s:%d): %s\n" "$a" "$lineno" "$line"
                    exit 1
                fi
                if [ "${struct[$depth]}" != "()" ]; then
                    printf "${state[$depth]} bogus ): error(%s:%d): %s\n" "$a" "$lineno" "$line"
                    exit 1
                fi
            else
                printf "${state[$depth]} bad error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            unset struct["$depth"]
            unset state["$depth"]
            unset branch["$depth"]
            (( depth-- )) || :
        elif [[ "$line" =~ ^\',\ *\`$ ]]; then
            if [ "${struct[$depth]}" != "()" ]; then
                printf "${state[$depth]} bogus ,: error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            tmp="${state[$depth]}"
            state["$depth"]="${branch[$depth]}"
            branch["$depth"]="$tmp"
        elif [[ "$line" =~ ^(gen_tunable|policy_module)\([^\)]*\)$ ]]; then
            :
        elif [[ "$line" =~ ^# ]]; then
            :
        elif [ "${state[$depth]}" = true ]; then
            if [[ "$line" =~ ^(type|attribute|role|typeattribute|typealias|class|attribute_role|roleattribute)\  ]]; then
                # definitions skipped
                :
            elif [[ "$line" =~ ^(sid|portcon|fs_use_trans|genfscon|fs_use_xattr|fs_use_task)\  ]]; then
                # maybe could handle these, but they are used only on /kernel/
                :
            elif [[ "$line" =~ ^[a-zA-Z0-9_]+\( ]]; then
                # interface rules
                skip=0
            elif [[ "$line" =~ ^(allow|auditallow|dontaudit|neverallow|allowxperm|auditallowxperm|dontauditxperm|neverallowxperm|type_transition|role_transition)\  ]]; then
                # rules
                skip=0
            else
                printf "${state[$depth]} unk error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
        elif [ "${state[$depth]}" = false ]; then
            :
        else
            printf "${state[$depth]} unk error(%s:%d): %s\n" "$a" "$lineno" "$line"
            exit 1
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
