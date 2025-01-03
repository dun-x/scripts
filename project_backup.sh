#!/bin/bash
user=$(whoami)
source /home/$USER/Desktop/scripts/parameter.sh

timestamp=$(date +"%Y%m%d_%H%M%S")

# Step 1: Display all subdirectories' names of the Project folder with assigned identifiers
echo "List of subdirectories in Project:"
declare -A subdirs
identifier=1

for dir in "$project_folder"/*; do
    if [ -d "$dir" ]; then
        subdirs["$identifier"]="$dir"
        dir_name="$(basename "$dir")"
        echo "$identifier: $dir_name"
        ((identifier++))
    fi
done

# Step 2: User inputs an identifier
read -p "Enter the identifier of the directory you want to choose: " chosen_identifier

# Step 3: Determine the chosen directory and create a compressed archive
project_dir="${subdirs[$chosen_identifier]}"
if [ -z "$project_dir" ]; then
    echo "Invalid identifier. Exiting."
    exit 1
fi

# Check for docker-compose.yml and stop containers if found
if [ -f "$project_dir/docker-compose.yml" ]; then
    sudo docker compose -f "$project_dir/docker-compose.yml" stop
    echo "Docker containers stopped."
fi

mkdir -p "$backup_folder"
archive_name="$(basename "$project_dir")_"$timestamp"_$(hostname).tar.gz"

if [ -f "$project_dir/.bk_ignore" ]; then
    sudo tar -cvpzf "$backup_folder/$archive_name" -C "$project_dir" --exclude-from="$project_dir/.bk_ignore" .
else
    sudo tar -cvpzf "$backup_folder/$archive_name" -C "$project_dir" .
fi

sudo chown dunx:dunx "$backup_folder/$archive_name"
echo "Archive created at $backup_folder/$ls -archive_name"

# Check for docker-compose.yml and stop containers if found
if [ -f "$project_dir/docker-compose.yml" ]; then
    sudo docker compose -f "$project_dir/docker-compose.yml" start
    echo "Docker containers started"
fi