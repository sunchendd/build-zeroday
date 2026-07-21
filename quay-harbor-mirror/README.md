# quay-harbor-mirror

Every 10 minutes, saves release images from the public registries as `.tgz`
(gzipped via `pigz`) under `/os_nfs/06_images/openimages`, so the build hosts can
`docker load` them without internet.

```
/os_nfs/06_images/openimages/
├── vllm/
│   ├── amd64/vllm-openai-<tag>-amd64.tgz
│   └── aarch64/vllm-openai-<tag>-aarch64.tgz
└── vllm-ascend/
    ├── amd64/vllm-ascend-<tag>-amd64.tgz
    └── aarch64/vllm-ascend-<tag>-aarch64.tgz
```

| Source | Saved as | Floor (init) |
|---|---|---|
| `quay.io/ascend/vllm-ascend` (+rc, -a3/-310p/-openeuler flavors) | `vllm-ascend/<arch>/vllm-ascend-<tag>-<arch>.tgz` | `v0.21.0` |
| `vllm/vllm-openai` (Docker Hub, GA releases) | `vllm/<arch>/vllm-openai-<tag>-<arch>.tgz` | `v0.21.0` |

Each tag is saved **per architecture** (amd64 + aarch64), cross-saved on the x86_64
host via `docker pull --platform`. The `.tgz` keeps the **original upstream tag**
inside (`<srcref>:<tag>`, e.g. `quay.io/ascend/vllm-ascend:v0.21.0`) — a clean,
portable artifact. After saving, the just-pulled image is **removed from day0-3**
by default (`KEEP_LOCAL=0`) to keep `/data/docker` clear — the `.tgz` on `/os_nfs`
is the artifact. Set `KEEP_LOCAL=1` to instead keep it locally as
`<srcref>:<tag>-<arch>` (bare tag removed) so arches coexist as a cache (each image
is ~16 GB — watch the disk). To restore one on a host:
`docker load -i /os_nfs/06_images/openimages/vllm-ascend/aarch64/vllm-ascend-v0.21.0-aarch64.tgz`.
New releases are saved automatically and announced to a Feishu group; the one-time
init (`backfill`) does **not** announce.

## Why it runs on day0-3 (single host)

The previous design split work across an offline Harbor host (16.9) and an online
DMZ puller. That is gone: **day0-3** has everything the job needs in one place —

- **internet** — `quay.io` and `api.github.com` are reachable directly; Docker Hub is
  pulled through the daemon mirror `docker.m.daocloud.io`.
- **docker** — `docker pull --platform` + `docker save` work natively (no skopeo, no daemon proxy issues).
- **`/os_nfs`** — the output share is mounted right here, so `.tgz`s are written directly (no rsync).

So the loop is one script on one host: discover tags → pull → `docker save | pigz` → done.

```
 day0-3 (orchestrator + puller, online, /os_nfs mounted)
   │  (1) discover tags  — quay.io API (ascend) / GitHub releases API (vllm)
   │  (2) docker pull --platform linux/{amd64,arm64} <srcref>:<tag>
   │  (3) docker save <img> | pigz  ->  /os_nfs/06_images/openimages/<group>/<arch>/<name>-<tag>-<arch>.tgz
   │  (4) Feishu ◄── notify (cron `run` only; direct POST, day0-3 is online)
   ▼
 /os_nfs/06_images/openimages/   (consumed by the offline build hosts via `docker load`)
```

Environment-specific gotchas baked into the design:
- **Docker Hub's catalog API is blocked**, but `docker pull` works through the daemon
  mirror. So vllm release tags are discovered from the **GitHub releases API** and
  pulled through `docker.m.daocloud.io`.
- **`.tgz` via `pigz`**, not plain `docker save -o`: these images are 15–18 GB each;
  gzip halves the on-NFS footprint (`pigz` is the repo-wide convention). Writes go to
  a `.tmp` file and are `mv`'d into place, so a partial file is never visible.
- **State is per `(srcref, tag, arch)`**, so a tag whose aarch64 save failed is retried
  on later cycles without redoing the amd64 side.

## Files & locations

On **day0-3** (`/usr/local/...`):
- `bin/quay-harbor-mirror.sh` — the orchestrator (single script; no DMZ helper anymore).
- `etc/quay-harbor-mirror/config.sh` — sources, filters, floors, output dir, webhook. **Edit this to change scope.**
- `var/lib/quay-harbor-mirror/state.json` — keys = `srcref:tag:arch` already saved.
- `var/log/quay-harbor-mirror.log` — cron log.
- `/etc/cron.d/quay-harbor-mirror` — the schedule (every 10 min, flock-guarded).

