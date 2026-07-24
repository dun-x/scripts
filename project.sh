#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
env_file="$script_dir/.env"

BACKUP_STOPPED_COMPOSE=false
BACKUP_COMPOSE_FILE=""
BACKUP_RUNNING_SERVICES=()

usage() {
  cat <<'EOF'
Usage: project <command>

Commands:
  backup      Back up one project directory to a timestamped tar.gz archive.
  restore     Restore one project archive to a project directory.
  help        Show this help.

Config:
  Reads project_folder and backup_folder from ~/Desktop/scripts/.env.

Examples:
  project backup
  project restore
EOF
}

load_env() {
  if [[ ! -f "$env_file" ]]; then
    echo "Missing env file: $env_file" >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$env_file"

  : "${project_folder:?Missing project_folder in $env_file}"
  : "${backup_folder:?Missing backup_folder in $env_file}"
}

find_compose_file() {
  local dir="$1"
  local candidate
  for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "$dir/$candidate" ]]; then
      printf '%s\n' "$dir/$candidate"
      return 0
    fi
  done
  return 1
}

infer_project_name() {
  local archive_base="$1"
  local without_host without_time without_date
  without_host="${archive_base%_*}"
  without_time="${without_host%_*}"
  without_date="${without_time%_*}"
  printf '%s\n' "$without_date"
}

