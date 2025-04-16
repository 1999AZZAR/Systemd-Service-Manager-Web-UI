#!/bin/bash

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
# --- End Configuration ---

# --- Helper Functions ---
print_info() { echo "[INFO] $1"; }
print_success() { echo "[SUCCESS] $1"; }
print_warning() { echo "[WARNING] $1"; }
print_error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# --- Pre-flight Checks ---
if [[ "${EUID}" -ne 0 ]]; then print_error "This script must be run as root (or with sudo)."; fi
command -v $PYTHON_EXEC >/dev/null 2>&1 || print_error "$PYTHON_EXEC is not installed. Please install it first (e.g., apt install python3)."
command -v systemctl >/dev/null 2>&1 || print_error "systemctl not found. This script requires systemd."
command -v sudo >/dev/null 2>&1 || print_error "sudo command not found. Please install it (e.g., apt install sudo)."
command -v xdg-open >/dev/null 2>&1 || print_warning "xdg-open not found. The automatic browser opening alias might not work."

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
if [[ ! -f "${SCRIPT_DIR}/app.py" || ! -d "${SCRIPT_DIR}/templates" || ! -d "${SCRIPT_DIR}/static" || ! -f "${SCRIPT_DIR}/${SERVICE_FILE_NAME}" ]]; then
    print_error "Script must be run from the directory containing app.py, templates/, static/, and ${SERVICE_FILE_NAME}"
fi

# --- Main Installation ---
print_info "Starting Service Manager setup..."

# 1. Install Dependencies
print_info "Updating package list and installing dependencies (python3-venv)..."
apt-get update >/dev/null
apt-get install -y python3-venv >/dev/null
print_success "Dependencies installed."

# 2. Create Application Directory
print_info "Creating application directory: ${APP_DIR}"
mkdir -p "${APP_DIR}"

# 3. Copy Application Files
print_info "Copying application files to ${APP_DIR}..."
mkdir -p "${APP_DIR}/static" "${APP_DIR}/templates"
cp "${SCRIPT_DIR}/app.py" "${APP_DIR}/"
# Use rsync for potentially safer copying of directory contents
rsync -a --delete "${SCRIPT_DIR}/templates/" "${APP_DIR}/templates/"
rsync -a --delete "${SCRIPT_DIR}/static/" "${APP_DIR}/static/"
print_success "Application files copied."

# 4. Create Python Virtual Environment and Install Requirements
print_info "Creating Python virtual environment in ${APP_DIR}/venv..."
# Ensure previous venv is removed if script is re-run
rm -rf "${APP_DIR}/venv"
$PYTHON_EXEC -m venv "${APP_DIR}/venv"
print_info "Installing Flask inside the virtual environment..."
"${APP_DIR}/venv/bin/python3" -m pip install --upgrade pip >/dev/null
"${APP_DIR}/venv/bin/python3" -m pip install Flask >/dev/null
print_success "Python environment created and Flask installed."

# 5. Set Permissions
print_info "Setting ownership for ${APP_DIR} to ${SERVICE_USER}:${SERVICE_GROUP}..."
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then print_warning "User '$SERVICE_USER' not found. Create it or adjust SERVICE_USER."; fi
if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then print_warning "Group '$SERVICE_GROUP' not found. Create it or adjust SERVICE_GROUP."; fi
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${APP_DIR}"
print_success "Permissions set."

# 6. Configure Sudoers
print_info "Configuring sudoers for ${SERVICE_USER} in /etc/sudoers.d/${SUDOERS_FILE_NAME}..."
SUDOERS_FILE_PATH="/etc/sudoers.d/${SUDOERS_FILE_NAME}"
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

# Add lines below ONLY if you enable the file editing feature in app.py
# ${SERVICE_USER} ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/systemd/system/*
# ${SERVICE_USER} ALL=(ALL) NOPASSWD: /usr/bin/tee /usr/lib/systemd/system/*
EOF
chmod 0440 "${SUDOERS_FILE_PATH}"
# Validate sudoers file syntax
visudo -c -f "${SUDOERS_FILE_PATH}" || print_error "Sudoers file syntax error in ${SUDOERS_FILE_PATH}. Installation aborted."
print_success "Sudoers rule created and validated."

# 7. Setup Systemd Service
print_info "Setting up systemd service..."
SERVICE_FILE_PATH_SRC="${SCRIPT_DIR}/${SERVICE_FILE_NAME}"
SERVICE_FILE_PATH_DEST="/etc/systemd/system/${SERVICE_FILE_NAME}"

# Create a temporary file for sed modifications
TMP_SERVICE_FILE=$(mktemp)
cp "${SERVICE_FILE_PATH_SRC}" "${TMP_SERVICE_FILE}"

