#!/bin/bash

# --- Colors for prettier output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Exit immediately if a command exits with a non-zero status.
set -e
# Prevent errors in pipelines from being masked.
set -o pipefail

# --- Configuration (Should match install.sh) ---
APP_NAME="servicemanager"
APP_DIR="/opt/${APP_NAME}"
SERVICE_FILE_NAME="${APP_NAME}.service"
SERVICE_FILE_PATH_DEST="/etc/systemd/system/${SERVICE_FILE_NAME}"
SUDOERS_FILE_NAME="90-${APP_NAME}" # File in /etc/sudoers.d/
SUDOERS_FILE_PATH="/etc/sudoers.d/${SUDOERS_FILE_NAME}"
FLASK_PORT="5001"       # Needed for alias removal message
VENV_DIR=".venv"        # Virtual environment directory (match install.sh)
SERVICE_USER="www-data" # Match the service user in install.sh
LOG_FILE="/tmp/${APP_NAME}_uninstall_$(date +%Y%m%d_%H%M%S).log"

# --- Helper Functions ---
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

print_info() {
    log "${BLUE}[INFO]${NC} $1"
}

print_success() {
    log "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    log "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    log "${RED}[ERROR]${NC} $1" >&2
    # Don't exit immediately on error during uninstall, try to continue
}

