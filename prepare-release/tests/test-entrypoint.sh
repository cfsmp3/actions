#!/usr/bin/env bash
#
# Tests for prepare-release/entrypoint.sh.
#
# Each case builds a throwaway package repository with a debian/changelog,
# pushes it to a bare "remote", and checks it out the way actions/checkout
# does by default (fetch-depth 1, fetch-tags false), so the checkout has no
# tags. It then runs entrypoint.sh against a fixture voulage tree.
#
# Requires: bash, git, jq, dpkg-parsechangelog (dpkg-dev)
#
# Usage: prepare-release/tests/test-entrypoint.sh

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENTRYPOINT="${SCRIPT_DIR}/../entrypoint.sh"

# keep the user's git configuration out of the fixtures
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

FAILED=0
CASE_DIR=""
REMOTE=""

pass() {
  echo -e "\033[0;32mPASS\033[0m: $1"
}

fail() {
  echo -e "\033[0;31mFAIL\033[0m: $1"
  FAILED=1
}

# write_voulage <dir> <package> <unstable-ref>
write_voulage() {
  local dir=$1
  local package=$2
  local ref=$3

  mkdir -p "$dir/stage/unstable/ubuntu/resolute" "$dir/stage/testing/ubuntu/resolute"

  echo '{"packages": {}}' > "$dir/stage/unstable/package-model.json"
  echo '{"packages": {}}' > "$dir/stage/testing/package-model.json"

  jq -n --arg p "$package" --arg r "$ref" \
    '{packages: {($p): {ref: $r, source: "https://example.com/old.git"}}}' \
    > "$dir/stage/unstable/ubuntu/resolute/package-model.json"
  jq -n --arg p "$package" \
    '{packages: {($p): {ref: "v0.0.1-1", source: "https://example.com/old.git"}}}' \
    > "$dir/stage/testing/ubuntu/resolute/package-model.json"
}

# setup_case <name> <package> <ref> <changelog-version> [<tag>...]
#
# A tag argument "annotated:<name>" creates an annotated tag, any other
# argument a lightweight one, both on the released commit.
setup_case() {
  local name=$1
  local package=$2
  local ref=$3
  local version=$4
  shift 4

  CASE_DIR="$WORK_DIR/$name"
  REMOTE="$CASE_DIR/remote.git"

  mkdir -p "$CASE_DIR/src/debian"
  cat > "$CASE_DIR/src/debian/changelog" <<EOF
${package} (${version}) resolute; urgency=medium

  * Test release.

 -- Test <test@example.com>  Mon, 19 Oct 2026 12:00:00 +0000
EOF

  git -C "$CASE_DIR/src" init -q -b "$ref"
  git -C "$CASE_DIR/src" add debian/changelog
  git -C "$CASE_DIR/src" commit -q -m "release ${version}"

  local tag
  for tag in "$@"; do
    case "$tag" in
      annotated:*) git -C "$CASE_DIR/src" tag -a -m "${tag#annotated:}" "${tag#annotated:}" ;;
      *)           git -C "$CASE_DIR/src" tag "$tag" ;;
    esac
  done

  git init -q --bare "$REMOTE"
  git -C "$CASE_DIR/src" push -q "file://$REMOTE" "refs/heads/*:refs/heads/*" "refs/tags/*:refs/tags/*"

  # the CI checkout: actions/checkout@v4 defaults (fetch-depth 1, fetch-tags false)
  git clone -q --depth=1 --no-tags --branch "$ref" "file://$REMOTE" "$CASE_DIR/pkg"

  write_voulage "$CASE_DIR/voulage" "$package" "$ref"
  cp -r "$CASE_DIR/voulage" "$CASE_DIR/voulage.orig"
}

# run_entrypoint <package> <ref> [<package-repo>]
run_entrypoint() {
  local package=$1
  local ref=$2
  local repo=${3:-"file://$REMOTE"}

  set +e
  (
    cd "$CASE_DIR/pkg" &&
      GITHUB_OUTPUT="$CASE_DIR/github_output" \
      VOULAGE_PATH="$CASE_DIR/voulage" \
      PACKAGE_NAME="$package" \
      PACKAGE_REPO="$repo" \
      PACKAGE_REF="$ref" \
      bash "$ENTRYPOINT"
  ) > "$CASE_DIR/output" 2>&1
  echo $? > "$CASE_DIR/rc"
  set -e
}

output_has() {
  grep -qF -- "$1" "$CASE_DIR/output"
}

github_output_has() {
  grep -qxF -- "$1" "$CASE_DIR/github_output" 2>/dev/null
}

voulage_unchanged() {
  diff -r "$CASE_DIR/voulage.orig" "$CASE_DIR/voulage" >/dev/null
}