restart_backup_services() {
  if [[ "$BACKUP_STOPPED_COMPOSE" == true && ${#BACKUP_RUNNING_SERVICES[@]} -gt 0 ]]; then
    echo "Restarting previously running Docker Compose services..."
    sudo docker compose --project-directory "$(dirname "$BACKUP_COMPOSE_FILE")" -f "$BACKUP_COMPOSE_FILE" up -d "${BACKUP_RUNNING_SERVICES[@]}"
    BACKUP_STOPPED_COMPOSE=false
  fi
}

cmd_backup() {
  load_env

  local timestamp project_dir custom_path archive_name archive_path
  local -a tar_args
  timestamp="$(date +"%Y%m%d_%H%M%S")"
  project_dir=""
  BACKUP_COMPOSE_FILE=""
  BACKUP_STOPPED_COMPOSE=false
  BACKUP_RUNNING_SERVICES=()
  trap restart_backup_services EXIT

  read -r -p "Enter project directory to backup (press Enter to choose from list): " custom_path
  custom_path="${custom_path/#\~/$HOME}"

  if [[ -n "$custom_path" ]]; then
    if [[ ! -d "$custom_path" ]]; then
      echo "Invalid directory path: $custom_path" >&2
      exit 1
    fi
    project_dir="$(cd "$custom_path" && pwd -P)"
  else
    echo "List of project directories:"
    local -a project_dirs
    mapfile -t project_dirs < <(find "$project_folder" -mindepth 1 -maxdepth 1 -type d | sort)

    if [[ ${#project_dirs[@]} -eq 0 ]]; then
      echo "No project directories found in $project_folder" >&2
      exit 1
    fi

    local i chosen_identifier
    for i in "${!project_dirs[@]}"; do
      printf '%s: %s\n' "$((i + 1))" "$(basename "${project_dirs[$i]}")"
    done

    read -r -p "Enter the identifier of the directory to backup: " chosen_identifier
    if ! [[ "$chosen_identifier" =~ ^[0-9]+$ ]] || ((chosen_identifier < 1 || chosen_identifier > ${#project_dirs[@]})); then
      echo "Invalid identifier: $chosen_identifier" >&2
      exit 1
    fi
    project_dir="${project_dirs[$((chosen_identifier - 1))]}"
  fi

  if BACKUP_COMPOSE_FILE="$(find_compose_file "$project_dir")"; then
    mapfile -t BACKUP_RUNNING_SERVICES < <(
      sudo docker compose --project-directory "$project_dir" -f "$BACKUP_COMPOSE_FILE" ps --services --filter status=running \
        | sed '/^[[:space:]]*$/d'
    )
    if [[ ${#BACKUP_RUNNING_SERVICES[@]} -gt 0 ]]; then
      echo "Stopping Docker Compose services before backup: ${BACKUP_RUNNING_SERVICES[*]}"
      sudo docker compose --project-directory "$project_dir" -f "$BACKUP_COMPOSE_FILE" stop "${BACKUP_RUNNING_SERVICES[@]}"
      BACKUP_STOPPED_COMPOSE=true
    else
      echo "No running Docker Compose services found."
    fi
  fi

  mkdir -p "$backup_folder"
  archive_name="$(basename "$project_dir")_${timestamp}_$(hostname).tar.gz"
  archive_path="$backup_folder/$archive_name"

  tar_args=(-cpzf "$archive_path" -C "$project_dir")
  if [[ -f "$project_dir/.bk_ignore" ]]; then
    tar_args+=(--exclude-from="$project_dir/.bk_ignore")
  fi

  echo "Creating archive: $archive_path"
  sudo tar "${tar_args[@]}" .
  sudo chown "$(id -u):$(id -g)" "$archive_path"

  echo "Archive created at $archive_path"
  restart_backup_services
  trap - EXIT
}

cmd_restore() {
  load_env

  local timestamp chosen_identifier chosen_file chosen_file_name project_name default_project_dir
  local user_provided_path project_dir parent_dir old_project_dir compose_file start_compose
  timestamp="$(date +"%Y%m%d_%H%M%S")"

  if [[ ! -d "$backup_folder" ]]; then
    echo "Backup folder does not exist: $backup_folder" >&2
    exit 1
  fi

  echo "List of *.tar.gz files in backup folder:"
  local -a backup_files
  mapfile -t backup_files < <(find "$backup_folder" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)

  if [[ ${#backup_files[@]} -eq 0 ]]; then
    echo "No *.tar.gz backup files found in $backup_folder" >&2
    exit 1
  fi

  local i
  for i in "${!backup_files[@]}"; do
    printf '%s: %s\n' "$((i + 1))" "$(basename "${backup_files[$i]}")"
  done

  read -r -p "Enter the identifier of the backup file to restore: " chosen_identifier
  if ! [[ "$chosen_identifier" =~ ^[0-9]+$ ]] || ((chosen_identifier < 1 || chosen_identifier > ${#backup_files[@]})); then
    echo "Invalid identifier: $chosen_identifier" >&2
    exit 1
  fi

  chosen_file="${backup_files[$((chosen_identifier - 1))]}"
  chosen_file_name="$(basename "$chosen_file" .tar.gz)"
  project_name="$(infer_project_name "$chosen_file_name")"

  default_project_dir="$project_folder/$project_name"
  read -r -p "Enter extraction path (default: $default_project_dir): " user_provided_path
  user_provided_path="${user_provided_path/#\~/$HOME}"

  if [[ -n "$user_provided_path" ]]; then
    project_dir="$user_provided_path"
  else
    project_dir="$default_project_dir"
  fi

  parent_dir="$(dirname "$project_dir")"
  mkdir -p "$parent_dir"

  if ! sudo tar -tzf "$chosen_file" >/dev/null; then
    echo "Archive validation failed: $chosen_file" >&2
    exit 1
  fi

  old_project_dir="${project_dir}_${timestamp}"
  if [[ -d "$project_dir" ]]; then
    if compose_file="$(find_compose_file "$project_dir")"; then
      echo "Stopping existing Docker Compose services before moving current project..."
      sudo docker compose -f "$compose_file" stop || true
    fi
    sudo mv "$project_dir" "$old_project_dir"
    echo "Renamed existing directory to $old_project_dir"
  fi

  sudo mkdir -p "$project_dir"
  echo "Extracting $chosen_file to $project_dir"
  sudo tar -xpzf "$chosen_file" -C "$project_dir"

  echo "File extracted to $project_dir"

  if compose_file="$(find_compose_file "$project_dir")"; then
    read -r -p "Start restored Docker Compose services now? [y/N]: " start_compose
    if [[ "$start_compose" =~ ^[Yy]$ ]]; then
      sudo docker compose -f "$compose_file" up -d
    fi
  fi
}

main() {
  local command_name="${1:-help}"
  [[ $# -gt 0 ]] && shift || true

  case "$command_name" in
    backup)
      [[ $# -eq 0 ]] || { echo "Unexpected extra arguments: $*" >&2; exit 2; }
      cmd_backup
      ;;
    restore)
      [[ $# -eq 0 ]] || { echo "Unexpected extra arguments: $*" >&2; exit 2; }
      cmd_restore
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "Unknown command: $command_name" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
