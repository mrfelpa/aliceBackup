#!/usr/bin/env sh
##############################################################################
# aliceBackup - Secure and Scalable Backup Solution
# AUTHOR: Jefferson 'Slackjeff' Carneiro <slackjeff@riseup.net>
# AUTHOR: Mr Felpa
# LICENSE: GPLv3
##############################################################################
set -euo pipefail

#----------------------------------------------------------------------------#
# Configuration
#----------------------------------------------------------------------------#

PRG_VERSION="0.4"
DATE=$(date +"%Y%m%d_%H%M%S")
ALICE_CONFIGURE_DIR="/etc/alicebackup"
ALICE_CONFIGURE_FILE="alicebackup.conf"
DAY_OF_THE_WEEK=$(date +%u)
MACHINE_NAME=$(hostname -s)
LOG_FILE="/var/log/alicebackup.log"
export LC_ALL=C LANG=C

# Ensure secure permissions for configuration and logs
umask 077
[ ! -d "$ALICE_CONFIGURE_DIR" ] && mkdir -p "$ALICE_CONFIGURE_DIR"
[ ! -f "$LOG_FILE" ] && touch "$LOG_FILE" && chmod 600 "$LOG_FILE"

# Load configuration
if [ -f "${ALICE_CONFIGURE_DIR}/${ALICE_CONFIGURE_FILE}" ]; then
    . "${ALICE_CONFIGURE_DIR}/${ALICE_CONFIGURE_FILE}"
else
    echo "Configuration file not found. Please run --configure-me first." >&2
    exit 1
fi

#----------------------------------------------------------------------------#
# Functions
#----------------------------------------------------------------------------#

# Logging with levels and log rotation
LOG() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # Rotate logs if they exceed 10MB
    local log_size=$(stat -c%s "$LOG_FILE")
    if [ "$log_size" -gt 10485760 ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
        touch "$LOG_FILE"
        chmod 600 "$LOG_FILE"
    fi
}

# Validate user input to prevent command injection
VALIDATE_INPUT() {
    local input=$1
    if echo "$input" | grep -qE '[;&|]'; then
        LOG "ERROR" "Invalid input detected: $input"
        DIE "Invalid input. Special characters are not allowed."
    fi
}

# Error handling with secure feedback
DIE() {
    local message=$1
    LOG "ERROR" "$message"
    echo "Error: An issue occurred. Please check the logs for details." >&2
    exit 1
}

# Full backup
FULL_BACKUP() {
    local sourceDirectory=$1
    local exclude=$2
    LOG "INFO" "Starting full backup."
    tar $exclude --create --file="${backupLocalDir}/backup-full-$MACHINE_NAME-$DATE.tar.gz" --listed-incremental="${backupLocalDir}/backup-full-$MACHINE_NAME.snar" $sourceDirectory
    LOG "INFO" "Full backup completed."
}

# Differential backup
DIFFERENTIAL_BACKUP() {
    local sourceDirectory=$1
    local exclude=$2
    LOG "INFO" "Starting differential backup."
    local count=$(ls -1 ${backupLocalDir}/backup-diff-*.snar 2>/dev/null | wc -l)
    count=$((count+1))
    cp "${backupLocalDir}/backup-full-$MACHINE_NAME.snar" "${backupLocalDir}/backup-diff-$MACHINE_NAME-${count}.snar"
    tar $exclude --create --file="${backupLocalDir}/backup-diff-$MACHINE_NAME-$DATE.tar.gz" --listed-incremental="${backupLocalDir}/backup-diff-$MACHINE_NAME-${count}.snar" $sourceDirectory
    LOG "INFO" "Differential backup completed."
}

# Encrypt backup files
ENCRYPT_BACKUP() {
    local file=$1
    LOG "INFO" "Encrypting backup file: $file"
    gpg --batch --yes --passphrase "$ENCRYPTION_KEY" --symmetric --cipher-algo AES256 -o "${file}.gpg" "$file" || DIE "Failed to encrypt backup."
    rm -f "$file" # Remove unencrypted file
    LOG "INFO" "Backup file encrypted: ${file}.gpg"
}