testing_ref() {
  jq -r --arg p "$1" '.packages[$p].ref' "$CASE_DIR/voulage/stage/testing/ubuntu/resolute/package-model.json"
}

show_output() {
  sed 's/^/    | /' "$CASE_DIR/output"
}

# expect_release_exists <case> <package> <ref> <version> <tag>...
expect_release_exists() {
  local name=$1
  local package=$2
  local ref=$3
  local version=$4
  local release=$5
  shift 5

  setup_case "$name" "$package" "$ref" "$version" "$@"

  if [ -n "$(git -C "$CASE_DIR/pkg" tag --list)" ]; then
    fail "$name: the checkout should have no tags"
    return
  fi

  run_entrypoint "$package" "$ref"

  if [ "$(cat "$CASE_DIR/rc")" == 0 ] &&
    output_has "Release exists!" &&
    github_output_has "release-exists=true" &&
    github_output_has "release-version=${release}" &&
    voulage_unchanged; then
    pass "$name: '${release}' already exists, voulage untouched"
  else
    fail "$name: expected 'Release exists!' and no voulage change"
    show_output
    diff -ru "$CASE_DIR/voulage.orig" "$CASE_DIR/voulage" | sed 's/^/    | /' || true
  fi
}

# expect_new_release <case> <package> <ref> <version> <release> [<tag>...]
expect_new_release() {
  local name=$1
  local package=$2
  local ref=$3
  local version=$4
  local release=$5
  shift 5

  setup_case "$name" "$package" "$ref" "$version" "$@"
  run_entrypoint "$package" "$ref"

  if [ "$(cat "$CASE_DIR/rc")" == 0 ] &&
    output_has "Release not found!" &&
    github_output_has "release-exists=false" &&
    github_output_has "release-version=${release}" &&
    [ "$(testing_ref "$package")" == "$release" ]; then
    pass "$name: new release '${release}', testing model updated"
  else
    fail "$name: expected a new release '${release}' and an updated testing model"
    show_output
  fi
}

echo "Release guard:"

expect_release_exists "existing-lightweight-tag" "fixture-pkg" "main" "1.2.3-1" \
  "v1.2.3-1" \
  "v1.2.3-1"

expect_release_exists "existing-annotated-tag" "fixture-pkg" "main" "1.2.3-1" \
  "v1.2.3-1" \
  "annotated:v1.2.3-1"

expect_new_release "new-version" "fixture-pkg" "main" "1.2.4-1" \
  "v1.2.4-1" \
  "v1.2.3-1" "v1.2.4-1-gnome-50" "v1.2.4-10"

# the tag cannot be looked up: fail instead of rewriting the models
setup_case "unreachable-remote" "fixture-pkg" "main" "1.2.3-1"
run_entrypoint "fixture-pkg" "main" "file://$CASE_DIR/does-not-exist.git"
if [ "$(cat "$CASE_DIR/rc")" != 0 ] && voulage_unchanged; then
  pass "unreachable-remote: fails, voulage untouched"
else
  fail "unreachable-remote: expected a failure and no voulage change"
  show_output
fi

echo ""
echo "Tag names:"

expect_new_release "main" "fixture-pkg" "main" "1:2.0~rc1-1" \
  "v1.2.0-rc1-1"

expect_new_release "regolith-49" "regolith-control-center" "regolith/49" "1.49.0-4" \
  "v1.49.0-4-gnome-49"

expect_new_release "regolith-50" "regolith-control-center" "regolith/50" "1.50.4-1" \
  "v1.50.4-1-gnome-50"

expect_new_release "regolith-51" "regolith-control-center" "regolith/51" "1.51.0-1" \
  "v1.51.0-1-gnome-51"

expect_new_release "sway-v1.11" "sway-regolith" "packaging/v1.11-regolith" "1.11-2" \
  "v1.11-2"

expect_new_release "i3status-rs-v0.40" "i3status-rs" "ubuntu/v0.40.0" "0.40.0-1" \
  "v0.40.0-1"

# a ref without a rule is refused before anything else happens
setup_case "unknown-ref" "fixture-pkg" "regolith/99" "1.99.0-1"
run_entrypoint "fixture-pkg" "regolith/99"
if [ "$(cat "$CASE_DIR/rc")" != 0 ] &&
  output_has "'regolith/99' is not a valid ref to release from." &&
  voulage_unchanged; then
  pass "unknown-ref: refused, voulage untouched"
else
  fail "unknown-ref: expected 'is not a valid ref to release from.'"
  show_output
fi

if [ "$FAILED" != 0 ]; then
  echo -e "\033[0;31mSome tests failed.\033[0m"
  exit 1
fi

echo -e "\033[0;32mAll tests passed.\033[0m"