print_step() {
    log "\n${BOLD}${BLUE}== $1 ==${NC}"
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

cleanup_on_exit() {
    print_info "Uninstallation process complete. Log saved to: $LOG_FILE"
}
trap cleanup_on_exit EXIT

# --- Pre-flight Checks ---
# 1. Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} This script must be run as root (or with sudo)." >&2
    exit 1
fi

# Initialize log file with a header
echo "Service Manager Uninstall Log - $(date)" >"$LOG_FILE"
echo "=======================================" >>"$LOG_FILE"

# --- Main Uninstallation ---
print_step "Service Manager Uninstaller"
echo -e "-------------------------------------"
echo -e "--- Service Manager Uninstaller ---"
echo -e "-------------------------------------"
echo -e "This script will attempt to completely remove:"
echo -e "  - The systemd service: ${SERVICE_FILE_NAME}"
echo -e "  - The application files: ${APP_DIR}"
echo -e "  - The Python virtual environment"
echo -e "  - The sudoers rule: ${SUDOERS_FILE_PATH}"
echo -e "  - Any bash/zsh aliases"
echo -e "  - Process cleanup if any are still running"
echo -e ""

if ! confirm "Do you wish to proceed with complete uninstallation? [y/N]"; then
    echo -e "Uninstallation cancelled."
    exit 0
fi

# 0. Check if any processes are still running
print_step "Checking for Running Processes"
if pgrep -f "${APP_DIR}/app.py" >/dev/null; then
    print_warning "Found processes still running for ${APP_NAME}."
    if confirm "Would you like to kill these processes before uninstalling? [y/N]"; then
        pkill -f "${APP_DIR}/app.py" || print_warning "Failed to kill all processes. Some may still be running."
        print_info "Processes terminated."
        # Short sleep to allow processes to fully terminate
        sleep 1
    else
        print_warning "Continuing with processes still running. This may cause issues."
    fi
else
    print_info "No running processes found for ${APP_NAME}."
fi

# 1. Stop the Service
print_step "Stopping Service"
print_info "Attempting to stop service ${SERVICE_FILE_NAME}..."
if systemctl is-active --quiet "${SERVICE_FILE_NAME}" 2>/dev/null; then
    systemctl stop "${SERVICE_FILE_NAME}" || {
        print_error "Failed to stop service (maybe already stopped?)."
        systemctl kill "${SERVICE_FILE_NAME}" 2>/dev/null || true
    }
    print_info "Service stop attempted."

    # Double-check service is actually stopped
    sleep 1
    if systemctl is-active --quiet "${SERVICE_FILE_NAME}" 2>/dev/null; then
        print_warning "Service appears to still be running. Will proceed anyway."
    else
        print_success "Service confirmed stopped."
    fi
else
    print_info "Service already stopped or not found."
fi

# 2. Disable the Service
print_step "Disabling Service"
print_info "Attempting to disable service ${SERVICE_FILE_NAME}..."
if systemctl is-enabled --quiet "${SERVICE_FILE_NAME}" 2>/dev/null; then
    systemctl disable "${SERVICE_FILE_NAME}" || print_error "Failed to disable service."
    print_success "Service disabled."
else
    print_info "Service already disabled or not found."
fi

# 3. Remove Systemd Service File
print_step "Removing Systemd Service File"
print_info "Attempting to remove systemd file: ${SERVICE_FILE_PATH_DEST}..."
if [[ -f "${SERVICE_FILE_PATH_DEST}" ]]; then
    rm -f "${SERVICE_FILE_PATH_DEST}" || print_error "Failed to remove systemd service file."
    print_success "Systemd file removed."
    # Reload daemon only if file was actually removed
    print_info "Reloading systemd daemon..."
    systemctl daemon-reload || print_error "Failed to reload systemd daemon."
else
    print_info "Systemd file not found."
fi

# Check for any other files that might have been created
OTHER_SERVICE_PATHS=(
    "/etc/systemd/system/${SERVICE_FILE_NAME}.d"
    "/etc/systemd/system/multi-user.target.wants/${SERVICE_FILE_NAME}"
)

for path in "${OTHER_SERVICE_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
        print_info "Found additional systemd file/directory: $path"
        rm -rf "$path" && print_success "Removed: $path" || print_error "Failed to remove: $path"
    fi
done

# 4. Remove Sudoers File
print_step "Removing Sudoers Configuration"
print_info "Attempting to remove sudoers file: ${SUDOERS_FILE_PATH}..."
if [[ -f "${SUDOERS_FILE_PATH}" ]]; then
    rm -f "${SUDOERS_FILE_PATH}" || print_error "Failed to remove sudoers file."
    print_success "Sudoers file removed."
else
    print_info "Sudoers file not found."
fi

# 5. Remove Application Directory including virtual environment
print_step "Removing Application Files"
print_info "Checking application directory: ${APP_DIR}..."
if [[ -d "${APP_DIR}" ]]; then
    if confirm "      CONFIRM: Delete directory ${APP_DIR} and all its contents? [y/N]"; then
        # First check if venv exists and deactivate if active
        VENV_PATH="${APP_DIR}/${VENV_DIR}"
        if [[ -d "$VENV_PATH" ]]; then
            print_info "Found Python virtual environment at $VENV_PATH"
            # No need to deactivate as we're in a separate script process
        fi

        # Use force removal with verbose output to log what's being removed
        rm -rf "${APP_DIR}" || print_error "Failed to remove application directory."
        if [[ ! -d "${APP_DIR}" ]]; then
            print_success "Application directory completely removed."
        else
            print_error "Some files may remain in ${APP_DIR}, please check manually."
        fi
    else
        print_warning "Skipping removal of ${APP_DIR}."
    fi
else
    print_info "Application directory not found."
fi

# 6. Remove Bash/Zsh Aliases (Best effort for multiple users)
print_step "Removing Shell Aliases"
# Get a list of potential users who might have the alias
# Start with SUDO_USER, logname, and also check /home for other users

# First, find the original user who ran sudo (if applicable)
SUDO_USER_HOME=""
if [[ -n "${SUDO_USER:-}" ]]; then
    SUDO_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [[ -n "$SUDO_USER_HOME" ]]; then
        print_info "Found original sudo user: $SUDO_USER (home: $SUDO_USER_HOME)"
    fi
fi

# Function to remove alias from a specific RC file
remove_alias_from_file() {
    local user="$1"
    local file="$2"

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    print_info "Checking for alias in $file for user $user..."

    # Different possible alias patterns
    ALIAS_PATTERNS=(
        "alias ${APP_NAME}='xdg-open http://localhost:${FLASK_PORT}"
        "alias ${APP_NAME}=\"xdg-open http://localhost:${FLASK_PORT}"
        "alias service_manager='xdg-open http://localhost:${FLASK_PORT}"
        "alias service_manager=\"xdg-open http://localhost:${FLASK_PORT}"
        "# Alias for Web Service Manager"
        "# Alias for $APP_NAME"
    )

    local found=false
    for pattern in "${ALIAS_PATTERNS[@]}"; do
        if grep -q "$pattern" "$file"; then
            found=true
            break
        fi
    done

    if $found; then
        print_info "Found alias in $file, attempting to remove..."
        # Create backup
        cp "$file" "${file}.bak_$(date +%Y%m%d)" || print_warning "Failed to create backup of $file"

        # Remove any line matching our patterns
        for pattern in "${ALIAS_PATTERNS[@]}"; do
            sed -i "\@${pattern}@d" "$file" || print_warning "Failed to remove pattern '$pattern' from $file"
        done

        print_success "Attempted to remove aliases from $file (backup created)"
        return 0
    else
        print_info "No matching alias found in $file"
        return 1
    fi
}

# Try to remove alias for the sudo user first
if [[ -n "$SUDO_USER" && -n "$SUDO_USER_HOME" ]]; then
    RC_FILES=(
        "$SUDO_USER_HOME/.bashrc"
        "$SUDO_USER_HOME/.zshrc"
        "$SUDO_USER_HOME/.bash_profile"
        "$SUDO_USER_HOME/.profile"
    )

    for rc_file in "${RC_FILES[@]}"; do
        remove_alias_from_file "$SUDO_USER" "$rc_file"
    done

    print_info "If you're using $SUDO_USER, remember to run 'source ~/.bashrc' (or equivalent) or start a new terminal."
fi

# Check for other potential users in /home
print_info "Checking for aliases in other user homes..."
for user_home in /home/*; do
    if [[ -d "$user_home" ]]; then
        user=$(basename "$user_home")

        # Skip if this is the SUDO_USER we already processed
        if [[ "$user" == "$SUDO_USER" ]]; then
            continue
        fi

        RC_FILES=(
            "$user_home/.bashrc"
            "$user_home/.zshrc"
            "$user_home/.bash_profile"
            "$user_home/.profile"
        )

        for rc_file in "${RC_FILES[@]}"; do
            remove_alias_from_file "$user" "$rc_file"
        done
    fi
done

# Also check root's configuration
ROOT_RC_FILES=(
    "/root/.bashrc"
    "/root/.zshrc"
    "/root/.bash_profile"
    "/root/.profile"
)

for rc_file in "${ROOT_RC_FILES[@]}"; do
    remove_alias_from_file "root" "$rc_file"
done

# 7. Check for remaining files and warn user
print_step "Final Cleanup Check"

# Places to check for leftover files
POTENTIAL_LEFTOVER_LOCATIONS=(
    "/etc/systemd/system/${APP_NAME}*"
    "/etc/sudoers.d/*${APP_NAME}*"
    "/var/log/${APP_NAME}*"
    "/tmp/${APP_NAME}*"
    "/run/${APP_NAME}*"
)

found_leftovers=false
for pattern in "${POTENTIAL_LEFTOVER_LOCATIONS[@]}"; do
    # We use ls instead of test to also see what matched
    if ls $pattern &>/dev/null; then
        found_leftovers=true
        print_warning "Found potential leftover files: $pattern"
        ls -la $pattern 2>/dev/null >>"$LOG_FILE"
    fi
done

if $found_leftovers; then
    print_warning "Some files related to ${APP_NAME} may still remain on the system."
    print_info "Check the log file for details: $LOG_FILE"
    if confirm "Would you like to attempt to remove these files? [y/N]"; then
        for pattern in "${POTENTIAL_LEFTOVER_LOCATIONS[@]}"; do
            print_info "Removing files matching: $pattern"
            rm -rf $pattern 2>/dev/null || print_warning "Failed to remove some files matching $pattern"
        done
    fi
else
    print_success "No obvious leftover files detected."
fi

# Final cleanup: check for remaining processes again
if pgrep -f "${APP_DIR}/app.py" >/dev/null; then
    print_warning "There are still processes running related to ${APP_NAME}!"
    print_info "You may want to restart your system or kill these processes manually."
else
    print_success "No remaining processes detected."
fi

echo ""
echo -e "${GREEN}${BOLD}[SUCCESS] Uninstallation process finished.${NC}"
echo -e "Please review the output above and the log file for any warnings or manual steps required."
echo -e "Log file: ${BLUE}$LOG_FILE${NC}"
echo ""

exit 0
