#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=0
COMPOSE_ROOTS=()
CONFIG_FILE="${MAINTAIN_COMPOSE_DIRS:-$HOME/.config/maintain/compose-dirs}"

usage() {
  cat <<'EOF'
Usage: maintain [options] <command>

Commands:
  check       Show quick health status for the server.
  system      Update apt packages and refresh Snap Store when available.
  docker      Pull and recreate Docker Compose services.
  clean       Remove safe apt/Docker/Snap garbage, without deleting volumes.
  all         Run check, system, docker, clean, then check again.
  help        Show this help.

Options:
  -n, --dry-run          Print commands that would run, without changing state.
      --compose-root DIR Search this root for compose files. Can be repeated.
  -h, --help             Show this help.

Compose discovery:
  - By default, docker only maintains Compose projects that are currently running.
  - If ~/.config/maintain/compose-dirs exists, docker uses directories listed there.
  - --compose-root DIR discovers compose files under DIR, including stopped projects.
  - Override the config path with MAINTAIN_COMPOSE_DIRS=/path/to/file.

Examples:
  maintain check
  maintain --dry-run all
  maintain system
  maintain clean
  maintain --compose-root ~/Desktop docker
EOF
}

log() {
  printf '\n== %s ==\n' "$*"
}

quote_cmd() {
  local arg
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
}

run_cmd() {
  printf '+ '
  quote_cmd "$@"
  if ((DRY_RUN)); then
    return 0
  fi
  "$@"
}

compose_command() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    printf 'docker\0compose\0'
  elif command -v docker-compose >/dev/null 2>&1; then
    printf 'docker-compose\0'
  else
    return 1
  fi
}

load_compose_dirs() {
  local dirs=()
  local line root file dir container_id

  if ((${#COMPOSE_ROOTS[@]} == 0)) && [[ -f "$CONFIG_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line%$'\r'}"
      [[ -z "${line//[[:space:]]/}" ]] && continue
      line="${line/#\~/$HOME}"
      dirs+=("$line")
    done < "$CONFIG_FILE"
  elif ((${#COMPOSE_ROOTS[@]} > 0)); then
    for root in "${COMPOSE_ROOTS[@]}"; do
      [[ -d "$root" ]] || continue
      while IFS= read -r -d '' file; do
        dir="$(dirname "$file")"
        dirs+=("$dir")
      done < <(
        find "$root" -maxdepth 4 -type f \
          \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) \
          -print0 2>/dev/null
      )
    done
  else
    while IFS= read -r container_id; do
      [[ -n "$container_id" ]] || continue
      dir="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container_id" 2>/dev/null || true)"
      [[ -n "$dir" && "$dir" != '<no value>' ]] && dirs+=("$dir")
    done < <(docker ps --filter label=com.docker.compose.project --format '{{.ID}}' 2>/dev/null)
  fi

  if ((${#dirs[@]} == 0)); then
    return 0
  fi
  printf '%s\0' "${dirs[@]}" | sort -zu
}

cmd_check() {
  log "System"
  date -Is
  hostnamectl --static 2>/dev/null || hostname
  uptime || true

  log "Disk"
  df -h / /home 2>/dev/null || df -h

  log "Memory"
  free -h 2>/dev/null || true

  log "Failed systemd units"
  systemctl --failed --no-pager 2>/dev/null || true

  log "Apt"
  if command -v apt >/dev/null 2>&1; then
    local upgradable
    upgradable="$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
    printf 'Upgradable packages: %s\n' "$upgradable"
  else
    printf 'apt not found\n'
  fi

  log "Docker"
  if command -v docker >/dev/null 2>&1; then
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
    docker system df 2>/dev/null || true
  else
    printf 'docker not found\n'
  fi
}

cmd_system() {
  local sudo=()
  if ((EUID != 0)); then
    sudo=(sudo)
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log "Apt update"
    run_cmd "${sudo[@]}" apt-get update
    log "Apt upgrade"
    run_cmd "${sudo[@]}" env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
    log "Apt cleanup"
    run_cmd "${sudo[@]}" apt-get -y autoremove
    run_cmd "${sudo[@]}" apt-get autoclean
  else
    printf 'apt-get not found; skipping apt update.\n' >&2
  fi

  if command -v snap >/dev/null 2>&1; then
    if snap list snap-store >/dev/null 2>&1; then
      log "Snap refresh"
      if pgrep -x snap-store >/dev/null 2>&1; then
        run_cmd "${sudo[@]}" killall snap-store
      fi
      run_cmd "${sudo[@]}" snap refresh snap-store
    else
      printf 'snap-store not installed; skipping Snap Store refresh.\n' >&2
    fi
  fi
}

cmd_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    printf 'docker not found; skipping Docker maintenance.\n' >&2
    return 0
  fi

  local compose=()
  mapfile -d '' -t compose < <(compose_command || true)
  if ((${#compose[@]} == 0)); then
    printf 'No Docker Compose command found; skipping Compose services.\n' >&2
    return 0
  fi

  local dirs=()
  mapfile -d '' -t dirs < <(load_compose_dirs)
  if ((${#dirs[@]} == 0)); then
    printf 'No compose directories found. Add one per line to %s or pass --compose-root.\n' "$CONFIG_FILE" >&2
    return 0
  fi

  local dir
  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    log "Docker Compose: $dir"
    run_cmd "${compose[@]}" --project-directory "$dir" pull
    run_cmd "${compose[@]}" --project-directory "$dir" up -d --remove-orphans
  done
}

cmd_clean() {
  local sudo=()
  if ((EUID != 0)); then
    sudo=(sudo)
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log "Apt cleanup"
    run_cmd "${sudo[@]}" apt-get -y autoremove
    run_cmd "${sudo[@]}" apt-get autoclean
  fi

  if command -v docker >/dev/null 2>&1; then
    log "Docker cleanup"
    run_cmd docker image prune -f
    run_cmd docker system prune -f
    run_cmd docker builder prune -f
  fi

  if command -v snap >/dev/null 2>&1; then
    log "Snap cleanup"
    local snapname revision
    while read -r snapname revision; do
      [[ -n "${snapname:-}" && -n "${revision:-}" ]] || continue
      run_cmd "${sudo[@]}" snap remove "$snapname" --revision="$revision"
    done < <(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')
  fi
}

cmd_all() {
  cmd_check
  cmd_system
  cmd_docker
  cmd_clean
  cmd_check
}

main() {
  local command_name=""
  while (($#)); do
    case "$1" in
      -n|--dry-run)
        DRY_RUN=1
        shift
        ;;
      --compose-root)
        [[ $# -ge 2 ]] || { printf -- '--compose-root requires a directory\n' >&2; exit 2; }
        COMPOSE_ROOTS+=("${2/#\~/$HOME}")
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      check|system|docker|clean|all|help)
        command_name="$1"
        shift
        break
        ;;
      *)
        printf 'Unknown option or command: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if (($#)); then
    printf 'Unexpected extra arguments: %s\n' "$*" >&2
    exit 2
  fi

  case "${command_name:-help}" in
    help)
      usage
      ;;
    check)
      cmd_check
      ;;
    system|docker|clean|all)
      "cmd_$command_name"
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