In this repo (`quay-harbor-mirror/`): `config.sh`, `quay-harbor-mirror.sh`,
`quay-harbor-mirror.cron`, `README.md`.

## Managing the job

### Commands (run on day0-3)
```bash
quay-harbor-mirror.sh discover                          # dry-run: what would be saved now
quay-harbor-mirror.sh backfill                          # one-shot init: save all >= floor (NO notify)
quay-harbor-mirror.sh run                               # same as cron: save all >= floor (NOTIFIES new)
quay-harbor-mirror.sh save <srcref> <tag>               # ad-hoc single tag (no floor, no notify)
```
`<srcref>` is the pull ref without tag, e.g. `quay.io/ascend/vllm-ascend` or `vllm/vllm-openai`.

### Start / stop the automatic schedule
```bash
# enable (every 10 min; skips a cycle if the previous run is still busy)
install -m 0644 quay-harbor-mirror.cron /etc/cron.d/quay-harbor-mirror
# disable
rm /etc/cron.d/quay-harbor-mirror
# run one cycle manually right now (same as a cron tick, with notification)
quay-harbor-mirror.sh run
```

### Where to look
- **Log:** `tail -f /var/log/quay-harbor-mirror.log`
- **State:** `cat /var/lib/quay-harbor-mirror/state.json` (keys = `srcref:tag:arch` already saved)
- **Output:** `ls -lh /os_nfs/06_images/openimages/*/*`
- **In-flight:** `pgrep -af quay-harbor-mirror`
- **flock:** a run in progress holds `/var/lock/quay-harbor-mirror.lock`; the next tick skips until it's free.

### Changing what is saved
Edit `/usr/local/etc/quay-harbor-mirror/config.sh` on day0-3, then the next cron tick picks it up:
- **Add/remove a source or change the tag filter / floor:** edit `SOURCES` (each line is
  `name~srcref~group~reponame~filter~discover~min`; `~` is the field separator so `|` is free inside the regex).
- **Re-save a tag** that is already in state:
  `jq 'del(.saved["<srcref>:<tag>:amd64"],.saved["<srcref>:<tag>:aarch64"])' state.json > t && mv t state.json`
  (and delete the existing `.tgz` files), then `quay-harbor-mirror.sh save <srcref> <tag>` (or wait for the next tick).
- **Save an old version below the floor:** `quay-harbor-mirror.sh save <srcref> <tag>` (ignores the floor).
- **Keep images locally on day0-3:** set `KEEP_LOCAL=1` to retain each saved image as `<srcref>:<tag>-<arch>` (default `0` removes it after saving to free `/data/docker`).
- **Notifications:** set `FEISHU_WEBHOOK` (empty = off). Only `run` notifies; `backfill` and `save` do not.

### Deploy / update the scripts
```bash
# on day0-3
install -m 0644 config.sh            /usr/local/etc/quay-harbor-mirror/config.sh
install -m 0755 quay-harbor-mirror.sh /usr/local/bin/quay-harbor-mirror.sh
install -m 0644 quay-harbor-mirror.cron /etc/cron.d/quay-harbor-mirror   # (re)enable the schedule
```

## Verify (on day0-3)
```bash
quay-harbor-mirror.sh discover                          # what run would save
ls -lh /os_nfs/06_images/openimages/vllm-ascend/aarch64/ # saved artifacts
docker load -i /os_nfs/06_images/openimages/vllm-ascend/aarch64/vllm-ascend-v0.21.0-aarch64.tgz
# -> "Loaded image: quay.io/ascend/vllm-ascend:v0.21.0" (original tag, as on the registry)
# locally day0-3 keeps nothing by default (KEEP_LOCAL=0); with KEEP_LOCAL=1 it keeps …:v0.21.0-amd64 / …:v0.21.0-aarch64
```

## Rollback
```bash
rm /etc/cron.d/quay-harbor-mirror                        # stop the cron
rm /usr/local/bin/quay-harbor-mirror.sh /usr/local/etc/quay-harbor-mirror/config.sh
# saved .tgz files stay under /os_nfs/06_images/openimages; remove them manually if desired.
```

## Troubleshooting
- **A tag keeps failing:** check the log. Most often day0-3 ran out of disk
  (`df -h /data /os_nfs`) — these images are 15–18 GB each, pulled to `/data/docker`
  before saving. It is retried every cycle until it succeeds.
- **`discover` empty for a source:** day0-3 could not reach quay/GitHub that cycle; it retries next tick.
- **No Feishu notification:** day0-3 must reach `open.feishu.cn`; check
  `curl -s -o /dev/null -w %{http_code} https://open.feishu.cn/`.
- **Partial `.tgz.tmp` left behind:** a save was interrupted; it is removed on the next attempt for that arch.
