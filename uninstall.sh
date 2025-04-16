#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
# Temporarily disable nounset for checking SUDO_USER which might be unbound
set +u
# Prevent errors in pipelines from being masked.
set -o pipefail

# --- Configuration (Should match install.sh) ---
APP_NAME="servicemanager"
APP_DIR="/opt/${APP_NAME}"
SERVICE_FILE_NAME="${APP_NAME}.service"
SERVICE_FILE_PATH_DEST="/etc/systemd/system/${SERVICE_FILE_NAME}"
SUDOERS_FILE_NAME="90-${APP_NAME}" # File in /etc/sudoers.d/
SUDOERS_FILE_PATH="/etc/sudoers.d/${SUDOERS_FILE_NAME}"
FLASK_PORT="5001" # Needed for alias removal message
# Re-enable nounset
set -u
# --- End Configuration ---

# --- Helper Functions ---
print_info() {
    echo "[INFO] $1"
}

print_warning() {
    echo "[WARNING] $1"
}

print_error() {
    echo "[ERROR] $1" >&2
    # Don't exit immediately on error during uninstall, try to continue
}

confirm() {
    # call with a prompt string or use a default
    read -r -p "${1:-Are you sure? [y/N]} " response
    case "$response" in
    [yY][eE][sS] | [yY])
        true
        ;;
    *)
        false
        ;;
    esac
}

# --- Pre-flight Checks ---
# 1. Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (or with sudo)." >&2
    exit 1
fi

# --- Main Uninstallation ---
echo "-------------------------------------"
echo "--- Service Manager Uninstaller ---"
echo "-------------------------------------"
echo "This script will attempt to remove:"
echo "  - The systemd service: ${SERVICE_FILE_NAME}"
echo "  - The application files: ${APP_DIR}"
echo "  - The sudoers rule: ${SUDOERS_FILE_PATH}"
echo "  - The bash alias (from the invoking user's .bashrc if found)"
echo ""

if ! confirm "Do you wish to proceed with uninstallation? [y/N]"; then
    echo "Uninstallation cancelled."
    exit 0
fi

# 1. Stop the Service
print_info "Attempting to stop service ${SERVICE_FILE_NAME}..."
if systemctl is-active --quiet "${SERVICE_FILE_NAME}"; then
    systemctl stop "${SERVICE_FILE_NAME}" || print_error "Failed to stop service (maybe already stopped?)."
    print_info "Service stopped."
else
    print_info "Service already stopped or not found."
fi

# 2. Disable the Service
print_info "Attempting to disable service ${SERVICE_FILE_NAME}..."
if systemctl is-enabled --quiet "${SERVICE_FILE_NAME}"; then
    systemctl disable "${SERVICE_FILE_NAME}" || print_error "Failed to disable service."
    print_info "Service disabled."
else
    print_info "Service already disabled or not found."
fi

# 3. Remove Systemd Service File
print_info "Attempting to remove systemd file: ${SERVICE_FILE_PATH_DEST}..."
if [[ -f "${SERVICE_FILE_PATH_DEST}" ]]; then
    rm -f "${SERVICE_FILE_PATH_DEST}"
    print_info "Systemd file removed."
    # Reload daemon only if file was actually removed
    print_info "Reloading systemd daemon..."
    systemctl daemon-reload || print_error "Failed to reload systemd daemon."
else
    print_info "Systemd file not found."
fi

# 4. Remove Sudoers File
print_info "Attempting to remove sudoers file: ${SUDOERS_FILE_PATH}..."
if [[ -f "${SUDOERS_FILE_PATH}" ]]; then
    rm -f "${SUDOERS_FILE_PATH}"
    print_info "Sudoers file removed."
else
    print_info "Sudoers file not found."
fi

# 5. Remove Application Directory
print_info "Attempting to remove application directory: ${APP_DIR}..."
if [[ -d "${APP_DIR}" ]]; then
    if confirm "      CONFIRM: Delete directory ${APP_DIR} and all its contents? [y/N]"; then
        rm -rf "${APP_DIR}"
        print_info "Application directory removed."
    else
        print_warning "Skipping removal of ${APP_DIR}."
    fi
else
    print_info "Application directory not found."
fi

# 6. Remove Bash Alias (Best effort)
# Temporarily disable nounset for SUDO_USER
set +u
ORIGINAL_USER=${SUDO_USER:-$(logname 2>/dev/null || echo "")}
# Re-enable nounset
set -u

if [[ -n "$ORIGINAL_USER" && "$ORIGINAL_USER" != "root" ]]; then
    USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
    BASHRC_PATH="${USER_HOME}/.bashrc"

    if [[ -f "$BASHRC_PATH" ]]; then
        ALIAS_CMD_PATTERN="alias ${APP_NAME}='xdg-open http://localhost:${FLASK_PORT} &> /dev/null'" # Pattern to match
        ALIAS_COMMENT_PATTERN="# Alias for Web Service Manager"                                      # Comment pattern

        print_info "Attempting to remove alias for user ${ORIGINAL_USER} from ${BASHRC_PATH}..."
        # Check if alias exists using grep before attempting sed
        if grep -Fq "$ALIAS_CMD_PATTERN" "$BASHRC_PATH"; then
            # Use sed to delete the alias line and the comment line above it (if it exists)
            # Be cautious with sed -i, maybe make a backup first?
            # This attempts to delete the alias line and the comment line immediately preceding it
            sed -i.bak -e "\@${ALIAS_CMD_PATTERN}@d" -e "\@${ALIAS_COMMENT_PATTERN}@d" "$BASHRC_PATH"

            # Check if sed actually removed it (basic check)
            if ! grep -Fq "$ALIAS_CMD_PATTERN" "$BASHRC_PATH"; then
                print_info "Alias likely removed from ${BASHRC_PATH}. Backup created: ${BASHRC_PATH}.bak"
                print_info "User ${ORIGINAL_USER} should run 'source ${BASHRC_PATH}' or open a new terminal."
            else
                print_warning "Could not automatically remove alias using sed. Please check ${BASHRC_PATH} and remove manually:"
                echo "  ${ALIAS_COMMENT_PATTERN}"
                echo "  ${ALIAS_CMD_PATTERN}"
            fi
        else
            print_info "Alias not found in ${BASHRC_PATH}."
        fi
    else
        print_warning "Could not find ${BASHRC_PATH} for user ${ORIGINAL_USER}. Check manually if alias exists."
    fi
else
    print_warning "Could not determine original non-root user. Please check your ~/.bashrc manually for the alias:"
    echo "  # Alias for Web Service Manager"
    echo "  alias ${APP_NAME}='xdg-open http://localhost:${FLASK_PORT} &> /dev/null'"
fi

echo ""
echo "[SUCCESS] Uninstallation process finished."
echo "Please review the output above for any warnings or manual steps required."
echo ""

exit 0
