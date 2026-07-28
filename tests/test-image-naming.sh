#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load the helper functions without executing the script's argument parsing/build.
source <(sed -n '1,/^# Parse arguments$/p' "${repo_root}/build-zeroday-image.sh")

assert_eq() {
  local expected="$1"
  local actual="$2"
  local description="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' \
      "$description" "$expected" "$actual" >&2
    return 1
  fi
}

timestamp="20260630120102"

assert_eq \
  "wings-vllm-ascend:v0.23.0rc1-a3-${timestamp}" \
  "$(default_target_image \
    "quay.io/ascend/vllm-ascend:v0.23.0rc1" \
    "vllm-ascend" "v0.23.0rc1" "" "a3" "" "$timestamp")" \
  "Ascend release image uses compatibility-list repository naming"

assert_eq \
  "wings-vllm:v0.23.0-cu130-${timestamp}" \
  "$(default_target_image \
    "vllm/vllm-openai:v0.23.0" \
    "vllm" "v0.23.0" "" "cu130" "" "$timestamp")" \
  "vLLM release image uses compatibility-list repository naming"

assert_eq \
  "wings-vllm-ascend:glm5.2-a3-${timestamp}" \
  "$(default_target_image \
    "quay.io/ascend/vllm-ascend:v0.23.0rc1" \
    "vllm-ascend" "v0.23.0rc1" "GLM5.2" "A3" "" "$timestamp")" \
  "model-specific image remains lowercase"

printf 'PASS: image naming tests\n'
