#!/bin/bash

set -epu -o pipefail

for a in "$@"; do
	cnt=0
	sed -rn '
s/^[[:space:]]*//;
/^require [{]/,/^[}]/{
    /^require [{]/d;
    /^[}]/d;
    /^#/d;
    s/[[:space:]]*#.*//;
    p;
}' "$a"|sort -u > local_lines/requires.txt
    sed -r '/^(type|attribute) /!d;s/ alias /;\ntype /' "$a" >> local_lines/requires.txt
	while read -r line; do
        out=local_lines/"$(basename -- "$a" .te)"_"$cnt".te
        if [ "$out" -nt "$a" ] && [ "$out" -nt "$0" ]; then
            continue
        fi
		sed -r 's/^[^(), :;{}]*//;s/[(), :;{}]/\n/g' <<< "$line" | sed '/./!d;s/^/ /' | sort -u > local_lines/tokens.txt
		requires="$((
            fgrep -f local_lines/tokens.txt local_lines/requires.txt
            if [[ "$line" =~ \(.*\) ]]; then
                sed -r 's/"[^"]*"//;s/^[^(), :;{}]*//;s/[(), :;{}]/\n/g' <<< "$line"
            else
                sed -r 's/self:.*//;s/ alias / /;s/^[^ ]* //;s/:.*//;s/[(), :;{}]/\n/g' <<< "$line"
            fi | sed -r '
/./!d;
/_t$/!{
    s/^/attribute /;
}
/_t$/{
    s/^/type /;
}
s/$/;\n/;
'
            if [[ "$line" =~ ^dev_ ]]; then
                echo "type device_t;"
            fi
        )|sort -u)"
		printf "policy_module(%s_%d, 1.0.0)\nrequire {\n%s\n}\n%s\n" "$(basename -- "$a" .te)" $cnt "$requires" "$line" > "$out".tmp
        if [ ! -f "$out" ] || ! cmp -s "$out".tmp "$out"; then
            mv -- "$out".tmp "$out"
        fi
		(( cnt++ )) || :
	done < <(sed -r '
s/^[[:space:]]*//;
/^(policy_module|tunable_policy|optional_policy|gen_tunable|ifdef)[(]/d;
/^require [{]/,/^[}]/d;
/^#/d;
s/[[:space:]]*#.*//;
/^$/d;
/^type /d;
/^attribute /d;
/^['"'"'][)]/d;
' "$a")
done
