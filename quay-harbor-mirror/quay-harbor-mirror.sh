#!/usr/bin/env bash
# quay-harbor-mirror.sh — runs ON day0-3 (internet + docker + /os_nfs, single host).
#
#   backfill   one-shot: save every release >= per-source floor not yet saved (NO notification)
#   run        cron:     save every release >= floor not yet saved (NOTIFIES on each new image)
#   discover   dry-run:  print, per source, what run/backfill would save
#   save <srcref> <tag>  save one tag, both arches (ad-hoc; no floor, no notification)
#   test-notify         post a test message to the Feishu webhook
#
# Flow per tag, per arch: docker pull --platform linux/{amd64,arm64}, then
# docker save | pigz -> OUTDIR/<group>/<arch>/<reponame>-<tag>-<arch>.tgz.
# State in state.json means each (srcref:tag:arch) is saved only once. New images
# on `run` are announced to Feishu (day0-3 posts directly — it has internet).
# Tags within a source are processed by a worker pool of MAX_CONCURRENT (default 2);
# each tag pulls one arch at a time, so that is also the max concurrent download count.
#
# No DMZ, no Harbor, no skopeo: day0-3 pulls the public registries itself (quay.io
# and GitHub directly; Docker Hub through the daemon mirror docker.m.daocloud.io).
set -uo pipefail

CONFIG="${QUAY_HARBOR_MIRROR_CONFIG:-/usr/local/etc/quay-harbor-mirror/config.sh}"
# shellcheck source=config.sh
. "$CONFIG"

log(){ echo "$(date '+%F %T') $*"; }

CURL="curl -fsS --max-time 30 --retry 3 --retry-delay 3"

state_init(){
  mkdir -p "$STATEDIR"
  [[ -s "$STATEFILE" ]] || echo '{"saved":{}}' > "$STATEFILE"
}
state_has(){ jq -e --arg k "$1" '.saved[$k]' "$STATEFILE" >/dev/null 2>&1; }
# state_set is guarded by flock: parallel workers (see save_pending) all write state.json.
state_set(){
  local ts; ts="$(date -u '+%FT%TZ')"
  { flock -x 9
    jq --arg k "$1" --arg t "$ts" '.saved[$k]=$t' "$STATEFILE" > "$STATEFILE.tmp" && mv "$STATEFILE.tmp" "$STATEFILE"
  } 9>"${STATEFILE}.lock"
}

# Post a message to the Feishu webhook directly (day0-3 has internet). No-op if webhook unset.
notify(){
  [[ -n "${FEISHU_WEBHOOK:-}" ]] || return 0
  $CURL --max-time 15 -X POST -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg t "image-saver: new image $*" '{msg_type:"text",content:{text:$t}}')" \
    "$FEISHU_WEBHOOK" >/dev/null 2>&1 || log "  (feishu notify failed)"
}

# discover_tags <kind> <param>  -> print ALL tags, one per line (filtering is done by the caller)
#   kind=quay   : param is the quay repo, e.g. ascend/vllm-ascend
#   kind=github : param is the github repo, e.g. vllm-project/vllm (release tags)
discover_tags(){
  local kind=$1 param=$2
  case "$kind" in
    quay)
      local page=1 j names
      while [[ $page -le 30 ]]; do
        j=$($CURL "https://quay.io/api/v1/repository/${param}/tag/?limit=100&page=${page}&onlyActiveTags=true") || return 0
        names=$(printf '%s' "$j" | jq -r '.tags[]?.name')
        [[ -z "$names" ]] && break
        printf '%s\n' "$names"
        printf '%s' "$j" | jq -e '.tags | length >= 100' >/dev/null 2>&1 || break
        page=$((page+1))
      done | sort -u
      ;;
    github)
      # Docker Hub's catalog API is blocked, but `docker pull` works through the
      # daemon mirror (docker.m.daocloud.io). Discover release tags from GitHub.
      local j
      j=$($CURL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${param}/releases?per_page=100") || return 0
      printf '%s' "$j" | jq -r '.[].tag_name' | sort -u
      ;;
    *) log "  unknown discover kind '$kind'"; return 0 ;;
  esac
}

discover_source(){
  local src=$1 name srcref filter discover dkind dparam
  IFS='~' read -r name srcref _ _ filter discover _ <<< "$src"
  dkind="${discover%%:*}"; dparam="${discover#*:}"
  discover_tags "$dkind" "$dparam" | grep -E "$filter" | sort -V
}

# stdin: v-sorted tags; $1: min base (e.g. v0.21.0). stdout: tags whose vX.Y.Z base >= min (empty min = all).
floor_filter(){
  local min="$1" line base smaller
  [[ -z "$min" ]] && { cat; return; }
  while read -r line; do
    [[ -z "$line" ]] && continue
    base="$(printf '%s' "$line" | sed -E 's/^(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
    smaller="$(printf '%s\n%s\n' "$min" "$base" | sort -V | head -1)"
    [[ "$smaller" == "$min" ]] && printf '%s\n' "$line"
  done
}

