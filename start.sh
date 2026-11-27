#!/usr/bin/env bash
# Start LoopForge from the published GHCR image pinned in compose.yaml
# (default), or build this checkout for development.
#
# Usage:
#   ./start.sh            install/start in the background (same as -d)
#   ./start.sh -d         install/start in the background
#   ./start.sh logs       follow platform logs
#   ./start.sh stop       stop containers, keep them and their data
#   ./start.sh down       remove containers, keep data volumes
#   ./start.sh restart    restart the platform container
#   ./start.sh pull       refresh images and recreate changed containers
#   ./start.sh dev        build this checkout (compose.dev.yaml) and start it
#   ./start.sh release    switch a source-built installation back to GHCR
#   MIRROR=ghcr.nju.edu.cn ./start.sh
#                         pull ghcr.io images from that host and tag them back
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source scripts/docker-access.sh
source scripts/ghcr-mirror.sh

# compose 文件列表固定在脚本内，override 永远最后。
# 背景：曾用 compose.yaml+compose.dev.yaml 重建 mysql，漏掉 override，
# MySQL 调优参数（sort_buffer_size 等）整段丢失，列表接口持续报
# Error 1038 (HY001) Out of sort memory。所有 compose 调用都必须经过本函数。
loopforge_compose_files() {
  local files="compose.yaml"
  if grep -qs -E '^COMPOSE_FILE=.*compose\.dev\.yaml' .env || [[ "${LOOPFORGE_BUILD_FROM_SOURCE:-0}" == 1 ]]; then
    files="${files}:compose.dev.yaml"
  fi
  [[ -f compose.override.yaml ]] && files="${files}:compose.override.yaml"
  printf '%s' "$files"
}

compose() {
  [[ -f .env ]] || docker_access_fail 'Not installed yet. Run ./start.sh first.'
  select_docker_access || docker_access_fail 'Docker is not running, or this user cannot access it.'
  local -a files=()
  local _cf f
  IFS=':' read -r -a _cf <<< "$(loopforge_compose_files)"
  for f in "${_cf[@]}"; do files+=(-f "$f"); done
  docker_access compose "${files[@]}" --profile platform "$@"
}

cmd="${1:--d}"
shift || true
case "$cmd" in
  up|-d|detach) bash scripts/install.sh ;;
  dev) LOOPFORGE_BUILD_FROM_SOURCE=1 bash scripts/install.sh ;;
  release)
    [[ -f .env ]] && python3 - <<'PY'
import pathlib,re
p=pathlib.Path('.env')
p.write_text(re.sub(r'(?m)^COMPOSE_FILE=.*\n?','',p.read_text()))
PY
    COMPOSE_FILE=compose.yaml:compose.override.yaml bash scripts/install.sh
    ;;
  pull)
    # An empty MIRROR keeps the original refresh. A registry host pulls the pinned
    # ghcr.io tag from that host and tags it back before MySQL is refreshed.
    if [[ -n "${MIRROR:-}" ]]; then
      [[ -f .env ]] || docker_access_fail 'Not installed yet. Run ./start.sh first.'
      select_docker_access || docker_access_fail 'Docker is not running, or this user cannot access it.'
    fi
    if mirror_published_ghcr always; then
      compose pull --policy always mysql
    else
      compose pull --ignore-buildable --policy always
    fi
    compose up -d --no-build --wait --wait-timeout 180
    # A newer image may read generated columns the old volume never got.
    bash scripts/install-schema-extensions.sh
    ;;
  logs) compose logs -f "${@:-platform}" ;;
  stop) compose stop ;;
  down) compose down --remove-orphans ;;
  restart) compose restart platform ;;
  build)
    echo 'The default start uses the published GHCR image (no local build).' >&2
    echo 'For a source build: ./start.sh dev' >&2
    exit 1
    ;;
  *)
    echo "unknown: $cmd" >&2
    echo 'usage: ./start.sh [-d|logs|stop|down|restart|pull|dev|release]' >&2
    exit 1
    ;;
esac
