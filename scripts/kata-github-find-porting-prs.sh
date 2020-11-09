#!/bin/bash
#---------------------------------------------------------------------

script_name=${0##*/}

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

[ -n "${DEBUG:-}" ] && set -o xtrace

[ -e ~/bin/libutil.sh ] && source ~/bin/libutil.sh

kata_org="kata-containers"
kata_2x_repo="kata-containers"
kata_org_url="https://github.com/${kata_org}"

# Kata 2.x repo
latest_kata_repo="${kata_org_url}/${kata_2x_repo}"

needs_backport_label="needs-backport"
needs_forward_port_label="needs-forward-port"
backport_label="backport"
forward_port_label="forward-port"

porting_labels=()
porting_labels_regex=""

# See: https://github.com/kata-containers/documentation/blob/master/Stable-Branch-Strategy.md#branch-management
maintained_stable_branches=2

get_repo_url()
{
    git config --get remote.origin.url
}

setup()
{
	local cmd

	for cmd in git hub "hub-query.sh" jq
	do
		command -v "$cmd" &>/dev/null || \
			die "need command: $cmd"
	done

    get_repo_url &>/dev/null || die "not a git checkout"

    local label
    for label in \
        "$needs_backport_label" \
        "$needs_forward_port_label" \
        "$backport_label" \
        "$forward_port_label"
    do
        porting_labels+=("$label")
    done

    porting_labels_regex=$(echo "${porting_labels[@]}"|tr ' ' '|')
    porting_labels_regex="(${porting_labels_regex})"
}

# FIXME:
usage()
{
    cat <<EOT
Usage: $script_name [options]

Description: FIXME.

Options:

 -h       : Show this help statement.

Notes:

FIXME

Examples:

FIXME

EOT
}

get_repo_slug()
{
    local repo_url=$(get_repo_url || true)

    [ -z "$repo_url" ] && die "cannot determine local git repo URL"

    echo "$repo_url" | awk -F\/ '{print $4, $5}' | tr ' ' '/'
}

# Return the Kata 2.x repo URL if the specified PR is
# a Kata 2.x PR, else "".
is_kata_2x_pr()
{
    local pr_url="${1:-}"
    [ -z "$pr_url" ] && die "need PR URL"

    echo "$pr_url" | grep -q "^${latest_kata_repo}" && \
        echo "$latest_kata_repo" && return 0 || true
}

# Return the Kata 2.x org URL if the specified PR is
# a Kata PR, else "".
is_kata_pr()
{
    local pr_url="${1:-}"
    [ -z "$pr_url" ] && die "need PR URL"

    echo "$pr_url" | grep -q "^${kata_org_url}" && \
        echo "$kata_org_url" && return 0 || true
}

# Returns a list of sorted stable branches (newest last)
get_stable_branches()
{
    local stable_prefix="stable-"

    git branch -r |\
        grep "origin/${stable_prefix}[0-9]*\.[0-9][0-9]*$" |\
        tr -d ' ' |\
        awk 'BEGIN{FS="-"} {print $2 | "sort -t. -k1,1n -k2,2n" }' |\
        sed "s/^/${stable_prefix}/g" || true
}

get_current_stable_branches()
{
    get_stable_branches | tail -n ${maintained_stable_branches}
}

# Convert a human-readable HTML URL to its API URL equivalent.
#
# Example:
#
# Input HTML URL:
#
#     https://github.com/${org}/${repo}/issues/${issue}
#
# Output API URL:
#
#     https://api.github.com/repos/${org}/${repo}/issues/${issue}
#
github_html_url_to_api_url()
{
    local html_url="${1:-}"
    [ -z "$html_url" ] && die "need PR HTML URL"

    echo "$html_url" |\
        sed \
        -e 's!github.com!api.github.com/repos!g' \
         -e 's!/pull/!/pulls/!g'
}

get_pr_port_labels()
{
    local pr_url="${1:-}"
    [ -z "$pr_url" ] && die "need PR URL"

    local api_url=$(github_html_url_to_api_url "$pr_url")

    hub api "$api_url" |\
        jq -S '.labels[].name' |\
        sed -e 's/^"//g' -e 's/"$//g' |\
        egrep "$porting_labels_regex" || true
}

# Returns PR porting URL if PR is a port, else "".
get_pr_port_urls()
{
    local pr="${1:-}"
    local pr_url="${2:-}"
    local direction="${3:-}"

    [ -z "$pr" ] && die "need PR"

    case "$direction" in
        back|forward) ;;
        *) die "invalid porting direction: '$direction'"
    esac

    local regex="^${direction}[ -]*port PR: *[^ ][^ ]*"

    local comment

    # PR comments are treated as issues by GitHub...
    comment=$(hub api "/repos/{owner}/{repo}/issues/${pr}/comments" |\
        jq -r '.[].body' |\
        egrep -i "${regex}" |\
        cut -d: -f2- |\
        sed -e 's/^ *//g' -e 's/\.$//g' || true)

    [ -n "$comment" ] && echo "$comment" && return 0

    # ... but the original PR description isn't considered a comment, so check
    # that too!
    comments=$(hub api "/repos/{owner}/{repo}/pulls/${pr}" |\
        jq -r '.body' |\
        egrep -i "${regex}" |\
        cut -d: -f2- |\
        sed -e 's/^ *//g' -e 's/\.$//g' || true)

    [ -n "$comment" ] && echo "$comment" && return 0

    # However, *review* comments a separate entity too!
    comment=$(hub api "/repos/{owner}/{repo}/pulls/${pr}/comments" |\
        jq -r '.[].body' |\
        egrep -i "${regex}" |\
        cut -d: -f2- |\
        sed -e 's/^ *//g' -e 's/\.$//g' || true)

    echo "$comment"
}

