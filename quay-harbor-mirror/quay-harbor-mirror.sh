#!/usr/bin/env bash
# quay-harbor-mirror.sh — runs ON 16.9 (Harbor host, no public internet).
#
#   backfill   one-shot: mirror every release >= per-source floor not yet mirrored (NO notification)
#   run        cron:     mirror every release >= floor not yet mirrored (NOTIFIES on each new image)
#   discover   dry-run:  print, per source, what run/backfill would mirror
#   mirror <srcref> <tag>  mirror one tag end-to-end (ad-hoc; no floor, no notification)
#
# Flow per tag: on the DMZ docker pull --platform amd64+aarch64 and save a .tar each,
# rsync the tars to 16.9, docker load+tag+push each arch, then docker manifest create/push
# a multi-arch tag. State in state.json means each tag is mirrored only once.
# Notifications go through the DMZ (16.9 has no internet) to a Feishu webhook.
set -uo pipefail

CONFIG="${QUAY_HARBOR_MIRROR_CONFIG:-/usr/local/etc/quay-harbor-mirror/config.sh}"
# shellcheck source=config.sh
. "$CONFIG"

log(){ echo "$(date '+%F %T') $*"; }

# Harbor basic auth straight from the existing docker login (no secret stored here).
HARBOR_B64="$(jq -r --arg h "$HARBOR_HOST" '.auths[$h].auth // empty' /root/.docker/config.json 2>/dev/null || true)"
[[ -n "$HARBOR_B64" ]] || { log "FATAL: no Harbor auth for $HARBOR_HOST in /root/.docker/config.json"; exit 2; }

sshdmz(){
  # </dev/null so ssh does not drain a parent `while read` loop's stdin
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=15 "$DMZ_USER@$DMZ_HOST" "$@" </dev/null
}

state_init(){
  mkdir -p "$STAGEDIR" "$STATEDIR"
  [[ -s "$STATEFILE" ]] || echo '{"mirrored":{}}' > "$STATEFILE"
}
state_has(){ jq -e --arg k "$1" '.mirrored[$k]' "$STATEFILE" >/dev/null 2>&1; }
state_set(){ local ts; ts="$(date -u '+%FT%TZ')"; jq --arg k "$1" --arg t "$ts" '.mirrored[$k]=$t' "$STATEFILE" > "$STATEFILE.tmp" && mv "$STATEFILE.tmp" "$STATEFILE"; }

ensure_project(){
  local p="$1"
  curl -fsS -X POST "$HARBOR_API/projects" \
       -H "Authorization: Basic $HARBOR_B64" -H 'Content-Type: application/json' \
       -d "{\"project_name\":\"${p}\",\"metadata\":{\"public\":\"true\"}}" >/dev/null 2>&1 \
    && log "  created Harbor project ${p}" || log "  Harbor project ${p} present (or create no-op)"
}

# Post a message to the Feishu webhook via the DMZ (16.9 is offline). No-op if webhook unset.
notify(){
  [[ -n "${FEISHU_WEBHOOK:-}" ]] || return 0
  sshdmz "$DMZ_HELPER" notify "$FEISHU_WEBHOOK" "harbor-mirror: new image $*" 2>/dev/null \
    || log "  (feishu notify failed)"
}

