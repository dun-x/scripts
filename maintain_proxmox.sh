#!/usr/bin/env bash
set -Eeuo pipefail

DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: maintain_proxmox [options] <command>

Commands:
  check       Show Proxmox/PBS health status.
  system      Update apt packages safely, without rebooting.
  clean       Remove safe apt garbage and old journal logs.
  safe        Run system, clean, then check.
  all         Alias for safe.
  help        Show this help.

Options:
  -n, --dry-run          Print commands that would run, without changing state.
  -h, --help             Show this help.

Notes:
  - Intended for Proxmox VE / Proxmox Backup Server hosts running as root.
  - Does not reboot, upgrade major versions, change repositories, touch VM/CT state,
    prune backups, run garbage collection, or run Docker maintenance.
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

require_root() {
  if ((EUID != 0)); then
    printf 'maintain_proxmox must run as root.\n' >&2
    exit 1
  fi
}

host_kind() {
  if command -v pveversion >/dev/null 2>&1; then
    printf 'pve'
  elif command -v proxmox-backup-manager >/dev/null 2>&1; then
    printf 'pbs'
  else
    printf 'linux'
  fi
}

cmd_check() {
  local kind
  kind="$(host_kind)"

  log "System"
  date -Is
  hostnamectl --static 2>/dev/null || hostname
  printf 'Host kind: %s\n' "$kind"
  uptime || true
  uname -a || true

  log "Disk"
  df -h / /var/lib/vz /var/lib/proxmox-backup /mnt/datastore 2>/dev/null || df -h /

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

  log "Kernel/Reboot"
  if [[ -e /var/run/reboot-required ]]; then
    printf 'Reboot required: yes\n'
    if [[ -f /var/run/reboot-required.pkgs ]]; then
      sed 's/^/reboot package: /' /var/run/reboot-required.pkgs || true
    fi
  else
    printf 'Reboot required: no\n'
  fi

  if [[ "$kind" == "pve" ]]; then
    log "Proxmox VE"
    pveversion 2>/dev/null || true
    pveversion -v 2>/dev/null | sed -n '1,25p' || true

    log "PVE cluster/storage"
    pvecm status 2>/dev/null | sed -n '1,80p' || true
    pvesm status 2>/dev/null || true

    log "PVE guests"
    qm list 2>/dev/null || true
    pct list 2>/dev/null || true

    log "PVE backup jobs"
    if command -v pvesh >/dev/null 2>&1; then
      pvesh get /cluster/backup --output-format yaml 2>/dev/null || true
    fi
  elif [[ "$kind" == "pbs" ]]; then
    log "Proxmox Backup Server"
    proxmox-backup-manager versions 2>/dev/null | sed -n '1,40p' || true

    log "PBS datastores"
    proxmox-backup-manager datastore list --output-format json-pretty 2>/dev/null || proxmox-backup-manager datastore list 2>/dev/null || true

    log "PBS jobs"
    proxmox-backup-manager prune-job list --output-format json-pretty 2>/dev/null || proxmox-backup-manager prune-job list 2>/dev/null || true
    proxmox-backup-manager garbage-collection job list --output-format json-pretty 2>/dev/null || proxmox-backup-manager garbage-collection job list 2>/dev/null || true
    proxmox-backup-manager verify-job list --output-format json-pretty 2>/dev/null || proxmox-backup-manager verify-job list 2>/dev/null || true
    proxmox-backup-manager sync-job list --output-format json-pretty 2>/dev/null || proxmox-backup-manager sync-job list 2>/dev/null || true
  fi
}

cmd_system() {
  require_root
  if command -v apt-get >/dev/null 2>&1; then
    log "Apt update"
    run_cmd apt-get update
    log "Apt upgrade"
    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
  else
    printf 'apt-get not found; skipping apt update.\n' >&2
  fi
}

cmd_clean() {
  require_root
  if command -v apt-get >/dev/null 2>&1; then
    log "Apt cleanup"
    run_cmd apt-get -y autoremove
    run_cmd apt-get autoclean
  fi

  if command -v journalctl >/dev/null 2>&1; then
    log "Journal cleanup"
    run_cmd journalctl --vacuum-time=14d
  fi
}

cmd_safe() {
  cmd_system
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
      -h|--help|help)
        usage
        return 0
        ;;
      check|system|clean|safe|all)
        command_name="$1"
        shift
        ;;
      *)
        printf 'Unknown argument: %s\n' "$1" >&2
        usage >&2
        return 2
        ;;
    esac
  done

  if [[ -z "$command_name" ]]; then
    usage >&2
    return 2
  fi

  case "$command_name" in
    check) cmd_check ;;
    system) cmd_system ;;
    clean) cmd_clean ;;
    safe|all) cmd_safe ;;
  esac
}

main "$@"
