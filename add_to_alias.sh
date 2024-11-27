#!/bin/bash
user=$(whoami)
script_directory=/home/$USER/Desktop/scripts

# Đoạn mã cần thêm vào .bashrc
CUSTOM_SCRIPTS="# <<< Custom Scripts >>>
alias sudo='sudo '
script_directory=$script_directory
for script_file in \"\$script_directory\"/*; do
    if [ -f \"\$script_file\" ]; then
        script_name=\$(basename \"\$script_file\")
        alias_name=\$(echo \"\$script_name\" | sed 's/ /_/g' | sed 's/\\..*\$//')
        if ! alias \"\$alias_name\" &> /dev/null; then
            alias \"\$alias_name\"=\"\$script_file\"
        fi
    fi
done
# <<< Custom Scripts >>>"

# Thêm đoạn mã vào cuối file .bashrc
echo "$CUSTOM_SCRIPTS" >> ~/.bashrc

# Thông báo hoàn thành
echo "Đoạn mã đã được thêm vào cuối file .bashrc"