# Harbor registry v2 helpers — used directly via curl/skopeo because the docker
# daemon on 16.9 proxies all registry traffic through a dead proxy, so `docker
# push`/`docker manifest` don't work. curl/skopeo run from the shell (no proxy env).
harbor_token(){ # $1 = repo (project/reponame) -> echoes a registry bearer token
  curl -fsS -H "Authorization: Basic $HARBOR_B64" \
    "http://${HARBOR_HOST}/service/token?service=harbor-registry&scope=repository:$1:pull,push" \
    | jq -r '.token // .access_token // empty'
}
# harbor_manifest_entry <repo> <tag> <arch>  -> one manifest-list entry JSON
harbor_manifest_entry(){
  local repo=$1 tag=$2 arch=$3 T man mt dgst sz plat
  plat=$arch; [[ $arch == aarch64 ]] && plat=arm64
  T="$(harbor_token "$repo")"
  man="$(curl -fsS -H "Authorization: Bearer $T" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    "http://${HARBOR_HOST}/v2/${repo}/manifests/${tag}")" || return 1
  mt=$(printf '%s' "$man" | jq -r '.mediaType // "application/vnd.docker.distribution.manifest.v2+json"')
  dgst="sha256:$(printf '%s' "$man" | sha256sum | cut -d' ' -f1)"
  sz=$(printf '%s' "$man" | wc -c)
  jq -n --arg mt "$mt" --arg dg "$dgst" --argjson sz "$sz" --arg plat "$plat" \
    '{mediaType:$mt, size:$sz, digest:$dg, platform:{os:"linux", architecture:$plat}}'
}
# put_manifest_list <repo> <tag>   (stdin: one entry JSON per line)
put_manifest_list(){
  local repo=$1 tag=$2 T list
  T="$(harbor_token "$repo")"
  list="$(jq -s -c '{schemaVersion:2, mediaType:"application/vnd.docker.distribution.manifest.list.v2+json", manifests:.}')"
  curl -fsS -o /dev/null -X PUT -H "Authorization: Bearer $T" \
    -H "Content-Type: application/vnd.docker.distribution.manifest.list.v2+json" \
    --data-binary "$list" "http://${HARBOR_HOST}/v2/${repo}/manifests/${tag}"
}

