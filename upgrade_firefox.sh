#!/bin/bash
user=$(whoami)
source /home/$USER/Desktop/scripts/parameter.sh

# Step 1: Display all *.tar.gz files in Sync directory with assigned identifiers
echo "List of *.tar.bz2 files in Sync directory:"
declare -A files
identifier=1

for file in "$download_folder"/firefox*.tar.bz2; do
    if [ -f "$file" ]; then
        files["$identifier"]="$file"
        file_name="$(basename "$file")"
        echo "$identifier: $file_name"
        ((identifier++))
    fi
done

# Step 2: User inputs an identifier
read -p "Enter the identifier of the file you want to choose: " chosen_identifier

# Step 3: Determine the chosen file and process accordingly
chosen_file="${files[$chosen_identifier]}"
if [ -z "$chosen_file" ]; then
    echo "Invalid identifier. Exiting."
    exit 1
fi

chosen_file_name="$(basename "$chosen_file" .tar.bz2)"

if [ -d /opt/firefox_old ]; then
    sudo rm -rf /opt/firefox_old
    echo "Removed existing firefox_old directory."
fi

if [ -d /opt/firefox ]; then
    sudo mv /opt/firefox /opt/firefox_old
    echo "Backup existing firefox to firefox_old."
fi

sudo mkdir -p /opt
cd ~/Downloads/
sudo tar xjf $chosen_file
sudo mv firefox /opt/firefox

echo "Firefox upgraded."
