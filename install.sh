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
# Treat unset variables as an error when substituting.
set -u
# Prevent errors in pipelines from being masked.
set -o pipefail

# --- Configuration ---
APP_NAME="servicemanager"
APP_DIR="/opt/${APP_NAME}"
SERVICE_USER="www-data"  # MUST match User= in servicemanager.service and sudoers
SERVICE_GROUP="www-data" # MUST match Group= in servicemanager.service
SERVICE_FILE_NAME="${APP_NAME}.service"
SUDOERS_FILE_NAME="90-${APP_NAME}" # File in /etc/sudoers.d/
PYTHON_EXEC="python3"
FLASK_PORT="5001" # Port the app runs on (must match app.py)
VENV_DIR=".venv"  # Standard Python virtual environment directory name
# --- End Configuration ---

# --- Helper Functions ---
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

print_step() {
    echo -e "\n${BOLD}${BLUE}== $1 ==${NC}"
}

# Progress spinner
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# --- Pre-flight Checks ---
print_step "Pre-flight Checks"

if [[ "${EUID}" -ne 0 ]]; then
    print_error "This script must be run as root (or with sudo)."
fi

# Check for required commands
if ! command_exists $PYTHON_EXEC; then
    print_error "$PYTHON_EXEC is not installed. Please install it first (e.g., apt install python3)."
fi

if ! command_exists systemctl; then
    print_error "systemctl not found. This script requires systemd."
fi

if ! command_exists sudo; then
    print_error "sudo command not found. Please install it (e.g., apt install sudo)."
fi

# Get script directory using a more reliable method
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# Check required files
REQUIRED_FILES=("app.py" "servicemanager.service")
REQUIRED_DIRS=("templates" "static")

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${SCRIPT_DIR}/${file}" ]]; then
        print_error "Required file ${file} not found in ${SCRIPT_DIR}. Installation aborted."
    fi
done

for dir in "${REQUIRED_DIRS[@]}"; do
    if [[ ! -d "${SCRIPT_DIR}/${dir}" ]]; then
        print_error "Required directory ${dir} not found in ${SCRIPT_DIR}. Installation aborted."
    fi
done

print_success "All pre-flight checks passed."

# --- Main Installation ---
print_step "Service Manager Setup"

# 1. Install Dependencies
print_step "Installing Dependencies"
print_info "Updating package list and installing dependencies (python3-venv)..."
apt-get update >/dev/null &
PID=$!
spinner $PID
wait $PID
apt-get install -y python3-venv >/dev/null &
PID=$!
spinner $PID
wait $PID
print_success "Dependencies installed."

# 2. Create Application Directory
print_step "Creating Application Directory"
print_info "Creating application directory: ${APP_DIR}"
mkdir -p "${APP_DIR}" || print_error "Failed to create directory ${APP_DIR}"
print_success "Application directory created."

# 3. Copy Application Files
print_step "Copying Application Files"
print_info "Copying application files to ${APP_DIR}..."
mkdir -p "${APP_DIR}/static" "${APP_DIR}/templates"
cp "${SCRIPT_DIR}/app.py" "${APP_DIR}/" || print_error "Failed to copy app.py"

# Check if rsync is available, fall back to cp if not
if command_exists rsync; then
    print_info "Using rsync for directory copying..."
    rsync -a --delete "${SCRIPT_DIR}/templates/" "${APP_DIR}/templates/" || print_error "Failed to copy templates directory"
    rsync -a --delete "${SCRIPT_DIR}/static/" "${APP_DIR}/static/" || print_error "Failed to copy static directory"
else
    print_warning "rsync not found, using cp instead (less safe for directories)"
    cp -r "${SCRIPT_DIR}/templates/"* "${APP_DIR}/templates/" || print_error "Failed to copy templates directory"
    cp -r "${SCRIPT_DIR}/static/"* "${APP_DIR}/static/" || print_error "Failed to copy static directory"
fi
print_success "Application files copied."

# 4. Create Python Virtual Environment and Install Requirements
print_step "Setting Up Python Environment"
print_info "Creating Python virtual environment in ${APP_DIR}/${VENV_DIR}..."
# Ensure previous venv is removed if script is re-run
rm -rf "${APP_DIR}/${VENV_DIR}"
$PYTHON_EXEC -m venv "${APP_DIR}/${VENV_DIR}" || print_error "Failed to create Python virtual environment"
print_info "Installing Flask inside the virtual environment..."
"${APP_DIR}/${VENV_DIR}/bin/python" -m pip install --upgrade pip >/dev/null &
PID=$!
spinner $PID
wait $PID
"${APP_DIR}/${VENV_DIR}/bin/python" -m pip install Flask >/dev/null &
PID=$!
spinner $PID
wait $PID
print_success "Python environment created and Flask installed."

# 5. Set Permissions
print_step "Setting Permissions"
print_info "Setting ownership for ${APP_DIR} to ${SERVICE_USER}:${SERVICE_GROUP}..."
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    print_warning "User '$SERVICE_USER' not found. Create it or adjust SERVICE_USER."
    if confirm "Would you like to create the '$SERVICE_USER' user now? [y/N]"; then
        useradd -r -s /bin/false "$SERVICE_USER" || print_warning "Failed to create user. Continuing anyway..."
    fi
