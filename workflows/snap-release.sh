#!/bin/bash
#
# Copyright (C) 2017 Canonical Ltd
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

set -ex -o pipefail
shopt -s inherit_errexit

CI_ID=$GITHUB_RUN_ID
GIT_REPO=https://github.com/$GITHUB_REPOSITORY

# Find the scripts folder
script_name=${BASH_SOURCE[0]##*/}
CICD_SCRIPTS=${BASH_SOURCE[0]%%"$script_name"}./

# shellcheck source=common.sh
. "$CICD_SCRIPTS"/common.sh

# Make sure we release all resources on shutdown
finish()
{
    if [ -n "$BUILD_BRANCH" ]; then
        git push origin :"$BUILD_BRANCH" || true
    fi
}
trap finish EXIT

# Sets git user/email so we can create commits
set_git_identity()
{
    git config user.name "System Enablement CI Bot"
    git config user.email "ce-system-enablement@lists.canonical.com"
}

# Updates changelog using the descriptions of the merge commits
# $1 Snap name
# $2 Version to release
# $3 Previous version
# $4 Name of the changelog file
# $5 Chunk of changes coming from staged packages
update_changelog()
{
    local commits i text range
    local snap=$1
    local ver=$2
    local prev_ver=$3
    local changelog_file=$4
    local pkg_changes=$5
    local changes author full_text

    if [ -n "$prev_ver" ]; then
        range=$prev_ver..HEAD
    else
        range=HEAD
    fi

    commits=$(git rev-list --merges --reverse "$range")
    declare -A changes

    for i in $commits; do
        local body merge_proposal description text

        body=$(git log --format=%B -n1 "$i")
        merge_proposal=$(echo "$body" | grep "^Merge-Proposal:") || true
        author=$(echo "$body" | grep "^Author:") || true
        author="${author#Author: *}"
        if [ -z "$author" ]; then
            # Probably github instead of launchpad
            author=$(git log --format='%an <%ae>' "$i"^!)
            merge_proposal=$(echo "$body" | grep "Merge pull request") || true
        fi
        # 'sed' removes leading blank lines first, then adds indentation
        description=$(echo "$body" | grep -v "^Author:\|^Merge" | \
                        sed '/./,$!d' | sed '3,$s/^/    /') || true
        if [ -z "$description" ]; then
            description="See more information in merge proposal"
        fi
        text=${changes[$author]}
        printf -v text "%s\n  * %s\n    %s" \
               "$text" "$description" "$merge_proposal"
        changes[$author]=$text
    done

    printf -v full_text "%s\n" "$(date --rfc-3339=date --utc) $snap $ver"
    for author in "${!changes[@]}"; do
        printf -v full_text "%s\n  [ %s ]%s\n" \
               "$full_text" "$author" "${changes[$author]}"
    done
    printf -v full_text "%s\n%s" "$full_text" "$pkg_changes"

    if [ ! -f "$changelog_file" ]; then
        touch "$changelog_file"
    fi
    echo "$full_text" | cat - "$changelog_file" > "$changelog_file".tmp
    mv "$changelog_file".tmp "$changelog_file"

    git add "$changelog_file"
    git commit -m "Update $changelog_file for $ver"
}

# Gets manifest from a published snap
# $1: snap name
# $2: channel to download from
# $3: architecture
# $4: output folder
get_old_manifest()
{
    local snap_n=$1
    local channel=$2
    local arch=$3
    local out_d=$4
    local dir track

    dir=$(mktemp -d)
    (
        cd "$dir"
        # We set proxy for snapd as in the future 'snap download' will
        # use snapd instead of downloading on its own. See
        # https://forum.snapcraft.io/t/downloading-snaps-via-snapd/11449
        #sudo snap set system proxy.http="$HTTP_PROXY"
        #sudo snap set system proxy.https="$HTTPS_PROXY"
        if ! UBUNTU_STORE_ARCH="$arch" \
             snap download --channel="$channel" "$snap_n"; then
            # First time we release for this track?
            # Try with "previous" track to get good history
            track=${channel%%/*}
            if [ "$track" -gt 20 ]
            then track=$((track - 2))
            else
                if [ "$snap_n" = network-manager ] || [ "$snap_n" = modem-manager ]
                then track=1.10
                else track=latest
                fi
            fi
            if ! UBUNTU_STORE_ARCH="$arch" \
                 snap download --channel="$track/${channel#*/}" "$snap_n"; then
                # Last try with a different arch
                UBUNTU_STORE_ARCH=amd64 \
                                 snap download --channel="$channel" "$snap_n"
            fi
        fi
        unsquashfs "$snap_n"_*.snap snap/manifest.yaml
    )
    mv "$dir/squashfs-root/snap/manifest.yaml" "$out_d"/manifest-"$arch".yaml
    rm -rf "$dir"
}

# Bumps version in snapcraft
# $1 Version to be set in the snapcraft.yaml file
# $2 Path to the snapcraft.yaml file
set_version()
{
    sed -i -e "s/^version:\ .*/version: $1/g" "$2"
    git add "$2"
    git commit -m "Bump version to $1"
}

# Changes snap version to <next_version>-dev and pushes to released branch
# $1: next version
# $2: released branch
# $3: path to snapcraft.yaml
open_next_version_development()
{
    local _next_version=$1
    local _release_branch=$2
    local _snapcraft_yaml_path=$3

    sed -i -e "s/^version:\ .*/version: ${_next_version}-dev/g" \
        "$_snapcraft_yaml_path"
    git add "$_snapcraft_yaml_path"
    git commit -m "Open development for ${_next_version}-dev"
    git push origin "$_release_branch"
}

# Return changes in the debian packages of which at least a file has been
# included in the snap, for a given snap file.
# $1: path to snap
# $2: channel to get old manifest from (used only if not locally present)
# $3: directory where to store new manifest
# $4: name of variable to store the text output
get_pkg_changes_for_snap()
{
    local snap_p=$1
    local chan=$2
    local unsquash_d=$3
    local out_var=$4
    local manifest_d=manifests
    local manifest_p arch unstage_f snap_n

    arch=${snap_p##*_}
    arch=${arch%.snap}
    # We want this manifest to be stored in the git repo
    manifest_p=$manifest_d/manifest-"$arch".yaml

    if ! [ -f "$manifest_p" ]; then
        mkdir -p $manifest_d
        snap_n=${snap_p##*/}
        snap_n=${snap_n%%_*}
        get_old_manifest "$snap_n" "$chan" "$arch" $manifest_d
    fi

    rm -rf "$unsquash_d"
    unsquashfs -d "$unsquash_d" "$snap_p" snap/manifest.yaml snap/unstage.txt \
               usr/share/doc/

    if [ -f "$unsquash_d"/snap/unstage.txt ]; then
        unstage_f="$unsquash_d"/snap/unstage.txt
    else
        unstage_f=unstage.txt
    fi
    "$CICD_SCRIPTS"/unstage-from-manifest.py "$unstage_f" \
                    "$unsquash_d"/snap/manifest.yaml "$unsquash_d"/manifest.yaml

    # Get changes from deb packages - add a 2 space indentation
    pkg_changes=$("$CICD_SCRIPTS"/changelog-from-manifest.py \
                                 "$manifest_p" \
                                 "$unsquash_d"/manifest.yaml \
                                 "$unsquash_d"/usr/share/doc/ | sed 's/^/  /')
    # Update now the manifest in the repo
    cp "$unsquash_d"/manifest.yaml "$manifest_p"

    eval "$out_var"='$pkg_changes'
}

# Return changes in the debian packages of which at least a file has been
# included in the snap.
# $1: snap name
# $2: channel to get old manifest from (used only if not locally present)
# $3: build directory
# $4: directory where to store new manifest
# $5: name of variable to store the text output
get_pkg_changes()
{
    local snap_n=$1
    local chan=$2
    local build_d=$3
    local out_d=$4
    local out_text_var=$5
    local first=true prev_changes="" snap_p changes

    # We actually expect the changelog to be the same for all archs, at least
    # the staged packages are the same for all archs in all system snaps. So,
    # just compare the output and exit with an error if changelogs differ in the
    # end. That may happen if a package has been updated in the archive for some
    # archs, but we hit a race and for others the package has not been uploaded
    # yet.  Rebuilding should fix things in that case. Or, we might have hit a
    # real difference and we need to investigate why.
    for snap_p in "$build_d"/"$snap_n"_*.snap; do
        get_pkg_changes_for_snap "$snap_p" "$chan" "$out_d" changes

        if [ "$first" = false ]; then
            if [ "$changes" != "$prev_changes" ]; then
                printf "ERROR: different changelogs:%s\nversus\n%s\n" \
                       "$prev_changes" "$changes"
                exit 1
            fi
        fi
        prev_changes=$changes
        first=false
    done

    eval "$out_text_var"='$prev_changes'
}

# $1: release branch
# $2: workspace where we can store temporal files
# $3: git repository
# $4: name of build branch
# $5: next version after the one we will release, to open development for it
main()
{
    local release_branch=$1
    local workspace=$2
    local git_repo=$3
    local build_branch=$4
    local next_version=$5
    local snapcraft_yaml_path snap_name current_version version next_minor
    local changelog_version series track channel previous_version arch
    local build_d new_man_d

    snapcraft_yaml_path=$(get_snapcraft_yaml_path)
    if [ -z "$snapcraft_yaml_path" ]; then
        echo "ERROR: No snapcraft.yaml or snap/snapcraft.yaml file!"
        exit 1
    fi

    snap_name=$(yq .name "$snapcraft_yaml_path")
    current_version=$(yq .version "$snapcraft_yaml_path")
    version=${current_version%%-dev}
    next_minor=$((${version##*-} + 1))
    # Next version can be forced externally to something else
    if [ -z "$next_version" ]
    then next_version=${version%%-*}-$next_minor
    fi
    changelog_version=ChangeLog

    echo "Snap to be released: $snap_name"
    echo "Version to be released: $version"
    echo "New development version: $next_version"

    set_git_identity

    series=$(get_series "$snapcraft_yaml_path")

    track=$(get_track_from_branch "$release_branch")
    channel="$track"/beta

    # latest tag is latest version
    previous_version="$(git describe --abbrev=0 --tags)" || true

    # Checkout a build branch
    git checkout -b "$build_branch"

    # Set release version now so it gets reflected in the built snap
    set_version "$version" "$snapcraft_yaml_path"

    # We build from a temporary branch that we will delete on exit
    git push origin "$build_branch"
    build_d="$workspace"
    build_and_download_snaps "$snap_name" "$git_repo" \
                             "$build_branch" "$series" "$build_d" \
                             "${BUILD_ARCHITECTURES-}" \
                             "${SNAPCRAFT_CHANNEL-}"

    ## Inject changelog and update manifests
    mkdir -p manifests
    new_man_d="$workspace"/new_man
    get_pkg_changes "$snap_name" "$channel" "$build_d" "$new_man_d" pkg_changes

    # Now checkout to the release branch
    git checkout "$release_branch"
    # pkg_changes is set by get_pkg_changes, disable warning
    # shellcheck disable=SC2154
    update_changelog "$snap_name" "$version" "$previous_version" \
                     "$changelog_version" "$pkg_changes"
    # Update manifests in repo
    git add manifests/manifest-*.yaml
    git commit -m "Update manifests to $version"
    # Put back version and create tag now
    set_version "$version" "$snapcraft_yaml_path"

    for snap_p in "$build_d"/"$snap_name"_*.snap; do
        arch="${snap_p##*_}"
        arch="${arch%.snap}"
        modify_files_in_snap "$snap_p" \
                             "$PWD/$changelog_version" \
                             usr/share/doc/"$snap_name"/ChangeLog \
                             manifests/manifest-"$arch".yaml snap/manifest.yaml \
                             "" snap/unstage.txt
    done

    # Run CI tests, using the just built snap
    cp "$build_d"/"$snap_name"_*_amd64.snap .
    spread google:

    # Commit changes to release branch (version in yaml and changelog)
    open_next_version_development "$next_version" "$release_branch" \
                                  "$snapcraft_yaml_path"
    tag=${version}_${release_branch}
    git tag -a -m "$tag" "$tag" HEAD
    git push origin "$tag"
}

if [ $# -ne 2 ]; then
    printf "Wrong number of arguments.\n"
    printf "Usage: %s <release_branch> <workspace_dir>\n" "$0"
    printf "Environment\n"
    printf "   - BUILD_ARCHITECTURES - override build architectures\n"
    printf "   - SNAPCRAFT_CHANNEL   - override snapcraft snap channel\n"
    exit 1
fi
NEXT_VERSION=${NEXT_VERSION:-}
BUILD_BRANCH="$1"_$CI_ID
main "$1" "$2" "$GIT_REPO" "$BUILD_BRANCH" "$NEXT_VERSION"