check_port_pr()
{
    local pr_url="${1:-}"
    local parent_pr_url="${2:-}"
    local direction="${3:-}"

    [ -z "$pr_url" ] && die "need PR URL"
    [ -z "$parent_pr_url" ] && die "need parent PR URL"
    [ -z "$direction" ] && die "need porting direction"

    local kata_pr=$(is_kata_pr "$pr_url")
    [ -z "$kata_pr" ] && die "PR $pr_url is not a Kata PR"

    case "$direction" in
        back|forward) ;;
        *) die "invalid porting direction: '$direction'"
    esac

    local labels=$(get_pr_port_labels "$pr_url")

    [ -z "$labels" ] \
        && warn "Porting PR $pr_url missing $direction port label" \
        || true

    label_count=$(echo "$labels"|wc -l)

    local msg=$(printf "PR %s has too many port labels: '%s'" \
        "$pr" \
        $(echo "$labels"|tr '\n' ','))

    [ $label_count -gt 1 ] && die "$msg" || true

    case "$labels" in
        "$backport_label") ;;
        "$forward_port_label") ;;
    esac
}

get_destination_branch()
{
    local pr_url="${1:-}"
    [ -z "$pr_url" ] && die "need PR URL"

    local api_url=$(github_html_url_to_api_url "$pr_url")

    hub api "$api_url" | jq -r '.base.ref' || true
}