fi
if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    print_warning "Group '$SERVICE_GROUP' not found. Create it or adjust SERVICE_GROUP."
    if confirm "Would you like to create the '$SERVICE_GROUP' group now? [y/N]"; then
        groupadd "$SERVICE_GROUP" || print_warning "Failed to create group. Continuing anyway..."
    fi
fi
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${APP_DIR}" || print_warning "Failed to set ownership. Check if user/group exists."
chmod -R 750 "${APP_DIR}" || print_warning "Failed to set directory permissions"
print_success "Permissions set."

# Confirm function for yes/no prompts
confirm() {
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

# 6. Configure Sudoers
print_step "Configuring Sudoers"
print_info "Configuring sudoers for ${SERVICE_USER} in /etc/sudoers.d/${SUDOERS_FILE_NAME}..."
SUDOERS_FILE_PATH="/etc/sudoers.d/${SUDOERS_FILE_NAME}"

# Create the sudoers file with conservative permissions initially
cat >"${SUDOERS_FILE_PATH}" <<EOF
# Allow the Service Manager backend user (${SERVICE_USER}) to run specific systemctl commands
${SERVICE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl list-units --type=service --all --no-legend --no-pager
${SERVICE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl list-unit-files --type=service --no-legend --no-pager
${SERVICE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl is-enabled *
${SERVICE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl start *
${SERVICE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl stop *
${SERVICE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart *
${SERVICE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl enable *
${SERVICE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl disable *
${SERVICE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl daemon-reload
${SERVICE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl cat *
${SERVICE_USER} ALL=(ALL) NOPASSWD: /bin/systemctl show -p FragmentPath --value *

# Add file editing capability - SECURITY RISK - Comment or remove if not needed
EOF

# Ask about file editing capability
if confirm "Enable service file editing capabilities? (SECURITY RISK!) [y/N]"; then
    cat >>"${SUDOERS_FILE_PATH}" <<EOF
# File editing capabilities enabled by user during install
${SERVICE_USER} ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/systemd/system/*.service
# Uncomment below if needed for system services
# ${SERVICE_USER} ALL=(ALL) NOPASSWD: /usr/bin/tee /usr/lib/systemd/system/*.service
EOF
    print_info "File editing capabilities ENABLED. Review security in the README."
else
    print_info "File editing capabilities NOT enabled. Edit sudoers manually if needed later."
fi

chmod 0440 "${SUDOERS_FILE_PATH}" || print_error "Failed to set permissions on sudoers file"

# Validate sudoers file syntax
if ! visudo -c -f "${SUDOERS_FILE_PATH}"; then
    print_error "Sudoers file syntax error in ${SUDOERS_FILE_PATH}. Installation aborted."
fi
print_success "Sudoers rule created and validated."

# 7. Setup Systemd Service
print_step "Setting Up Systemd Service"
print_info "Setting up systemd service..."
SERVICE_FILE_PATH_SRC="${SCRIPT_DIR}/${SERVICE_FILE_NAME}"
SERVICE_FILE_PATH_DEST="/etc/systemd/system/${SERVICE_FILE_NAME}"

# Create a temporary file for sed modifications
TMP_SERVICE_FILE=$(mktemp)
cp "${SERVICE_FILE_PATH_SRC}" "${TMP_SERVICE_FILE}" || print_error "Failed to copy service file to temp location"

# Modify ExecStart to use the venv python3
VENV_PYTHON_PATH="${APP_DIR}/${VENV_DIR}/bin/python"
print_info "Ensuring service ExecStart uses ${VENV_PYTHON_PATH}..."
sed -i "s#^ExecStart=.*#ExecStart=${VENV_PYTHON_PATH} ${APP_DIR}/app.py#" "${TMP_SERVICE_FILE}" || print_error "Failed to modify ExecStart in service file"

# Modify WorkingDirectory if it doesn't match APP_DIR
print_info "Ensuring service WorkingDirectory is ${APP_DIR}..."
sed -i "s#^WorkingDirectory=.*#WorkingDirectory=${APP_DIR}#" "${TMP_SERVICE_FILE}" || print_error "Failed to modify WorkingDirectory in service file"

# Modify User and Group
print_info "Ensuring service User=${SERVICE_USER} and Group=${SERVICE_GROUP}..."
sed -i "s#^User=.*#User=${SERVICE_USER}#" "${TMP_SERVICE_FILE}" || print_error "Failed to modify User in service file"
sed -i "s#^Group=.*#Group=${SERVICE_GROUP}#" "${TMP_SERVICE_FILE}" || print_error "Failed to modify Group in service file"

print_info "Copying modified service file to ${SERVICE_FILE_PATH_DEST}"
cp "${TMP_SERVICE_FILE}" "${SERVICE_FILE_PATH_DEST}" || print_error "Failed to copy service file to final location"
rm "${TMP_SERVICE_FILE}" # Clean up temp file
chmod 0644 "${SERVICE_FILE_PATH_DEST}" || print_error "Failed to set permissions on service file"

print_info "Reloading systemd daemon..."
systemctl daemon-reload || print_error "Failed to reload systemd daemon"

print_info "Enabling service ${SERVICE_FILE_NAME} to start on boot..."
systemctl enable "${SERVICE_FILE_NAME}" || print_error "Failed to enable service"

print_info "Starting service ${SERVICE_FILE_NAME}..."
# Stop first in case it's already running from a previous attempt
systemctl stop "${SERVICE_FILE_NAME}" 2>/dev/null || true # Ignore error if not running
systemctl start "${SERVICE_FILE_NAME}" || {
    print_error "Failed to start service. Check logs with: journalctl -u ${SERVICE_FILE_NAME}"
}

print_success "Systemd service ${SERVICE_FILE_NAME} setup and started."

# 8. Add Bash Alias
print_step "Setting Up User Alias"
# Disable nounset temporarily for SUDO_USER check
set +u
ORIGINAL_USER=${SUDO_USER:-$(logname 2>/dev/null || echo "")}
# Re-enable nounset
set -u

if [[ -n "$ORIGINAL_USER" && "$ORIGINAL_USER" != "root" ]]; then
    USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

    # Check for different shell rc files
    RC_FILES=(".bashrc" ".zshrc")
    FOUND_RC=false

    for rc_file in "${RC_FILES[@]}"; do
        RC_PATH="${USER_HOME}/${rc_file}"
        if [[ -f "$RC_PATH" ]]; then
            ALIAS_CMD="alias ${APP_NAME}='xdg-open http://localhost:${FLASK_PORT} &> /dev/null'"
            ALIAS_COMMENT="# Alias for Web Service Manager (${APP_NAME})"

            print_info "Attempting to add alias '${APP_NAME}' to ${RC_PATH} for user ${ORIGINAL_USER}..."
            if grep -Fq "$ALIAS_CMD" "$RC_PATH"; then
                print_info "Alias already exists in ${RC_PATH}."
            else
                echo "" >>"$RC_PATH"
                echo "$ALIAS_COMMENT" >>"$RC_PATH"
                echo "$ALIAS_CMD" >>"$RC_PATH"
                # Ensure user owns their rc file
                chown "${ORIGINAL_USER}:${ORIGINAL_USER}" "$RC_PATH" || print_warning "Could not chown ${RC_PATH} back to ${ORIGINAL_USER}"
                print_success "Alias '${APP_NAME}' added to ${RC_PATH}."
                print_info "Run 'source ${RC_PATH}' or open a new terminal for the alias to take effect."
            fi
            FOUND_RC=true
            break
        fi
    done

    if [[ "$FOUND_RC" = false ]]; then
        print_warning "Could not find shell configuration file for user ${ORIGINAL_USER}. Alias not added automatically."
        print_info "You can add it manually: echo \"alias ${APP_NAME}='xdg-open http://localhost:${FLASK_PORT} &> /dev/null'\" >> ~/.bashrc"
    fi
else
    print_warning "Could not determine the original user or user is root. Alias not added automatically."
    print_info "You can add it manually: echo \"alias ${APP_NAME}='xdg-open http://localhost:${FLASK_PORT} &> /dev/null'\" >> ~/.bashrc"
fi

# 9. Check if service is running properly
print_step "Verifying Installation"
sleep 2 # Give the service a moment to start
if systemctl is-active --quiet "${SERVICE_FILE_NAME}"; then
    print_success "Service ${SERVICE_FILE_NAME} is running correctly."
else
    print_warning "Service ${SERVICE_FILE_NAME} may not be running correctly. Check status with: sudo systemctl status ${SERVICE_FILE_NAME}"
fi

# --- Final Instructions ---
echo -e "\n${BOLD}${GREEN}Installation Complete!${NC}\n"
echo -e "${BOLD}Services:${NC}"
echo "  Check status:  ${BLUE}sudo systemctl status ${SERVICE_FILE_NAME}${NC}"
echo "  Check logs:    ${BLUE}sudo journalctl -u ${SERVICE_FILE_NAME} -f${NC}"
echo ""
echo -e "${BOLD}Web Interface:${NC}"
echo "  URL:          ${BLUE}http://<your-server-ip>:${FLASK_PORT}${NC}"
echo "  Local access: ${BLUE}http://localhost:${FLASK_PORT}${NC}"
echo ""
if [[ -n "$ORIGINAL_USER" && "$ORIGINAL_USER" != "root" && -f "$RC_PATH" ]] && grep -Fq "$ALIAS_CMD" "$RC_PATH"; then
    echo -e "Try opening the UI in a ${BOLD}new terminal${NC} with the command: ${BLUE}${APP_NAME}${NC}"
fi
echo ""
echo -e "${YELLOW}Security Reminder:${NC} This application grants sudo privileges to ${SERVICE_USER}."
echo "Review the installed sudoers file: /etc/sudoers.d/${SUDOERS_FILE_NAME}"
echo ""

exit 0
