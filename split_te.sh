#!/bin/bash

set -epu -o pipefail

D=split_lines

mkdir -p "$D"

filter_require() {
    sed -r '
/./!d;
/_r$/{
    s/^/role /;
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

gen_require() {
    local line="$1"; shift
    sed -r 's/^[^(), :;{}]*//;s/[(), :;{}]/\n/g' <<< "$line" | sed '/./!d;s/^/ /' | sort -u > "$D"/tokens.txt
    (
            grep -Ff "$D"/tokens.txt "$D"/requires.txt

            # KLUDGE, seems dev_ macros miss type device_t
            if [[ "$line" =~ ^dev_ ]]; then
                echo "type device_t;"
            fi

            if [[ "$line" =~ \(.*\) ]]; then
                sed -r 's/"[^"]*"//;s/^[^(), :;{}]*//;s/[(), :;{}]/\n/g' <<< "$line"
            else
                sed -r 's/self:.*//;s/ alias / /;s/^[^ ]* //;s/:.*//;s/[(), :;{}]/\n/g' <<< "$line"
            fi | filter_require
    ) | sort -u
}

declare -A old_files=()
outdel=()

for a in "$@"; do
    while IFS= read -d '' -r old && [ "$old" ]; do
        old_files["$old"]=1
    done < <(find "$D" -type f -name "$(basename -- "$a" .te)_*.te" -print0)

    (
	    sed -rn '
s/^[[:space:]]*//;
s/[[:space:]]*#.*//;
/^#/d;
/^require [{]/,/^[}]/{
    /^require [{]/d;
    /^[}]/d;
    p;
}
' "$a"
        sed -r '
/^(type|attribute|typeattribute|typealias) /!d;
s/^typealias /type /;
s/^typeattribute ([^ ]*) (.*)/type \1;\nattribute \2/;
s/ alias /;\ntype /;
' "$a"
    ) | sort -u > "$D"/requires.txt

	lineno=0
    state=line
    macrono=0
    macroskip=-1
	while read -r line; do
		(( lineno++ )) || :
        out="$D"/"$(basename -- "$a" .te)"_"$lineno".te
        unset old_files["$out"]

        if [ ! "$line" ]; then
            outdel+=("$out")
            continue
        fi

        skip=0

        if [[ "$line" =~ ^(optional_policy|tunable_policy|ifdef|ifndef)\( ]]; then
            (( macrono++ )) || :
        elif [[ "$line" =~ ^\'\) ]]; then
            (( macrono-- )) || :
        fi

        if [ "$state" = line ]; then
            if [[ "$line" =~ ^policy_module ]]; then
                skip=1
            elif [[ "$line" =~ ^optional_policy ]]; then
                skip=1
            elif [[ "$line" =~ ^tunable_policy ]]; then
                skip=1
            elif [[ "$line" =~ ^ifdef ]]; then
                if [[ "$line" =~ ^ifdef\(\`distro_redhat\',\`$ ]]; then
                    skip=1
                else
                    printf "error(%s:%d): %s\n" "$a" "$lineno" "$line"
                    exit 1
                fi
            elif [[ "$line" =~ ^ifndef ]]; then
                # printf "error(%s:%d): %s\n" "$a" $lineno "$line"
                if [[ "$line" =~ ^ifndef\(\`distro_redhat\',\`$ ]]; then
                    if (( macroskip != -1 )); then
                        # printf "error(%s:%d): %s\n" "$a" $lineno "$line"
                        exit 1
                    fi
                    state=macroskip
                    macroskip=$(( macrono - 1 ))
                else
                    printf "error(%s:%d): %s\n" "$a" "$lineno" "$line"
                    exit 1
                fi
                skip=1
            elif [[ "$line" =~ ^\'\) ]]; then
                skip=1
            elif [[ "$line" =~ ^# ]]; then
                skip=1
            elif [[ "$line" =~ ^(type|attribute|role|typeattribute|typealias)\  ]]; then
                skip=1
            elif [[ "$line" =~ ^gen_tunable ]]; then
                skip=1
            elif [[ "$line" =~ ^require\ \{ ]]; then
                state=require
                skip=1
            elif [[ "$line" =~ ^[a-z0-9_]+\( ]]; then
                :
            elif [[ "$line" =~ ^(allow|auditallow|dontaudit|neverallow|allowxperm|auditallowxperm|dontauditxperm|neverallowxperm)\  ]]; then
                :
            else
                printf "error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
        elif [ "$state" = require ]; then
            if [ "$line" = "}" ]; then
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