# Modify ExecStart to use the venv python3
VENV_PYTHON_PATH="${APP_DIR}/venv/bin/python3"
print_info "Ensuring service ExecStart uses ${VENV_PYTHON_PATH}..."
sed -i "s#^ExecStart=.*#ExecStart=${VENV_PYTHON_PATH} ${APP_DIR}/app.py#" "${TMP_SERVICE_FILE}"

# Modify WorkingDirectory if it doesn't match APP_DIR
print_info "Ensuring service WorkingDirectory is ${APP_DIR}..."
sed -i "s#^WorkingDirectory=.*#WorkingDirectory=${APP_DIR}#" "${TMP_SERVICE_FILE}"

# Modify User and Group
print_info "Ensuring service User=${SERVICE_USER} and Group=${SERVICE_GROUP}..."
sed -i "s#^User=.*#User=${SERVICE_USER}#" "${TMP_SERVICE_FILE}"
sed -i "s#^Group=.*#Group=${SERVICE_GROUP}#" "${TMP_SERVICE_FILE}"

# Check if changes were made (optional, good for debugging)
# diff -u "${SERVICE_FILE_PATH_SRC}" "${TMP_SERVICE_FILE}" || true

print_info "Copying modified service file to ${SERVICE_FILE_PATH_DEST}"
cp "${TMP_SERVICE_FILE}" "${SERVICE_FILE_PATH_DEST}"
rm "${TMP_SERVICE_FILE}" # Clean up temp file
chmod 0644 "${SERVICE_FILE_PATH_DEST}"

print_info "Reloading systemd daemon..."
systemctl daemon-reload

print_info "Enabling service ${SERVICE_FILE_NAME} to start on boot..."
systemctl enable "${SERVICE_FILE_NAME}"

print_info "Starting service ${SERVICE_FILE_NAME}..."
# Stop first in case it's already running from a previous attempt
systemctl stop "${SERVICE_FILE_NAME}" || true # Ignore error if not running
systemctl start "${SERVICE_FILE_NAME}"

print_success "Systemd service ${SERVICE_FILE_NAME} setup and started."

# 8. Add Bash Alias
# Disable nounset temporarily for SUDO_USER check
set +u
ORIGINAL_USER=${SUDO_USER:-$(logname 2>/dev/null || echo "")}
# Re-enable nounset
set -u

if [[ -n "$ORIGINAL_USER" && "$ORIGINAL_USER" != "root" ]]; then
    USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
    BASHRC_PATH="${USER_HOME}/.bashrc"

    if [[ -f "$BASHRC_PATH" ]]; then
        ALIAS_CMD="alias ${APP_NAME}='xdg-open http://localhost:${FLASK_PORT} &> /dev/null'"
        ALIAS_COMMENT="# Alias for Web Service Manager (${APP_NAME})"

        print_info "Attempting to add alias '${APP_NAME}' to ${BASHRC_PATH} for user ${ORIGINAL_USER}..."
        if grep -Fq "$ALIAS_CMD" "$BASHRC_PATH"; then
            print_info "Alias already exists in ${BASHRC_PATH}."
        else
            echo "" >>"$BASHRC_PATH"
            echo "$ALIAS_COMMENT" >>"$BASHRC_PATH"
            echo "$ALIAS_CMD" >>"$BASHRC_PATH"
            # Ensure user owns their bashrc
            chown "${ORIGINAL_USER}:${ORIGINAL_USER}" "$BASHRC_PATH" || print_warning "Could not chown ${BASHRC_PATH} back to ${ORIGINAL_USER}"
            print_success "Alias '${APP_NAME}' added to ${BASHRC_PATH}."
            print_info "Run 'source ${BASHRC_PATH}' or open a new terminal for the alias to take effect."
        fi
    else
        print_warning "Could not find ${BASHRC_PATH} for user ${ORIGINAL_USER}. Alias not added automatically."
        print_info "You can add it manually: echo \"${ALIAS_CMD}\" >> ~/.bashrc"
    fi
else
    print_warning "Could not determine the original user or user is root. Alias not added automatically."
    print_info "You can add it manually: echo \"${ALIAS_CMD}\" >> ~/.bashrc"
fi

# --- Final Instructions ---
echo ""
print_success "Installation Complete!"
echo ""
echo "The Service Manager backend should now be running."
echo "Check status: sudo systemctl status ${SERVICE_FILE_NAME}"
echo "Check logs:   sudo journalctl -u ${SERVICE_FILE_NAME} -f"
echo ""
echo "Access the web UI at: http://<your-server-ip>:${FLASK_PORT}"
echo "(Or http://localhost:${FLASK_PORT} if accessing locally)"
echo ""
if [[ -n "$ORIGINAL_USER" && "$ORIGINAL_USER" != "root" && -f "$BASHRC_PATH" ]] && grep -Fq "$ALIAS_CMD" "$BASHRC_PATH"; then
    echo "Try opening the UI in a *new* terminal with the command: ${APP_NAME}"
fi
echo ""

exit 0
