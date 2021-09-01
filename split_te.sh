#!/bin/bash

set -epu -o pipefail

D=sl
declare -i OPT_kludge_dev=0

while (( $# )); do
    case "$1" in
        --directory) (( $# > 1 )) || { printf "ERROR: %s %s\n" "$0" "$*"; exit 2; }; D="$2"; shift 2 ;;
        --directory=*) D="${1#--directory=}"; shift ;;
        --kludge-dev) OPT_kludge_dev=1; shift ;;
        --) shift; break ;;
        *) printf "ERROR: %s %s\n" "$0" "$*"; exit 2 ;;
    esac
done

mkdir -p "$D" tmp

# input: tokens of unknown type, or some bogus tokens
# output: type/role/attribute/etc clauses for each valid token
filter_require() {
    sed -r '
s/^ *//;
s/ *$//;
s/;$//;
/^(dir|file|sock_file|self|[a-z_]*_class_set|\*)$/d;
/^(mcs_system(low|high)|mcs_allcats|mls_systemhigh|s0)$/d;
' | sed -r '
/./!d;
/_r$/{
    s/^/role /;
}
/_roles$/{
    s/^/attribute_role /;
}
/_t$/{
    s/^/type /;
}
/^(user|unconfined)$/{
    s/^(.*)$/type \1_t/;
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
rr2='s/ -/ /g;s/[() ,{}~]/\n/g;'
gen_require() {
    local line="$1"; shift
    local ll l3
    (
        if [[ "$line" =~ \(.*\) ]]; then
            # M4 macro
            # KLUDGE some domain_templates
            case "$line" in
                "cron_admin_role("*) line="${line%)}""_t)" ;;
                "cron_common_crontab_template("*) line="${line%)}""_t)" ;;
                "cron_role("*) line="${line%)}""_t)" ;;
                "piranha_domain_template("*) line="$(sed -r 's/\((.*)\)/(piranha_\1_t)/' <<< "$line")" ;;
                "postfix_server_domain_template("*) line="${line%(*)}""(foo_t)" ;;
                "qmail_child_domain_template("*) line="$(sed -r 's/\(([^ ]*),/(\1_t,/' <<< "$line")" ;;
                "ssh_server_template("*) line="${line%(*)}""()" ;;
            esac
            if (( OPT_kludge_dev )); then
                # KLUDGE: some upstream interfaces miss types
                # this should be fixed by upstream patches
                case "$line" in
                    "dev_create_all_blk_files("*) echo 'device_t' | filter_require ;;
                    "dev_delete_all_blk_files("*) echo 'device_t' | filter_require ;;
                    "dev_create_all_chr_files("*) echo 'device_t' | filter_require ;;
                    "dev_delete_all_chr_files("*) echo 'device_t' | filter_require ;;
                    "dev_setattr_all_chr_files("*) echo 'device_t' | filter_require ;;
                    "dev_setattr_generic_usb_dev("*) echo 'device_t' | filter_require ;;
                esac
            fi
            line="${line#*\(}"
            line="${line%)*}"
            sed -r "${rr_str}${rr2}" <<< "$line" | filter_require
        elif [[ "$line" =~ ^role_transition ]]; then
            # role_transition
            line="${line#role_transition}"
            # rest
            sed -r  "${rr_str}"'s/^ *([^ ]*) ([^ ]*) ([^ ;]*);$/\1\n\2\n\3/;' <<< "$line" | filter_require
        elif [[ "$line" =~ ^type_transition ]]; then
            # type_transition
            line="${line#type_transition}"
            # class
            sed -r  "${rr_str}"'s/^ *[^ ]* [^ :]*:([^ ]*) .*/class \1 getattr;/;' <<< "$line"
            # rest
            sed -r  "${rr_str}"'s/^ *([^ ]*) ([^ :]*):[^ ]* ([^ ;]*) *;*$/\1\n\2\n\3/;' <<< "$line" | filter_require
        elif [[ "$line" =~ ^role_transition ]]; then
            # role / type_transition
            line="${line#role_transition}"
            # rest
            sed -r  's/^ *([^ ]*) ([^ ]*) ([^ ;]*);$/\1\n\2\n\3/;' <<< "$line" | filter_require
        else
            line="$(sed -r 's/~//g;s/\*:[a-z_]+ +\*;//;s/ +-/ /g;' <<< "$line")"
            if [[ "$line" =~ :\ *\{ ]]; then
                # handle class with group
                local l3 l4 l2=()
                ll="${line##*:}"
                l3="${ll#*\}}"
                ll="${ll#*\{}"
                readarray -d ' ' l2 <<< "${ll%%\}*}"
                for l4 in "${l2[@]}"; do
                    l4="$(printf "%s" "$l4" | sed -r 's/^ *//;s/ *$//;/./!d')"
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
                    printf "%s\n" "${ll%%\}*}" | sed -r 's/ /\n/g;' | filter_require
                    ll="${ll#*\}}"
                done
                line="$(sed -r 's/[{][^}]*[}]/*/g;' <<< "$line")"
            fi
            # sed -r 's/^[^ ]* [^ ]* [^ ]*:(.*;)$/class \1/;' <<< "$line"
            sed -r '
            s/^[^ ]* +//;
            s/^([^ ]*) +self/\1/;
            s/ +alias +/ /;
            s/^([^ ]*) +([^ ;]*);?/\1\n\2/;
            ' <<< "$line" | filter_require
        fi
    ) | sed -r '
    /^class [^ ]*_class_set /d;
    /./!d;
    '| sort -u
}

