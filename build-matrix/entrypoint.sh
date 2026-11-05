#!/usr/bin/env bash

set -e

if [ "$MATRIX_TYPE" != "package" ] && [ "$MATRIX_TYPE" != "platform" ]; then
  echo "Error: unknown matrix type ($MATRIX_TYPE)"
  exit 1
fi

if [ "$MATRIX_TYPE" == "package" ]; then
  if [ -z "$PACKAGE_NAME" ]; then
    echo "Error: package name is missing"
    exit 1
  fi
  if [ -z "$PACKAGE_REF" ]; then
    echo "Error: package ref is missing"
    exit 1
  fi
fi

if [ -z "$VOULAGE_PATH" ]; then
  echo "Error: VOULAGE_PATH is empty"
  exit 1
fi
if [ ! -d "$VOULAGE_PATH" ]; then
  echo "Error: voulage repo not found"
  exit 1
fi

if [ ! -d "$VOULAGE_PATH/stage" ]; then
  echo "Error: $VOULAGE_PATH/stage doesn't exist"
  exit 1
fi
if [ ! -d "$VOULAGE_PATH/stage/$BUILD_STAGE" ]; then
  echo "Error: $VOULAGE_PATH/stage/$BUILD_STAGE doesn't exist"
  exit 1
fi

includes=()
skip_reason=""

# The package's entry in the effective model of one target, as JSON, or
# nothing if the effective model doesn't list the package.
#
# The effective model is merged the way voulage merges it for a build
# (merge_models in voulage's .github/scripts/main.sh): the root, stage,
# distro, codename and architecture models, each optional, merged in that
# order with jq's recursive `*`. So a level inherits what it doesn't
# override, a source-only override keeps the inherited ref, and a lower
# level can enable a package that a higher level set to null.
effective_package() {
  local distro="$1"
  local codename="$2"
  local arch="$3"
  local models=()
  local model

  for model in \
    "stage/package-model.json" \
    "stage/$BUILD_STAGE/package-model.json" \
    "stage/$BUILD_STAGE/$distro/package-model.json" \
    "stage/$BUILD_STAGE/$distro/$codename/package-model.json" \
    "stage/$BUILD_STAGE/$distro/$codename/$arch/package-model.json"; do
    if [ -f "$model" ]; then
      models+=("$model")
    fi
  done

  if [ "${#models[@]}" -eq 0 ]; then
    return
  fi

  jq -s -c --arg name "$PACKAGE_NAME" '
    reduce .[] as $model ({}; . * $model)
    | (.packages // {})
    | if has($name) then .[$name] else empty end
  ' "${models[@]}"
}

# Whether the package is built for one target at the requested ref. Sets
# skip_reason when it isn't.
builds_package() {
  local package
  local ref

  package=$(effective_package "$1" "$2" "$3")
  if [ -z "$package" ]; then
    skip_reason="Skipped (package is not in the model)"
    return 1
  fi
  if [ "$package" == "null" ]; then
    skip_reason="Skipped (model is explicitly set to null)"
    return 1
  fi

  ref=$(echo "$package" | jq -r '.ref')
  if [ "$ref" != "$PACKAGE_REF" ]; then
    skip_reason="Ignored (request ref: $PACKAGE_REF, model ref: $ref)"
    return 1
  fi

  return 0
}

main() {
  echo "Supported distro/codename:"

  pushd "$VOULAGE_PATH" >/dev/null || exit 1

  for dir in stage/"$BUILD_STAGE"/*/*/; do
    if [ ! -d "$dir" ]; then
      continue
    fi

    distro=$(echo "$dir" | cut -d/ -f3)
    codename=$(echo "$dir" | cut -d/ -f4)

    for arch in $BUILD_ARCH; do
      # Skip this target when its effective model sets the package to
      # null, doesn't list it, or builds another ref.
      if [ "$MATRIX_TYPE" == "package" ]; then
        if ! builds_package "$distro" "$codename" "$arch"; then
          echo "  - $distro/$codename/$arch: $skip_reason"
          continue
        fi
      fi

      echo "  - $distro/$codename/$arch: OK"
      includes+=("$(jq -n -c --arg distro "$distro" --arg codename "$codename" --arg arch "$arch" '$ARGS.named')")
    done
  done

  popd >/dev/null || exit 1
}

main

# shellcheck disable=SC2086
echo "includes=$(jq -n -c "[$(printf '%s\n' "${includes[@]}" | paste -sd,)]" '$ARGS.named')" >> $GITHUB_OUTPUT

# shellcheck disable=SC2086
echo "runners=$(jq -n -c "$(jq -n -c --arg amd64 "ubuntu-24.04" --arg arm64 "ubuntu-24.04-arm" '$ARGS.named')" '$ARGS.named')" >> $GITHUB_OUTPUT