# tag_fully_saved <srcref> <tag> -> 0 if every arch in ARCHES is in state
tag_fully_saved(){
  local srcref=$1 tag=$2 arch
  for arch in "${ARCHES[@]}"; do state_has "${srcref}:${tag}:${arch}" || return 1; done
  return 0
}

# pull_with_retry <srcref> <tag> <platarch> -> 0 on success. Retries transient
# registry EOFs (quay.io occasionally drops the TLS connection at the auth step).
pull_with_retry(){
  local srcref=$1 tag=$2 platarch=$3 attempt max="${PULL_RETRIES:-3}"
  for ((attempt=1; attempt<=max; attempt++)); do
    if docker pull --platform="linux/${platarch}" "${srcref}:${tag}" 1>&2; then return 0; fi
    if [[ $attempt -lt $max ]]; then
      log "    pull attempt ${attempt}/${max} failed (linux/${platarch}); retrying in $((attempt*10))s..."
      sleep $((attempt*10))
    fi
  done
  return 1
}

# save_arch <srcref> <group> <reponame> <tag> <arch>  -> 0 on success (or already saved)
save_arch(){
  local srcref=$1 group=$2 reponame=$3 tag=$4 arch=$5
  local platarch=$arch; [[ $arch == aarch64 ]] && platarch=arm64
  local key="${srcref}:${tag}:${arch}"
  if state_has "$key"; then log "    skip (saved) ${key}"; return 0; fi
  local outdir="${OUTDIR}/${group}/${arch}"
  local outfile="${outdir}/${reponame}-${tag}-${arch}.tgz"
  # idempotent across state loss: if the file is already on disk, just record it.
  if [[ -s "$outfile" ]]; then state_set "$key"; log "    skip (file exists) ${outfile}"; return 0; fi
  mkdir -p "$outdir" || { log "    !!! cannot mkdir ${outdir}"; return 1; }
  local archtag="${srcref}:${tag}-${arch}"
  log "    >>> pull+save ${key} -> ${outfile}"
  if pull_with_retry "${srcref}" "${tag}" "${platarch}"; then
    # (1) Save the tar with the ORIGINAL ref — portable, clean upstream tag.
    if docker save "${srcref}:${tag}" | pigz > "${outfile}.tmp"; then
      mv "${outfile}.tmp" "$outfile"
      state_set "$key"
      log "    <<< saved ${outfile} ($(du -h "$outfile" | cut -f1))"
      # (2) Dispose of the just-pulled LOCAL image. Default: free /data/docker
      # (the .tgz on /os_nfs is the artifact). KEEP_LOCAL=1 instead retags it
      # <srcref>:<tag>-<arch> (bare tag dropped) so arches coexist locally.
      if [[ "${KEEP_LOCAL:-0}" == "1" ]] && docker tag "${srcref}:${tag}" "$archtag" >/dev/null 2>&1; then
        docker rmi "${srcref}:${tag}" >/dev/null 2>&1 || true
        log "    local: ${archtag}"
      else
        docker rmi "${srcref}:${tag}" >/dev/null 2>&1 || true
      fi
      return 0
    fi
    log "    !!! save/pigz failed for ${key}"
    rm -f "${outfile}.tmp"
  else
    log "    !!! pull failed for ${key} (linux/${platarch})"
  fi
  docker rmi "${srcref}:${tag}" >/dev/null 2>&1 || true
  return 1
}

# save_tag <srcref> <group> <reponame> <tag> <do_notify> -> 0 only if the tag is now fully saved.
# Notifies once per tag, the first cycle it becomes complete.
save_tag(){
  local srcref=$1 group=$2 reponame=$3 tag=$4 do_notify=$5 arch newly=0 failed=0 was_complete
  was_complete=0; tag_fully_saved "$srcref" "$tag" && was_complete=1
  for arch in "${ARCHES[@]}"; do
    if state_has "${srcref}:${tag}:${arch}"; then log "    skip (saved) ${srcref}:${tag}:${arch}"; continue; fi
    if save_arch "$srcref" "$group" "$reponame" "$tag" "$arch"; then newly=1; else failed=1; fi
  done
  if [[ $failed -eq 0 ]]; then
    [[ $do_notify -eq 1 && $was_complete -eq 0 ]] && notify "${srcref}:${tag}"
    return 0
  fi
  return 1
}

# cmd_onetag <name> <srcref> <group> <reponame> <tag> <do_notify> — save one tag (both arches).
# Invoked as its own process by the save_pending worker pool, so state.json writes
# are cross-process serialised by state_set's flock.
cmd_onetag(){
  local name=$1 srcref=$2 group=$3 reponame=$4 tag=$5 do_notify=$6
  state_init
  log "  >>> save ${srcref}:${tag}"
  if save_tag "$srcref" "$group" "$reponame" "$tag" "$do_notify"; then
    log "  <<< done ${srcref}:${tag}"
  else
    log "  !!! partial/failed ${srcref}:${tag} (will retry next run)"
  fi
}