if_gen_require() {
    (( $# )) || return 0
    printf "require {\n"
    local -A seen=()
    for r in "${requiresa[@]}"; do
        if [ "${seen[$r]:-}" ]; then
            continue
        fi
        printf "%s\n" "$r"
        seen["$r"]=1
    done
    printf "}\nx"
}

handle_if() {
    local a="$1"; shift

    local outbase="${a##*/}"
    outbase="${outbase%.if}"xif

    declare -A old_files=()
    local old
    for old in "$D"/"$outbase"_*.te; do
        [ -f "$old" ] || continue
        old_files["$old"]=1
    done

    local -i is_container=0
    if [ "$outbase" == "containerxif" ]; then
        is_container=1
    fi

    local line=
    local -i changes=0
    local -i lineno=0
    local state="out"
    local ptypes=()
    local ifa=
    local todel=()

    while read -r line; do
        (( lineno++ )) || :

        local out="$D"/"$outbase"_"$lineno".te
        unset old_files["$out"]

        if (( ${#todel[@]} > 1000 )); then
            rm -f -- "${todel[@]}"
            todel=()
        fi

        if [ ! "$line" ]; then
            if [ -f "$out" ]; then
                changes=1
            fi
            todel+=("$out" "${out%.te}".fc "${out%.te}".if)
            continue
        fi

        local -i skip=1

        if [[ "$state" == "out" ]]; then
            if [ "$line" == "## <summary>" ]; then
                state="in"
            elif [[ "$line" =~ ^##\ \<param ]]; then
                printf "ERROR(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            elif [[ "$line" =~ ^interface ]]; then
                if (( is_container )) && [[ "$line" =~ \`docker_ ]]; then
                    # container.if has multiple undocumented docker_
                    # interfaces that mirror container interfaces
                    :
                else
                    printf "ERROR(%s:%d): %s\n" "$a" "$lineno" "$line"
                    exit 1
                fi
            else
                :
            fi
        elif [[ "$state" == "in" ]]; then
            if [[ "$line" =~ ^##\ \<param\ name=\"[^\"]*\".*optional=\"true\" ]]; then
                :
            elif [[ "$line" =~ ^##\ \<param\ name=\"[^\"]*\" ]]; then
                local ptype="${line#\#\# <param name=\"}"
                ptype="${ptype%%\"*}"
                ptypes+=("$ptype")
            elif [[ "$line" =~ ^interface\(\`[^\']*\' ]]; then
                ifa="${line#interface(\`}"
                ifa="${ifa%%\'*}"
                state="out"
                case "$ifa" in
                    selinux_labeled_boolean) ;;
                    *) skip=0 ;;
                esac
            elif [[ "$line" =~ ^##\ \<summary\> ]]; then
                ptypes=()
                ifa=
            else
                :
            fi
        fi

        if (( skip )); then
            if [ -f "$out" ]; then
                changes=1
            fi
            todel+=("$out")
            continue
        fi

        if [ "$out" -nt "$a" ]; then
            continue
        fi

        local requiresa=()
        local params=() pt
        for pt in "${ptypes[@]}"; do
            case "$pt" in
                domain|type|peer_domain|target_domain|source_domain|userdomain|entrypoint|entry_point|entry_file|file_type|filetype|pty_type|tmpfs_type|sock_file_type|script_file|user_domain|tty_type|sock_file|directory_type|init_script_file|home_type|object_type) requiresa+=("type bin_t;"); params+=("bin_t") ;;
                "private type"|private_type) requiresa+=("type foo_t;"); params+=("foo_t") ;;
                class|object_class|object|"objectclass(es)") requiresa+=("class file read;"); params+=("file") ;;
                role|source_role) requiresa+=("role system_r;"); params+=("system_r") ;;
                user_role) requiresa+=("role user_r;"); params+=("user_r") ;;
                role_prefix) requiresa+=("role user_r;"); params+=("user") ;;
                userdomain_prefix) requiresa+=("type user_t;"); params+=("user") ;;
                domain_prefix) requiresa+=("type foo_t;"); params+=("foo") ;;
                tunable|boolean) params+=("foo_tunable") ;;
                range) params+=("s0 - s0") ;;
                filename|file|name) params+=('"foo"') ;;
                *) printf "MISSING: %s\n" "$pt"; exit  1 ;;
            esac
        done

        ifa+="("
        local p
        for p in "${params[@]}"; do
            ifa+="$p, "
        done
        ifa="${ifa%, }"
        ifa+=")"
        local requires
        requires="$(if_gen_require "${requiresa[@]}")"
        printf "# source: %s\npolicy_module(%s_%d, 1.0.0)\n%s%s\n" "$a" "$outbase" "$lineno" "${requires%x}" "$ifa" > "$out".tmp
        if [ ! -f "$out" ] || ! cmp -s "$out".tmp "$out"; then
            mv -- "$out".tmp "$out"
            changes=1
        else
            todel+=("$out".tmp)
        fi
        ptypes=()
        ifa=
    done < <(sed -r 's/^[[:space:]]*(interface|## <param name=|## <summary)(.*)/\1\2/;t a;s/.*//;:a' "$a")

    if (( changes + ${#old_files[@]} )); then
        # If any of the files change, then we need to be sure there is no leftovers of old files
        find tmp -type f -name "${outbase}_*" -delete
    fi

    if (( ${#todel[@]} )); then
        rm -f -- "${todel[@]}"
    fi

    if (( ${#old_files[@]} )); then
        rm -f -- "${!old_files[@]}"
    fi
}

pop_state() {
    # shellcheck disable=SC2034 # it does not currently handle namerefs
    local -n struct_="$1"; shift
    local -n state_="$1"; shift
    local -n branch_="$1"; shift
    local -n depth_="$1"; shift
    unset struct_["$depth_"]
    unset state_["$depth_"]
    unset branch_["$depth_"]
    (( depth_-- )) || :
}

check_depth() {
    # shellcheck disable=SC2034 # it does not currently handle namerefs
    local -n state_="$1"; shift
    local -n depth_="$1"; shift
    local -n a_="$1"; shift
    local -n lineno_="$1"; shift
    local -n line_="$1"; shift
    if [ ! "${state_[$depth_]:-}" ]; then
        printf "${state_[*]} depth undefined error(%s:%d): %s\n" "$a_" "$lineno_" "$line_"
        exit 1
    fi
}

swap_state_branch() {
    # shellcheck disable=SC2034 # it does not currently handle namerefs
    local -n state_="$1"; shift
    local -n branch_="$1"; shift
    local -n depth_="$1"; shift
    local tmp="${state_[$depth_]}"
    state_["$depth_"]="${branch_[$depth_]}"
    branch_["$depth_"]="$tmp"
}

handle_te() {
    local a="$1"; shift

    local outbase="${a##*/}"
    outbase="${outbase%.te}"

    declare -A old_files=()
    local old
    for old in "$D"/"$outbase"_*.te; do
        [ -f "$old" ] || continue
        old_files["$old"]=1
    done

    local line=
    local -i changes=0
    local -i lineno=0
    local todel=()
    # depth increases if we go inside of ( or { and decreases if ) or }
    local -i depth=0
    # if state is true, then print, if false, not
    local state=("true")
    # this represents other branch value in if then else or similar structures
    local branch=("true")
    # type of structure we are currently in, "", {}, ()
    local struct=("")
    # KLUDGE: add some defaults too:
    declare -A defines=(
        [sulogin_pam]="false"
        [sulogin_no_pam]="false"
    )
    # from tmp/global_bools.conf
    declare -A bools=(
        [allow_execheap]="false"
        [allow_execmem]="false"
        [allow_execmod]="false"
        [allow_execstack]="false"
        [allow_polyinstantiation]="false"
        [allow_raw_memory_access]="false"
        [allow_ypbind]="false"
        [console_login]="true"
        [global_ssp]="false"
        [mail_read_content]="false"
        [nfs_export_all_ro]="false"
        [nfs_export_all_rw]="false"
        [secure_mode]="false"
        [use_nfs_home_dirs]="false"
        [user_tcp_server]="false"
        [user_udp_server]="false"
        [use_samba_home_dirs]="false"
    )
    if [ ! -f tmp/all_interfaces.conf ]; then
        printf "MISSING: tmp/all_interfaces.conf\n"
        printf "maybe run: make\n"
        exit 1
    fi
    # Some modules check interfaces using ifdef, so:
    local key
    while read -r key; do
        [ "$key" ] || continue
        defines["$key"]="true"
    done < <(sed  -nr 's/^[[:space:]]*define[(][`]'"([^']*)'"',[`] dnl$/\1/p' tmp/all_interfaces.conf)

    while read -r line; do
        (( lineno++ )) || :
        # printf "$state (%s:%d): (%s:%d) %s\n" "$a" "$lineno" "${state[*]}" "$depth" "$line"

        local out="$D"/"$outbase"_"$lineno".te
        unset old_files["$out"]

        if (( ${#todel[@]} > 1000 )); then
            rm -f -- "${todel[@]}"
            todel=()
        fi

        if [ ! "$line" ]; then
            if [ -f "$out" ]; then
                changes=1
            fi
            todel+=("$out" "${out%.te}".fc "${out%.te}".if)
            continue
        fi

        local -i skip=1
        local pre=

        # first go over different lines where we change state, but do not output
        # last go over known states and output if state allows
        # keep everything in one if/elif and always handle error in else
        if [[ "$line" =~ ^(gen_require|optional_policy)\( ]]; then
            (( depth++ )) || :
            struct["$depth"]="()"
            if [[ "$line" =~ ^(gen_require|optional_policy)\(\`$ ]]; then
                state["$depth"]="${state[$(((depth-1)))]}"
                branch["$depth"]="${state[$depth]}"
            elif [[ "$line" =~ ^(gen_require)\(\`[^\']*\'\)$ ]]; then
                state["$depth"]="${state[$(((depth-1)))]}"
                branch["$depth"]="${state[$depth]}"
            else
                printf "${state[$depth]:-} bad error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            check_depth state depth a lineno line
        elif [[ "$line" =~ ^(ifdef|ifndef)\( ]]; then
            (( depth++ )) || :
            struct["$depth"]="()"
            if [[ "$line" =~ ^ifdef\(\`(distro_redhat|enable_mcs|hide_broken_symptoms|init_systemd|targeted_policy)\',\ *\`$ ]]; then
                # define true, value true
                state["$depth"]="${state[$(((depth-1)))]}"
                branch["$depth"]="false"
            elif [[ "$line" =~ ^ifdef\(\`(distro_debian|distro_gentoo|distro_rhel4|distro_suse|distro_ubuntu|direct_sysadm_daemon|enable_mls|enable_ubac|TODO)\',\ *\`$ ]]; then
                # define false, value false
                state["$depth"]="false"
                branch["$depth"]="${state[$(((depth-1)))]}"
            elif [[ "$line" =~ ^ifndef\(\`(distro_debian|distro_gentoo|distro_rhel4|distro_suse|distro_ubuntu|direct_sysadm_daemon|enable_mls|enable_ubac|TODO)\',\ *\`$ ]]; then
                # define false, value true
                state["$depth"]="${state[$(((depth-1)))]}"
                branch["$depth"]="false"
            elif [[ "$line" =~ ^ifndef\(\`(distro_redhat|enable_mcs|hide_broken_symptoms|init_systemd|targeted_policy)\',\ *\`$ ]]; then
                # define true, value false
                state["$depth"]="false"
                branch["$depth"]="${state[$(((depth-1)))]}"
            elif [[ "$line" =~ ^ifdef\(\`[^\)]*\',\ *\`define\([^\)]*\)\'\)$ ]]; then
                # immediately back depth
                pop_state struct state branch depth
                check_depth state depth a lineno line
            else
                declare -i kv_found=0
                if [[ "$line" =~ ^ifdef\(\`[^\']*\',\ *\`$ ]]; then
                    local key="${line#ifdef(\`}"
                    key="${key%\',*}"
                    value="${defines[$key]:-}"
                    if [ "$value" ]; then
                        if [ "$value" == "true" ]; then
                            # define true, value true
                            state["$depth"]="${state[$(((depth-1)))]}"
                            branch["$depth"]="false"
                            kv_found=1
                        elif [ "$value" == "false" ]; then
                            # define true, value false
                            state["$depth"]="false"
                            branch["$depth"]="${state[$(((depth-1)))]}"
                            kv_found=1
                        fi
                    fi
                elif [[ "$line" =~ ^ifndef\(\`[^\']*\',\ *\`$ ]]; then
                    local key="${line#ifndef(\`}"
                    key="${key%\',*}"
                    value="${defines[$key]:-}"
                    if [ "$value" ]; then
                        if [ "$value" == "true" ]; then
                            # define false, value true
                            state["$depth"]="false"
                            branch["$depth"]="${state[$(((depth-1)))]}"
                            kv_found=1
                        elif [ "$value" == "false" ]; then
                            # define false, value false
                            state["$depth"]="${state[$(((depth-1)))]}"
                            branch["$depth"]="false"
                            kv_found=1
                        fi
                    fi
                fi
                if  (( !kv_found )); then
                    printf "${state[$depth]:-} ifdef error(%s:%d): %s\n" "$a" "$lineno" "$line"
                    exit 1
                fi
            fi
            check_depth state depth a lineno line
        elif [[ "$line" =~ ^(tunable_policy)\( ]]; then
            (( depth++ )) || :
            struct["$depth"]="()"
            if [[ "$line" =~ ^(tunable_policy)\(\`[^\']*\',\ *\`(\',\ *\`)?$ ]]; then
                state["$depth"]="${state[$(((depth-1)))]}"
                branch["$depth"]="${state[$depth]}"
            else
                printf "${state[$depth]:-} bad error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
        elif [[ "$line" =~ ^require\ *\{$ ]]; then
            (( depth++ )) || :
            struct["$depth"]="{}"
            state["$depth"]="false"
            branch["$depth"]="${state[$(((depth-1)))]}"
            check_depth state depth a lineno line
        elif [[ "$line" =~ ^if\ *\([^\)]*\)\ *\{$ ]]; then
            declare -i kv_found=0
            local key="${line#*(}"
            key="${key%)*}"
            value=
            if [[ "$key" =~ [\!\&\|\ ] ]]; then
                # complex logic
                # so far handle: value && || !value
                full_key="$key"
                val=1
                op=and
                while [ "$full_key" ]; do
                    if [ "$full_key" != "${full_key# }" ]; then
                        full_key="${full_key# }"
                        continue
                    fi
                    declare -i is_pos=1
                    key=
                    token="${full_key%% *}"
                    if [ "$token" == "&&" ]; then
                        full_key="${full_key#&&}"
                        op="and"
                        continue
                    elif [ "$token" == "||" ]; then
                        full_key="${full_key#||}"
                        op="or"
                        continue
                    elif [ "$token" == "!" ]; then
                        full_key="${full_key#$token}"
                        while [ "$full_key" != "${full_key# }" ]; do
                            full_key="${full_key# }"
                        done
                        token="${full_key%% *}"
                        full_key="${full_key#$token}"
                        key="$token"
                        is_pos=0
                    elif [[ "$token" =~ ^\! ]]; then
                        full_key="${full_key#$token}"
                        key="${token#!}"
                        is_pos=0
                    else
                        full_key="${full_key#$token}"
                        key="$token"
                        is_pos=1
                    fi
                    [ "$key" ]
                    case "$op" in
                        "and")
                            # echo "$op pre key=$key val=$val $is_pos ${bools[$key]:-}"
                            case "${bools[$key]:-}" in
                                "true") (( val=(val && is_pos) )) || : ;;
                                "false") (( val=(val && (!is_pos)) )) || : ;;
                                *) break ;;
                            esac
                            # echo "$op post val=$val"
                            ;;
                        "or")
                            # echo "$op pre key=$key val=$val $is_pos ${bools[$key]:-}"
                            case "${bools[$key]:-}" in
                                "true") (( val=(val || is_pos) )) || : ;;
                                "false") (( val=(val || (!is_pos)) )) || : ;;
                                *) break ;;
                            esac
                            # echo "$op post val=$val"
                            ;;
                        *) break ;;
                    esac
                done
                if (( val )); then
                    value="true"
                else
                    value="false"
                fi
                # if wholly eat full_key
                if [ ! "$full_key" ]; then
                    kv_found=1
                fi
            else
                # echo "bool '$key' '${bools[$key]:-}'"
                value="${bools[$key]:-}"
                if [ "$value" ]; then
                    kv_found=1
                fi
            fi
            if (( !kv_found )); then
                printf "${state[$depth]:-} if error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            (( depth++ )) || :
            struct["$depth"]="{}"
            if [ "$value" == "true" ]; then
                # define true, value true
                state["$depth"]="${state[$(((depth-1)))]}"
                branch["$depth"]="false"
            elif [ "$value" == "false" ]; then
                # define true, value false
                state["$depth"]="false"
                # shellcheck disable=SC2034 # this is false positive, branch clearly is used
                branch["$depth"]="${state[$(((depth-1)))]}"
            else
                printf "${state[$depth]:-} if value error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            check_depth state depth a lineno line
        elif [ "$line" == "}" ]; then
            if (( depth == 0 )); then
                printf "${state[$depth]:-} depth < 0: error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            if [ "${struct[$depth]}" != "{}" ]; then
                printf "${state[$depth]:-} bogus }: error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            pop_state struct state branch depth
            check_depth state depth a lineno line
        elif [[ "$line" =~ \'\) ]]; then
            if [[ "$line" =~ ^\'\)(\ *dnl\ .*)?$ ]]; then
                if (( depth == 0 )); then
                    printf "${state[$depth]:-} depth < 0: error(%s:%d): %s\n" "$a" "$lineno" "$line"
                    exit 1
                fi
                if [ "${struct[$depth]}" != "()" ]; then
                    printf "${state[$depth]:-} bogus ): error(%s:%d): %s\n" "$a" "$lineno" "$line"
                    exit 1
                fi
            else
                printf "${state[$depth]:-} bad error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            pop_state struct state branch depth
            check_depth state depth a lineno line
        elif [ "$line" == "} else {" ]; then
            if [ "${struct[$depth]}" != "{}" ]; then
                printf "${state[$depth]:-} bogus else: error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            swap_state_branch state branch depth
            check_depth state depth a lineno line
        elif [[ "$line" =~ ^\',\ *\`$ ]]; then
            if [ "${struct[$depth]}" != "()" ]; then
                printf "${state[$depth]:-} bogus , (else): error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
            swap_state_branch state branch depth
            check_depth state depth a lineno line
        elif [[ "$line" =~ ^gen_bool\([^\)]*\)$ ]]; then
            # Save bool
            bool="${line#gen_bool(}"
            bool="${bool%)}"
            bool_value="$bool"
            bool="${bool%,*}"
            bool_value="${bool_value#*,}"
            while [ "$bool_value" != "${bool_value# }" ]; do
                bool_value="${bool_value# }"
            done
            while [ "$bool_value" != "${bool_value% }" ]; do
                bool_value="${bool_value% }"
            done
            bools["$bool"]="$bool_value"
        elif [[ "$line" =~ ^(gen_tunable|policy_module)\([^\)]*\)$ ]]; then
            :
        elif [[ "$line" =~ ^# ]]; then
            :
        elif [ "${state[$depth]}" == "true" ]; then
            if [[ "$line" =~ ^(attribute_role|attribute|bool|class|roleattribute|role|typealias|typeattribute|type)\  ]]; then
                # definitions skipped
                :
            elif [[ "$line" =~ ^(fs_use_task|fs_use_trans|fs_use_xattr|genfscon|portcon|sid)\  ]]; then
                # maybe could handle these, but they are used only on /kernel/
                :
            elif [[ "$line" =~ ^[a-zA-Z0-9_]+\( ]]; then
                # interface rules
                skip=0
                case "$line" in
                    # interface does not work without having other interface before it
                    "apache_content_alias_template("*) pre="$(sed -r 's/^apache_content_alias_template\( */apache_content_template(/;s/[ ,].*/)/' <<< "$line")" ;;
                    # works only in base module, just skip here
                    "selinux_labeled_boolean("*) skip=1 ;;
                esac
            elif [[ "$line" =~ ^(allow|auditallow|dontaudit|neverallow|allowxperm|auditallowxperm|dontauditxperm|neverallowxperm)\  ]]; then
                # rules
                skip=0
            elif [[ "$line" =~ ^(role_transition|type_transition)\  ]]; then
                # rules
                skip=0
            else
                printf "${state[$depth]:-} unk error(%s:%d): %s\n" "$a" "$lineno" "$line"
                exit 1
            fi
        elif [ "${state[$depth]}" == "false" ]; then
            :
        else
            printf "${state[$depth]:-} unk error(%s:%d): %s\n" "$a" "$lineno" "$line"
            exit 1
        fi

        if (( skip )); then
            if [ -f "$out" ]; then
                changes=1
            fi
            todel+=("$out")
            continue
        fi

        if [ "$out" -nt "$a" ]; then
            continue
        fi

        local requires
        requires="$(gen_require "$line")"
        if [ "$requires" ]; then
            requires="$(printf "require {\n%s\n}\n" "$requires")"
        fi
        if [ "$pre" ]; then
            # handle \n nicely
            pre="$(printf "%s\nx" "$pre")"
            pre="${pre%x}"
        fi
        printf "# source: %s\npolicy_module(%s_%d, 1.0.0)\n%s\n%s%s\n" "$a" "$outbase" "$lineno" "$requires" "$pre" "$line" > "$out".tmp
        if [ ! -f "$out" ] || ! cmp -s "$out".tmp "$out"; then
            mv -- "$out".tmp "$out"
            changes=1
        else
            todel+=("$out".tmp)
        fi
    done < <(sed -r 's/^[[:space:]]*//;s/[[:space:]]*#.*//' "$a")

    if (( changes + ${#old_files[@]} )); then
        # If any of the files change, then we need to be sure there is no leftovers of old files
        find tmp -type f -name "${outbase}_*" -delete
    fi

    if (( ${#todel[@]} )); then
        rm -f -- "${todel[@]}"
    fi

    if (( ${#old_files[@]} )); then
        rm -f -- "${!old_files[@]}"
    fi
}

for a in "$@"; do
    # set | grep -Ev '^BASH_REMATCH=|^_=|^PIPESTATUS=' > vars1
    case "$a" in
        *.if) handle_if "$a" ;;
        *.te) handle_te "$a" ;;
        *.fc) ;;
        *) printf "ERROR(%s): Unknown filetype\n" "$a"; exit 1 ;;
    esac
    # set | grep -Ev '^BASH_REMATCH=|^_=|^PIPESTATUS=' > vars2
    # diff -u vars1 vars2
done

rm -f -- "$D"/tokens.txt "$D"/requires.txt