# Parallel transfer using rsync with resource limits
PARALLEL_RSYNC() {
    local sendServer=$1
    local remoteDirectory=$2
    LOG "INFO" "Starting parallel rsync transfer."
    rsync $RSYNC_CMD --exclude '*.snar' . "${sendServer}:${remoteDirectory}" -e "ssh -p $SSH_PORT -i $ID_RSA" --bwlimit=10240 || DIE "Failed to transfer backup."
    LOG "INFO" "Parallel rsync transfer completed."
}

# Configure script interactively
CONFIGURE_ME() {
    LOG "INFO" "Starting configuration wizard."
    while :; do
        sshUserConfigureMe=$(whiptail --title "SSH USER" --inputbox "SSH user for remote backup:" 10 70 3>&1 1>&2 2>&3)
        VALIDATE_INPUT "$sshUserConfigureMe"
        sshConfigureMe=$(whiptail --title "SSH SERVER" --inputbox "IP or domain of your SSH server:" 10 70 3>&1 1>&2 2>&3)
        VALIDATE_INPUT "$sshConfigureMe"
        sshPortConfigureMe=$(whiptail --title "SSH PORT" --inputbox "SSH port (default: 22):" 10 70 3>&1 1>&2 2>&3)
        VALIDATE_INPUT "$sshPortConfigureMe"
        idRsaConfigureMe=$(whiptail --title "SSH KEY" --inputbox "Full path to your SSH private key:" 10 70 3>&1 1>&2 2>&3)
        VALIDATE_INPUT "$idRsaConfigureMe"
        encryptionKeyConfigureMe=$(whiptail --title "ENCRYPTION KEY" --inputbox "Passphrase for encryption:" 10 70 3>&1 1>&2 2>&3)
        VALIDATE_INPUT "$encryptionKeyConfigureMe"

        if whiptail --title "Confirm" --yesno "Are all details correct?" 10 70; then
            break
        fi
    done

    # Save configuration
    cat <<EOF > "${ALICE_CONFIGURE_DIR}/${ALICE_CONFIGURE_FILE}"
# SSH Configuration
SSH_USER="$sshUserConfigureMe"
SSH_SERVER="$sshConfigureMe"
SSH_PORT="${sshPortConfigureMe:-22}"
ID_RSA="$idRsaConfigureMe"

# Encryption
ENCRYPTION_KEY="$encryptionKeyConfigureMe"

# Directories
backupLocalDir="/backup"
backupRemoteDir="/backupServer"

# Resource Limits
RSYNC_CMD="--archive --verbose --human-readable --compress"
EOF

    LOG "INFO" "Configuration saved."
    echo "Configuration saved to ${ALICE_CONFIGURE_DIR}/${ALICE_CONFIGURE_FILE}."
}

#----------------------------------------------------------------------------#
# Main
#----------------------------------------------------------------------------#

# Check for root privileges
[ $(id -u) -ne 0 ] && DIE "This script must be run as root."

# Parse arguments
if [ "$#" -eq 0 ]; then
    echo "Usage: $0 --source=/path/to/backup [--exclude-this=/path/to/exclude] [--configure-me]"
    exit 1
fi

# Backup logic
if [ "$DAY_OF_THE_WEEK" -eq 7 ]; then
    FULL_BACKUP "$sourceDirectory" "$excludes"
else
    DIFFERENTIAL_BACKUP "$sourceDirectory" "$excludes"
fi

# Encrypt backup
ENCRYPT_BACKUP "${backupLocalDir}/backup-*-$MACHINE_NAME-$DATE.tar.gz"

# Transfer backup
PARALLEL_RSYNC "${SSH_USER}@${SSH_SERVER}" "$backupRemoteDir"

LOG "INFO" "Backup process completed successfully."
echo "Backup completed successfully."