check_ports()
{
    local pr="${1:-}"
    local pr_url="${2:-}"
    local direction="${3:-}"

    [ -z "$pr" ] && die "need PR"
    [ -z "$pr_url" ] && die "need PR URL"
    [ -z "$direction" ] && die "need porting direction"

    case "$direction" in
        back|forward) ;;
        *) die "invalid porting direction: '$direction'"
    esac

    info "PR $pr labelled as needing $direction port"

    local kata_2x_pr=$(is_kata_2x_pr "$pr_url")
    local kata_1x_pr=""

    [ -z "$kata_2x_pr" ] && kata_1x_pr="true"

    [ "$direction" = "forward" ] && [ -n "$kata_2x_pr" ] && \
        die "No forward ports possible for PR $pr"

    local pr_details=$(hub pr show -f "%S;%t" "$pr")
    local pr_state=$(echo "$pr_details"|cut -d';' -f1)
    local pr_title=$(echo "$pr_details"|cut -d';' -f2-)

    local port_urls=$(get_pr_port_urls "$pr" "$pr_url" "$direction")

    local port_url

    if [ -z "$port_urls" ]
    then
        local fp="info"

        local summary="pending"

        # If the parent PR is closed, we would expect child PRs
        # to have been opened by now.
        [ "$pr_state" = "closed" ] && fp="warn" && summary="overdue"

        local msg=$(printf "PR %s ('%s', %s): No %s porting URLs found (%s)\n" \
            "$pr" \
            "$pr_title" \
            "$pr_url" \
            "$direction" \
            "$summary")

        $fp "$msg"
    fi

    local destination_branches=()

    for port_url in $port_urls
    do
        local destination=$(get_destination_branch "$port_url")
        [ -z "$destination" ] && die "cannot determine destination for PR $port_url"
        destination_branches+=("$destination")

        check_port_pr "$port_url" "$pr_url" "$direction"
    done

    if [ -n "$kata_1x_pr" ] && [ "$direction" = back ]
    then
        # Kata 1.x PRs should have stable backports
        local current_stable_branches=$(get_current_stable_branches || true)
        [ -z "$current_stable_branches" ] \
            && die "cannot determine current stable branches"

        local current_stable_branch

        for current_stable_branch in $(echo "$current_stable_branches")
        do
            local found="false"

            local dest_branch
            for dest_branch in "${destination_branches[@]}"
            do
                [ "$dest_branch" = "$current_stable_branch" ] \
                    && found="true"
            done

            [ "$found" = "false" ] && \
                warn "PR $pr missing backport for current stable branch $current_stable_branch"
            done
    fi

    # All checks passed

    for port_url in $port_urls
    do
        printf "PR %s (%s): Found %s port PR URL: '%s'\n" \
            "$pr" \
            "$pr_url" \
            "$direction" \
            "$port_url"
    done
}

find_pr_ports()
{
    local pr="${1:-}"
    [ -z "$pr" ] && die "need PR number"

    local pr_details=$(hub pr show -f "%U;%L" "$pr" || true)
    [ -z "$pr_details" ] && die "cannot determine details for PR $pr"

    local pr_url=$(echo "$pr_details"|cut -d';' -f1)
    local pr_labels=$(echo "$pr_details"|cut -d';' -f2)

    [ -z "$pr_labels" ] && die "PR $pr is unlabelled"

    pr_labels=$(echo "$pr_labels"|tr ',' '\n'|sed 's/^ *//g'|sort)

    local label
    echo "$pr_labels"|while read label
    do
        case "$label" in
            "$needs_backport_label") check_ports "$pr" "$pr_url" "back" ;;
            "$needs_forward_port_label") check_ports "$pr" "$pr_url" "forward" ;;
        esac
    done
}

find_all_porting_prs()
{
    local repo=$(get_repo_slug)

    local label
    local -A parent_porting_prs=()

    local query_prefix="is:pr repo:${repo}"
    local pr

    # Find all PRs in the current repo labelled as needing ports
    for label in "${needs_backport_label}" "${needs_forward_port_label}"
    do
        local query="${query_prefix} label:${label}"

        local prs=$(hub-query.sh "$query" |\
            jq -r '.items[].number' |\
            tr ' ' '\n' || true)

        for pr in $(echo "$prs")
        do
            parent_porting_prs[$pr]=1
        done
    done

    local sorted_prs=$(echo ${!parent_porting_prs[@]} | tr ' ' '\n'|sort -n)

    for pr in $(echo "$sorted_prs")
    do
        find_pr_ports "$pr"
    done
}

handle_args()
{
    local pr="${1:-}"

    if [ -n "$pr" ]
    then
        find_pr_ports "$pr"
    else
        find_all_porting_prs
    fi
}

main()
{
    setup

    handle_args "$@"
}

main "$@"
