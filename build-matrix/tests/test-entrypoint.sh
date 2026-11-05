#!/usr/bin/env bash
#
# Tests for build-matrix/entrypoint.sh.
#
# Each case writes a fixture voulage stage tree and checks which
# distro/codename/arch targets the matrix includes. voulage merges the
# root, stage, distro, codename and architecture models for a build
# (merge_models in its .github/scripts/main.sh); the matrix must decide
# each target from that same effective model.
#
# Requires: bash, jq
#
# Usage: build-matrix/tests/test-entrypoint.sh

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENTRYPOINT="${SCRIPT_DIR}/../entrypoint.sh"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

FAILED=0
VOULAGE=""

pass() {
  echo -e "\033[0;32mPASS\033[0m: $1"
}

fail() {
  echo -e "\033[0;31mFAIL\033[0m: $1"
  FAILED=1
}

# new_voulage <name> <codename-dir>...: an empty stage/unstable tree with
# the given distro/codename directories and no models.
new_voulage() {
  VOULAGE="$WORK_DIR/$1"
  shift
  mkdir -p "$VOULAGE/stage/unstable"
  echo '{"description": {"title": "root"}}' > "$VOULAGE/stage/package-model.json"
  local dir
  for dir in "$@"; do
    mkdir -p "$VOULAGE/stage/unstable/$dir"
  done
}

# model <path below stage/> <packages JSON>
model() {
  mkdir -p "$(dirname "$VOULAGE/stage/$1")"
  echo "{\"packages\": $2}" > "$VOULAGE/stage/$1"
}

# targets <type> [<ref>]: the included targets, one "distro/codename/arch"
# per line, sorted.
targets() {
  local output="$WORK_DIR/output"
  : > "$output"
  VOULAGE_PATH="$VOULAGE" MATRIX_TYPE="$1" PACKAGE_NAME=demo PACKAGE_REF="${2:-main}" \
    BUILD_STAGE=unstable BUILD_ARCH="amd64 arm64" GITHUB_OUTPUT="$output" \
    bash "$ENTRYPOINT" > "$WORK_DIR/log"
  sed -n 's/^includes=//p' "$output" | jq -r '.[] | "\(.distro)/\(.codename)/\(.arch)"' | sort
}

# expect <description> <expected targets, space separated> [<type> [<ref>]]
expect() {
  local got
  got=$(targets "${3:-package}" "$4" | paste -sd' ')
  if [ "$got" == "$2" ]; then
    pass "$1"
  else
    fail "$1: expected '$2', got '$got'"
    sed 's/^/    /' "$WORK_DIR/log"
  fi
}

new_voulage plain ubuntu/noble ubuntu/resolute
model unstable/package-model.json '{"demo": {"ref": "main", "source": "https://example.com/demo.git"}}'
model unstable/ubuntu/noble/package-model.json '{}'
model unstable/ubuntu/resolute/package-model.json '{}'
expect "a package in the stage model is built for every target" \
  "ubuntu/noble/amd64 ubuntu/noble/arm64 ubuntu/resolute/amd64 ubuntu/resolute/arm64"
expect "a package is not built for a ref no model selects" "" package other

new_voulage no-codename-model ubuntu/noble
model unstable/package-model.json '{"demo": {"ref": "main"}}'
expect "a codename without its own model inherits the stage model" \
  "ubuntu/noble/amd64 ubuntu/noble/arm64"

new_voulage distro-null ubuntu/noble debian/trixie
model unstable/package-model.json '{"demo": {"ref": "main"}}'
model unstable/ubuntu/package-model.json '{"demo": null}'
model unstable/ubuntu/noble/package-model.json '{}'
model unstable/debian/trixie/package-model.json '{}'
expect "a distro model that sets the package to null disables it for that distro" \
  "debian/trixie/amd64 debian/trixie/arm64"

new_voulage arch-null ubuntu/noble
model unstable/package-model.json '{"demo": {"ref": "main"}}'
model unstable/ubuntu/noble/package-model.json '{}'
model unstable/ubuntu/noble/arm64/package-model.json '{"demo": null}'
expect "an architecture model that sets the package to null disables it for that architecture" \
  "ubuntu/noble/amd64"

new_voulage arch-ref ubuntu/noble
model unstable/package-model.json '{"demo": {"ref": "main"}}'
model unstable/ubuntu/noble/amd64/package-model.json '{"demo": {"ref": "other"}}'
expect "an architecture model's ref applies to that architecture only" \
  "ubuntu/noble/arm64"
expect "an architecture model's ref applies to that architecture only (its ref)" \
  "ubuntu/noble/amd64" package other

new_voulage source-only ubuntu/noble
model unstable/package-model.json '{"demo": {"ref": "main", "source": "https://example.com/old.git"}}'
model unstable/ubuntu/noble/package-model.json '{"demo": {"source": "https://example.com/new.git"}}'
expect "a codename model that overrides only the source keeps the inherited ref" \
  "ubuntu/noble/amd64 ubuntu/noble/arm64"

new_voulage reenable ubuntu/noble ubuntu/resolute
model unstable/package-model.json '{"demo": null}'
model unstable/ubuntu/noble/package-model.json '{"demo": {"ref": "main", "source": "https://example.com/demo.git"}}'
model unstable/ubuntu/resolute/package-model.json '{}'
expect "a codename model can enable a package the stage model sets to null" \
  "ubuntu/noble/amd64 ubuntu/noble/arm64"

new_voulage codename-override ubuntu/noble ubuntu/resolute
model unstable/package-model.json '{"demo": {"ref": "main"}}'
model unstable/ubuntu/noble/package-model.json '{"demo": null}'
model unstable/ubuntu/resolute/package-model.json '{"demo": {"ref": "packaging/v2"}}'
expect "codename models that disable the package or select another ref" ""
expect "codename models that disable the package or select another ref (its ref)" \
  "ubuntu/resolute/amd64 ubuntu/resolute/arm64" package packaging/v2

new_voulage root-model ubuntu/noble
echo '{"packages": {"demo": {"ref": "main"}}}' > "$VOULAGE/stage/package-model.json"
expect "the root model is inherited too" "ubuntu/noble/amd64 ubuntu/noble/arm64"

new_voulage absent ubuntu/noble
model unstable/package-model.json '{"other": {"ref": "main"}}'
model unstable/ubuntu/noble/package-model.json '{}'
expect "a package no model lists is not built" ""
expect "the platform matrix has every target" "ubuntu/noble/amd64 ubuntu/noble/arm64" platform

exit $FAILED