# save_pending <src> <do_notify> — process all pending tags for a source, up to
# MAX_CONCURRENT tags in parallel (each tag = 1 pull at a time, arches sequential).
save_pending(){
  local src=$1 do_notify=$2
  local name srcref group reponame filter discover min
  IFS='~' read -r name srcref group reponame filter discover min <<< "$src"
  log "=== ${name} (${srcref}) -> ${OUTDIR}/{${group}}/{${ARCHES[*]}}/ | floor=${min:-none} | notify=${do_notify} | parallel=${MAX_CONCURRENT:-1} ==="
  local tags pending tag todo=()
  tags="$(discover_source "$src")" || { log "  discover failed, skipping"; return; }
  [[ -n "$tags" ]] || { log "  (no matching tags)"; return; }
  pending="$(printf '%s\n' "$tags" | floor_filter "$min")"
  log "  $(printf '%s\n' "$pending" | grep -c .) tag(s) >= floor"
  while read -r tag; do
    [[ -z "$tag" ]] && continue
    if tag_fully_saved "$srcref" "$tag"; then log "  skip (saved) ${srcref}:${tag}"; else todo+=("$tag"); fi
  done <<< "$pending"
  [[ ${#todo[@]} -gt 0 ]] || { log "  (nothing pending)"; return; }
  log "  processing ${#todo[@]} tag(s), up to ${MAX_CONCURRENT:-1} in parallel"
  printf '%s\n' "${todo[@]}" | xargs -P "${MAX_CONCURRENT:-1}" -I {} "$0" _onetag "$name" "$srcref" "$group" "$reponame" {} "$do_notify"
}

cmd_discover(){
  local src name srcref min tags pending t arch miss any
  for src in "${SOURCES[@]}"; do
    IFS='~' read -r name srcref _ _ _ _ min <<< "$src"
    log "=== ${name} (${srcref}) | floor=${min:-none} ==="
    tags="$(discover_source "$src")"
    pending="$(printf '%s\n' "$tags" | floor_filter "$min")"
    log "  would save now (not yet fully saved):"
    any=0
    while read -r t; do
      [[ -z "$t" ]] && continue
      miss=0; for arch in "${ARCHES[@]}"; do state_has "${srcref}:${t}:${arch}" || miss=1; done
      if [[ $miss -eq 1 ]]; then printf '    %s\n' "$t"; any=1; fi
    done <<< "$pending"
    if [[ $any -eq 0 ]]; then log "    (none — all already saved)"; fi
  done
}

cmd_run(){       state_init; local src; for src in "${SOURCES[@]}"; do save_pending "$src" 1; done; log "run complete"; }
cmd_backfill(){  state_init; local src; for src in "${SOURCES[@]}"; do save_pending "$src" 0; done; log "backfill complete"; }

cmd_save_one(){
  local want=$1 tag=$2 src name srcref group reponame found=0
  for src in "${SOURCES[@]}"; do
    IFS='~' read -r name srcref group reponame _ _ _ <<< "$src"
    [[ "$srcref" == "$want" ]] || continue
    found=1
    cmd_onetag "$name" "$srcref" "$group" "$reponame" "$tag" 0
    break
  done
  [[ $found -eq 1 ]] || { log "unknown source '${want}' (not in config)"; exit 2; }
}

# Post a test message to the Feishu webhook (uses the same path as notify()).
cmd_test_notify(){
  [[ -n "${FEISHU_WEBHOOK:-}" ]] || { log "FEISHU_WEBHOOK is empty — notifications disabled"; return 0; }
  log "sending test notification to Feishu..."
  if $CURL --max-time 15 -X POST -H 'Content-Type: application/json' \
     -d "$(jq -nc --arg t "image-saver test notification from $(hostname) at $(date '+%F %T')" '{msg_type:"text",content:{text:$t}}')" \
     "$FEISHU_WEBHOOK" >/dev/null 2>&1; then
    log "  test notification sent OK — check the Feishu group"
  else
    log "  test notification FAILED (is open.feishu.cn reachable from day0-3?)"
    return 1
  fi
}

case "${1:-run}" in
  run)             cmd_run ;;
  backfill)        cmd_backfill ;;
  discover)        cmd_discover ;;
  save)            shift; [[ $# -ge 2 ]] || { echo "usage: $0 save <srcref> <tag>" >&2; exit 64; }; cmd_save_one "$1" "$2" ;;
  test-notify)     cmd_test_notify ;;
  _onetag)         shift; cmd_onetag "$@" ;;   # internal: invoked by the save_pending worker pool
  -h|--help|help)  sed -n '2,14p' "$0" ;;
  *) echo "unknown command '$1'" >&2; exit 64 ;;
esac
