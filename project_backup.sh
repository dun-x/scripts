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
chosen_dir="${subdirs[$chosen_identifier]}"
if [ -z "$chosen_dir" ]; then
    echo "Invalid identifier. Exiting."
    exit 1
fi

mkdir -p "$backup_folder"
archive_name="$(basename "$chosen_dir")_$timestamp.tar.gz"
sudo tar -cvpzf "$backup_folder/$archive_name" -C "$chosen_dir" .
sudo chown dunx:dunx "$backup_folder/$archive_name"
echo "Archive created at $backup_folder/$archive_name"
