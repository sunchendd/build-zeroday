# shellcheck shell=bash
# Configuration for the quay -> Harbor mirror. Sourced by quay-harbor-mirror.sh.
# Edit filters / sources here without touching the orchestrator logic.

# ---- Harbor (runs on 16.9, Harbor is local there) ----
HARBOR_HOST="70.189.16.9"
HARBOR_API="http://${HARBOR_HOST}/api/v2.0"   # verified reachable from 16.9 localhost
# Harbor credentials are read at runtime from /root/.docker/config.json (no secret in this file).

# ---- DMZ (pull host; reached from 16.9 over keyless SSH) ----
DMZ_HOST="172.24.194.3"
DMZ_USER="root"
DMZ_HELPER="/usr/local/bin/dmz-mirror-helper.sh"
DMZ_TARDIR="/Maas/docker_space/quay-mirror"   # big disk on DMZ (~800G free)

# ---- 16.9 local layout (staging lives on the 64T root) ----
STAGEDIR="/AI/images/0DAY/quay-mirror/stage"
STATEDIR="/var/lib/quay-harbor-mirror"
STATEFILE="${STATEDIR}/state.json"
LOGFILE="/var/log/quay-harbor-mirror.log"

# ---- Sources to mirror ----
# Format: name~srcref~project~reponame~filter~discover~min
#   name     : label for state key / logs
#   srcref   : pull ref without tag (what `docker pull` uses), e.g. quay.io/ascend/vllm-ascend or vllm/vllm-openai
#   project  : Harbor project (= source org)
#   reponame : Harbor repo. Harbor path => HARBOR_HOST/project/reponame
#   filter   : extended regex (applied on 16.9); tag mirrored only if it matches. nightly/branch excluded.
#   discover : how to list tags: quay:<repo>  or  github:<github-repo>
#   min      : backfill floor — only releases with base version >= min are mirrored (backfill AND cron).
#              Empty = no floor (mirror everything matching the filter).
# NB: Docker Hub's catalog API is blocked on the DMZ, but `docker pull` works through the daemon mirrors,
#     so vllm release tags are discovered via the GitHub releases API and pulled through the mirror.
FILTER_ASCEND='^v[0-9]+\.[0-9]+\.[0-9]+(rc[0-9]+)?((-a3|-310p|-openeuler))*$'
FILTER_VLLM='^v[0-9]+\.[0-9]+\.[0-9]+$'
SOURCES=(
  "ascend~quay.io/ascend/vllm-ascend~ascend~vllm-ascend~${FILTER_ASCEND}~quay:ascend/vllm-ascend~v0.21.0"
  "vllm~vllm/vllm-openai~vllm~vllm-openai~${FILTER_VLLM}~github:vllm-project/vllm~v0.21.0"
)

# ---- Notifications ----
# Feishu group bot. Reached through the DMZ (16.9 is offline). Leave empty to disable.
# Only cron `run` notifies (new images); `backfill` (the one-time init) does NOT notify.
FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/d0e73483-a7ba-48aa-8462-bea5d1cc2eb4"
