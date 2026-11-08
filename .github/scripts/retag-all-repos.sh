#!/bin/bash

set -e

ONLY_REPO=$1

WORKSPACE_PATH="/tmp/regolith-workspace/"
VOULAGE_PATH="$(realpath "$WORKSPACE_PATH")/voulage/"
PACKAGES_PATH="$(realpath "$WORKSPACE_PATH")/packages/"
LOGS_PATH="$(realpath "$WORKSPACE_PATH")/logs/"

if [ ! -d "$WORKSPACE_PATH" ]; then
  mkdir -p "$WORKSPACE_PATH"
fi

if [ ! -d "$PACKAGES_PATH" ]; then
  mkdir -p "$PACKAGES_PATH"
fi

if [ ! -d "$LOGS_PATH" ]; then
  mkdir -p "$LOGS_PATH"
fi

BUILD_OUTPUT="${LOGS_PATH%/}/result-$(date +%Y%m%d%H%M).log"

touch "$BUILD_OUTPUT"

if [ -n "$GITHUB_TOKEN" ]; then
  git config --global "url.https://git:${GITHUB_TOKEN}@github.com/.insteadOf" https://github.com/
fi

clone_repo() {
  local repo_name=$1
  local repo_url=$2
  local repo_ref=$3
  local repo_path=$4

  echo "Cloning $repo_name into $repo_path"

  if [ ! -d "$repo_path" ]; then
    git clone --quiet --branch "$repo_ref" "$repo_url" "$repo_path"
  else
    pushd "$repo_path" >/dev/null || exit 1

    git fetch
    git checkout --quiet "$repo_ref"
    git pull --quiet

    popd >/dev/null || exit 1
  fi
}

process_model() {
  # model_sub_path can be empty, or ends with a slash (e.g. ubuntu/jammy/, debian/testing/)
  local model_sub_path=$1

  local stage_path="unstable/${model_sub_path}"
  local model_file="stage/${stage_path%/}/package-model.json"

  echo "Looking for packages in '${stage_path%/}/package-model.json'"
  echo ""

  while IFS='' read -r package; do
    package_name="$package"

    # only process the provided repo, if any
    if [ -n "$ONLY_REPO" ] && [ "$ONLY_REPO" != "$package_name" ]; then
      continue
    fi

    pacakge_repo=$(jq -r ".packages.\"$package\".source" "$model_file")
    package_ref=$(jq -r ".packages.\"$package\".ref" "$model_file")

    echo "Package found: '${package_name}'"
    clone_repo "$package_name" "$pacakge_repo" "$package_ref" "${PACKAGES_PATH%/}/${package_name}/"

    echo "Using '${package_ref}' branch"
    create_tag_from_history "$package_name" "$package_ref"

    echo "=========="
  done < <(jq -rc 'delpaths([path(.[][]| select(.==null))]) | .packages | keys | .[]' "$model_file")
}

create_tag_from_history() {
  local package_name=$1
  local package_ref=$2

  pushd "${PACKAGES_PATH%/}/${package_name}/" >/dev/null

  # Get all changes happened to debian/changelog and tag
  # them accordingly.
  #
  # Explicitly ignoring the first line, because that will
  # get tagged separatelt by the new prepare-release actions.
  for sha in $(git log --format=format:%H -- debian/changelog | tail -n+2); do
    git checkout "$sha" 2>&1 >/dev/null | tail -1

    release_version=""
    if ! generate_tag_name "$package_name" "$package_ref" release_version; then
      break
    fi

    if [ "$release_version" == "v" ]; then
      echo "error: could not determine the package version, skipping."
      continue
    fi

    if [ "$(git tag --list "${release_version}" | wc -l)" != 0 ] ; then
      echo "error: tag ${release_version} already exists, skipping."
      continue
    fi

    echo "Creating '${release_version}' tag out of $sha"
    echo -e "${package_name}\t${release_version}\t${sha}\t${package_ref}" >> "$BUILD_OUTPUT"

    # Do not annotate tags for historic changes. Annotating will mess up the
    # tag creation time, which was supposed to be in the past.
    git tag "${release_version}"

    echo "Pushing '${release_version}' to upstream repo"
    if ! git push origin "${release_version}"; then
      continue
    fi

    echo "----------"
  done
  echo "" >> "$BUILD_OUTPUT"

  popd >/dev/null
}

generate_tag_name() {
  local package_name=$1
  local package_ref=$2
  declare -n argument=$3

  local short_version=""
  local full_version=""

  short_version=$(dpkg-parsechangelog --show-field Version)
  full_version=$(echo "v${short_version}" | sed 's/:/./g' | sed 's/[\~\^\?\[\*]/-/g')

  local unsupported_ref="false"

  case "$package_ref" in
    # default main/master branches ~ convention is main
    "main"|"master")                              ;;

    # distro/codename specific branches ~ convention is <distro>-<codename>
    "ubuntu-jammy"|"ubuntu/jammy")                full_version+="-ubuntu-jammy" ;;
    "ubuntu-focal"|"ubuntu/focal")                full_version+="-ubuntu-focal" ;;
    "debian-bullseye")                            full_version+="-debian-bullseye" ;;
    "debian-testing"|"debian/testing")            full_version+="-debian-testing" ;;
    "debian-bookworm"|"debian-bookworm-compat")   full_version+="-debian-bookworm" ;;

    # library/platform specific branches ~ convention is <library-name>-<version>
    "regolith/1%43.0-1")                          full_version+="-gnome-43" ;;
    "regolith/46")                                full_version+="-gnome-46" ;;

    # unknown package ref
    *) unsupported_ref="true" ;;
  esac

  local separator=":::"
  local unsupported_combo="false"

  # Miscellaneous edge cases
  case "${package_name}${separator}${package_ref}" in
    "fonts-nerd-fonts:::debian")                  ;;
    "i3status-rs:::ubuntu/v0.22.0")               full_version+="-ubuntu-jammy" ;;
    "i3status-rs:::ubuntu/v0.32.1")               ;;
    "i3status-rs:::ubuntu/v0.40.0")               ;;
    "picom:::debian-v9")                          ;;
    "regolith-rofi-config:::i3cp")                ;;
    "sway-regolith:::packaging/v1.7-regolith")    full_version+="-ubuntu-jammy" ;;
    "sway-regolith:::packaging/v1.8-regolith")    full_version+="-debian-testing" ;;
    "sway-regolith:::packaging/v1.9-regolith")    ;;
    "whitesur-gtk-theme:::debian")                ;;

    # This package is exceptional. It is not built from a regolith repo and cannot push tags.
    #
    # Deprecated.
    "xcb-util:::applied/ubuntu/groovy")           full_version="" ;;

    # unknown package name and ref combo
    *) unsupported_combo="true" ;;
  esac

  if [ "$unsupported_ref" == "true" ] && [ "$unsupported_combo" == "true" ]; then
    echo "error: '${package_ref}' is not a valid ref to release from"
    return 1
  fi

  # shellcheck disable=SC2034
  argument="$full_version"
}

main() {
  clone_repo "Voulage" "https://github.com/regolith-linux/voulage.git" "main" "$VOULAGE_PATH"

  pushd "${VOULAGE_PATH}" >/dev/null

  # process package-models at stage root level
  process_model ""

  # process package-models at distro/codename level
  for dir in stage/unstable/*/*/; do
    distro=$(echo "$dir" | cut -d/ -f3)
    codename=$(echo "$dir" | cut -d/ -f4)

    process_model "$distro/$codename/"
  done

  popd >/dev/null
}

main
