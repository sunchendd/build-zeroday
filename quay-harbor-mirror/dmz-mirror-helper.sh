#!/usr/bin/env bash
# dmz-mirror-helper.sh — runs ON the DMZ (aarch64, has internet).
# Driven over SSH by the orchestrator on 16.9. Two jobs:
#   discover <kind> <param>  -> print ALL tags, one per line (filtering is done on 16.9)
#                              kind=quay   : param is the quay repo, e.g. ascend/vllm-ascend
#                              kind=github : param is the github repo, e.g. vllm-project/vllm (release tags)
#   pull <srcref> <tag> <arch> <platarch> <outdir>
#                              -> docker pull --platform, retag, save .tar, print its path
#   notify <webhook> <text...> -> POST a text message to the Feishu webhook (16.9 is offline)
#                                      -> docker pull --platform, retag, save .tar, print its path
# kind is "quay" (quay.io) or "dockerhub" (registry-1.docker.io).
set -uo pipefail

CURL="curl -fsS --max-time 30 --retry 3 --retry-delay 3"

die(){ echo "ERR: $*" >&2; exit 1; }

sanitize(){ echo "$1" | tr '/:' '__'; }

cmd_discover(){
  local kind=$1 repo=$2
  case "$kind" in
    quay)
      local page=1 names j
      while [[ $page -le 30 ]]; do
        j=$($CURL "https://quay.io/api/v1/repository/${repo}/tag/?limit=100&page=${page}&onlyActiveTags=true") || return 0
        names=$(printf '%s' "$j" | jq -r '.tags[]?.name')
        [[ -z "$names" ]] && break
        printf '%s\n' "$names"
        printf '%s' "$j" | jq -e '.tags | length >= 100' >/dev/null 2>&1 || break
        page=$((page+1))
      done | sort -u
      ;;
    github)
      # Docker Hub's catalog API is blocked on the DMZ; discover release tags from GitHub instead.
      local j
      j=$($CURL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${repo}/releases?per_page=100") || return 0
      printf '%s' "$j" | jq -r '.[].tag_name' | sort -u
      ;;
    *) die "unknown kind '$kind'" ;;
  esac
}

cmd_pull(){
  local srcref=$1 tag=$2 arch=$3 platarch=$4 outdir=$5
  mkdir -p "$outdir" || die "cannot mkdir $outdir"
  local tar="${outdir}/$(sanitize "$srcref")__${tag}__${arch}.tar"
  # NOTE: docker pull writes progress to stdout; redirect every docker command's stdout to
  # stderr so the orchestrator captures ONLY the final tar path below.
  docker pull --platform="linux/${platarch}" "${srcref}:${tag}" 1>&2 || die "pull failed ${srcref}:${tag} linux/${platarch}"
  docker tag "${srcref}:${tag}" "dmz-mirror:${arch}" 1>&2 || die "tag failed"
  docker save "dmz-mirror:${arch}" -o "$tar" 1>&2 || die "save failed"
  docker rmi "dmz-mirror:${arch}" "${srcref}:${tag}" >/dev/null 2>&1 || true
  echo "$tar"   # orchestrator reads this path from stdout
}

cmd_notify(){
  local webhook=$1; shift
  local text="$*"
  curl -fsS --max-time 15 -X POST -H 'Content-Type: application/json' \
       -d "$(jq -nc --arg t "$text" '{msg_type:"text",content:{text:$t}}')" "$webhook" >/dev/null 2>&1 && echo ok || echo fail
}

case "${1:-}" in
  discover) shift; cmd_discover "$@" ;;
  pull)     shift; cmd_pull "$@" ;;
  notify)   shift; cmd_notify "$@" ;;
  *) echo "usage: $0 {discover <kind> <param> | pull <srcref> <tag> <arch> <platarch> <outdir> | notify <webhook> <text>}" >&2; exit 64 ;;
esac