# mirror_tag <name> <srcref> <project> <reponame> <tag>  -> 0 on success
mirror_tag(){
  local name=$1 srcref=$2 proj=$3 reponame=$4 tag=$5
  local repo="${proj}/${reponame}"
  local arch platarch dmztar tar ref got=() entries=""
  for arch in amd64 aarch64; do
    platarch=$arch; [[ $arch == aarch64 ]] && platarch=arm64
    dmztar="$(sshdmz "$DMZ_HELPER" pull "$srcref" "$tag" "$arch" "$platarch" "$DMZ_TARDIR")" || { log "    pull ${arch} failed"; continue; }
    tar="$STAGEDIR/$(basename "$dmztar")"
    if ! rsync -az --partial --timeout=0 \
         -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
         "${DMZ_USER}@${DMZ_HOST}:${dmztar}" "$tar"; then
      log "    rsync ${arch} failed"; rm -f "$tar"; sshdmz "rm -f '$dmztar'" 2>/dev/null || true; continue
    fi
    ref="${tag}-${arch}"
    if skopeo --insecure-policy copy --dest-tls-verify=false --dest-authfile=/root/.docker/config.json \
         "docker-archive:${tar}" "docker://${HARBOR_HOST}/${repo}:${ref}" >/dev/null 2>&1; then
      got+=("$arch"); log "    pushed ${repo}:${ref}"
    else
      log "    skopeo push ${arch} failed"
    fi
    rm -f "$tar"; sshdmz "rm -f '$dmztar'" 2>/dev/null || true
  done

  [[ ${#got[@]} -gt 0 ]] || { log "    no arches succeeded for ${srcref}:${tag}"; return 1; }
  local ent
  for arch in "${got[@]}"; do
    ent="$(harbor_manifest_entry "$repo" "${tag}-${arch}" "$arch")" && entries+="${ent}"$'\n'
  done
  if [[ -n "$entries" ]] && printf '%s' "$entries" | put_manifest_list "$repo" "$tag"; then
    log "    manifest list pushed ${repo}:${tag} (arches: ${got[*]})"
    return 0
  fi
  log "    manifest list push failed (arch tags ${got[*]} still present)"
  return 1
}

discover_source(){
  local src=$1 name srcref filter discover dkind dparam
  IFS='~' read -r name srcref _ _ filter discover _ <<< "$src"
  dkind="${discover%%:*}"; dparam="${discover#*:}"
  sshdmz "$DMZ_HELPER" discover "$dkind" "$dparam" 2>/dev/null | grep -E "$filter" | sort -V
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

# mirror_pending <src> <do_notify 1|0>
mirror_pending(){
  local src=$1 do_notify=$2
  local name srcref proj reponame filter discover min
  IFS='~' read -r name srcref proj reponame filter discover min <<< "$src"
  log "=== ${name} (${srcref}) -> ${HARBOR_HOST}/${proj}/${reponame} | floor=${min:-none} | notify=${do_notify} ==="
  ensure_project "$proj"
  local tags pending tag key
  tags="$(discover_source "$src")" || { log "  discover failed, skipping"; return; }
  [[ -n "$tags" ]] || { log "  (no matching tags)"; return; }
  pending="$(printf '%s\n' "$tags" | floor_filter "$min")"
  log "  $(printf '%s\n' "$pending" | grep -c .) tag(s) >= floor"
  while read -r tag; do
    [[ -z "$tag" ]] && continue
    key="${srcref}:${tag}"
    if state_has "$key"; then log "  skip (mirrored) ${key}"; continue; fi
    log "  >>> mirror ${key}"
    if mirror_tag "$name" "$srcref" "$proj" "$reponame" "$tag"; then
      state_set "$key"; log "  <<< done ${key}"
      [[ $do_notify -eq 1 ]] && notify "${HARBOR_HOST}/${proj}/${reponame}:${tag}"
    else
      log "  !!! FAILED ${key} (will retry next run)"
    fi
  done <<< "$pending"
}

cmd_discover(){
  local src name srcref tags pending min mirrored new
  for src in "${SOURCES[@]}"; do
    IFS='~' read -r name srcref _ _ _ _ min <<< "$src"
    log "=== ${name} (${srcref}) | floor=${min:-none} ==="
    tags="$(discover_source "$src")"
    pending="$(printf '%s\n' "$tags" | floor_filter "$min")"
    new=""; while read -r t; do [[ -n "$t" ]] && ! state_has "${srcref}:${t}" && new+="${t}"$'\n'; done <<< "$pending"
    log "  would mirror now (not yet mirrored):"
    if [[ -z "$(printf '%s' "$new" | sed '/^$/d')" ]]; then log "    (none — all already mirrored)"; else printf '%s' "$new" | sed '/^$/d' | sed 's/^/    /'; fi
  done
}

cmd_run(){       state_init; local src; for src in "${SOURCES[@]}"; do mirror_pending "$src" 1; done; log "run complete"; }
cmd_backfill(){  state_init; local src; for src in "${SOURCES[@]}"; do mirror_pending "$src" 0; done; log "backfill complete"; }

cmd_mirror_one(){
  local srcref=$1 tag=$2 src name proj reponame found=0
  state_init
  for src in "${SOURCES[@]}"; do
    IFS='~' read -r name srcref proj reponame _ _ _ <<< "$src"
    [[ "$srcref" == "$1" ]] || continue
    found=1
    log "=== ad-hoc mirror ${srcref}:${tag} -> ${HARBOR_HOST}/${proj}/${reponame}:${tag} ==="
    ensure_project "$proj"
    if mirror_tag "$name" "$srcref" "$proj" "$reponame" "$tag"; then state_set "${srcref}:${tag}"; fi
    break
  done
  [[ $found -eq 1 ]] || { log "unknown source '${srcref}' (not in config)"; exit 2; }
}

case "${1:-run}" in
  run)             cmd_run ;;
  backfill)        cmd_backfill ;;
  discover)        cmd_discover ;;
  mirror)          shift; [[ $# -ge 2 ]] || { echo "usage: $0 mirror <srcref> <tag>" >&2; exit 64; }; cmd_mirror_one "$1" "$2" ;;
  -h|--help|help)  sed -n '2,16p' "$0" ;;
  *) echo "unknown command '$1'" >&2; exit 64 ;;
esac
