#!/bin/bash
user=$(whoami)
source /home/$USER/Desktop/scripts/.env

timestamp=$(date +"%Y%m%d_%H%M%S")

# Step 1: Display all *.tar.gz files in Sync directory with assigned identifiers
echo "List of *.tar.gz files in Sync directory:"
declare -A files
identifier=1

shopt -s dotglob nullglob
for file in "$backup_folder"/*.tar.gz; do
    if [ -f "$file" ]; then
        files["$identifier"]="$file"
        file_name="$(basename "$file")"
        echo "$identifier: $file_name"
        ((identifier++))
    fi
done
shopt -u dotglob nullglob

# Step 2: User inputs an identifier
read -p "Enter the identifier of the file you want to choose: " chosen_identifier

# Step 3: Determine the chosen file and process accordingly
chosen_file="${files[$chosen_identifier]}"
if [ -z "$chosen_file" ]; then
    echo "Invalid identifier. Exiting."
    exit 1
fi

chosen_file_name="$(basename "$chosen_file" .tar.gz)"
project_name=$(echo "$chosen_file_name" | cut -d'_' -f1)

# Propose extraction path to user
default_project_dir="$project_folder/$project_name"
read -p "Enter extraction path (default: $default_project_dir): " user_provided_path

# Use the user-provided path if it's not empty, otherwise use the calculated path
if [ -n "$user_provided_path" ]; then
    project_dir="$user_provided_path"
else
    project_dir="$default_project_dir"
fi
old_project_dir="${project_dir}_${timestamp}"

if [ -d "$project_dir" ]; then
    sudo mv "$project_dir" "${old_project_dir}"
    echo "Renamed existing directory to ${old_project_dir}."
fi

mkdir -p "$project_dir"
sudo tar -xpvzf "$chosen_file" -C "$project_dir"

echo "File extracted to $project_dir."
