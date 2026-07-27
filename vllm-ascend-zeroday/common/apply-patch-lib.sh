#!/usr/bin/env bash

apply_patch() {
  local repo_dir="$1"
  local patch_file="$2"

  if ! command -v git >/dev/null 2>&1; then
    echo "git is required to apply patches but is not available" >&2
    exit 1
  fi
  [[ -d "$repo_dir" ]] || {
    echo "Repository not found: $repo_dir" >&2
    exit 1
  }
  [[ -f "$patch_file" ]] || {
    echo "Patch file not found: $patch_file" >&2
    exit 1
  }

  echo "checking $(basename "$patch_file")"
  git -C "$repo_dir" apply --check "$patch_file" || {
    echo "Patch check failed: $patch_file" >&2
    exit 1
  }

  echo "applying $(basename "$patch_file")"
  git -C "$repo_dir" apply "$patch_file"
}
