# Systemd Service Manager Web UI

A modern, Flask-based web interface for managing systemd services on a Linux server. Provides a clean UI built with Tailwind CSS, featuring frosted glass effects, for viewing, controlling, and even editing service unit files.

---

**⚠️ Security Warning:** This application grants specific `sudo` privileges to the web server user (`www-data` by default) to interact with `systemctl`. The file editing feature, while powerful, is **extremely dangerous** if not properly secured and configured. Incorrect usage or security misconfiguration could severely compromise or break your system. Use with extreme caution, especially in production environments. Consider disabling the editing feature if not strictly required.

---

## Screenshot

![Screenshot](Screenshot_0.png)
![Screenshot](Screenshot_1.png)
![Screenshot](Screenshot_2.png)
![Screenshot](Screenshot_3.png)

## Features

*   **List Services:** View all `.service` units (active and inactive).
*   **Filtering:** Quickly filter the service list by unit name, description, active state, or enabled state using the search bar.
*   **Sorting:** Sort the service list by clicking table headers (Unit, Load, Active, Sub, Enabled, Description).
*   **Real-time Actions:**
    *   Start, Stop, Restart services.
    *   Enable, Disable services on boot.
    *   Reload the systemd daemon (`daemon-reload`).
*   **View Status:** See the detailed output of `systemctl status <service>`.
*   **View Unit File:** Display the content of the service's unit file using `systemctl cat`.
*   **Edit Unit File (Optional & Dangerous):** Modify the service's primary unit file directly through the web UI. Requires careful `sudoers` configuration.
*   **Modern UI:** Clean interface using Tailwind CSS, inspired by Material You aesthetics with frosted glass effects.

## Prerequisites

*   A Linux distribution using **systemd** (tested primarily on Debian/Ubuntu derivatives).
*   **Python 3** (including `python3-venv`).
*   **sudo** installed and configured.
*   Root or `sudo` privileges for installation.
*   Basic familiarity with the Linux command line.
*   A modern web browser.

## Installation

The provided `install.sh` script automates most of the setup process.

**Important:** Review the `install.sh` script before running it to understand the actions it will perform on your system.

1.  **Clone the Repository:**
    ```bash
    git clone https://github.com/1999AZZAR/Systemd-Service-Manager-Web-UI.git
    cd Systemd-Service-Manager-Web-UI
    ```

2.  **Run the Installation Script:**
    ```bash
    sudo ./install.sh
    ```

    The script will:
    *   Install dependencies (`python3-venv`).
    *   Create the application directory (default: `/opt/servicemanager`).
    *   Copy application files (`app.py`, `static/`, `templates/`).
    *   Create a Python virtual environment (`venv`) and install Flask.
    *   Set file ownership (default: `www-data:www-data`).
    *   Configure `sudoers` rules for the service user in `/etc/sudoers.d/90-servicemanager` (allowing specific `systemctl` commands **and `tee` if file editing is intended**).
    *   Copy, modify (to use the venv), enable, and start the `systemd` service (`servicemanager.service`).
    *   Attempt to add a bash alias (`service_manager`) to the invoking user's `.bashrc` for easy access.

3.  **Verify Service Status:**
    ```bash
    sudo systemctl status servicemanager.service
    ```
    It should show as `active (running)`.

4.  **(Optional) Source Bashrc:** If the alias was added, open a *new* terminal or run `source ~/.bashrc` for the `service_manager` command to become available.

## Configuration

Several parts of the application can be configured:

*   **`app.py`:**
    *   `SERVICE_USER`: The user the Flask app runs as (must match `servicemanager.service` and `sudoers`). Default: `www-data`.
    *   `ALLOWED_WRITE_DIRS`: **Critical for security if editing is enabled.** A list of *absolute directory paths* where the application is allowed to write files using `sudo tee`. Default: `["/etc/systemd/system/"]`. Restrict this as much as possible.

*   **`servicemanager.service`:**
    *   `User`, `Group`: Must match `SERVICE_USER` in `app.py`.
    *   `WorkingDirectory`: Should point to the application directory (e.g., `/opt/servicemanager`).
    *   `ExecStart`: Ensure this points to the correct Python executable within the virtual environment (the `install.sh` script attempts to set this automatically). If using Gunicorn/uWSGI, modify this line accordingly.

*   **`install.sh`:**
    *   Variables at the top (`APP_NAME`, `APP_DIR`, `SERVICE_USER`, `FLASK_PORT`, etc.) can be modified before running the script.

*   **Sudoers (`/etc/sudoers.d/90-servicemanager`):**
    *   This file defines the permissions granted to the `SERVICE_USER`.
    *   **Crucially, the `/usr/bin/tee` lines should only be present if you intend to use the file editing feature.** Ensure the path(s) specified for `tee` match the locations you *actually* want to allow writing to (e.g., `/etc/systemd/system/*.service`). **Avoid overly broad permissions like `/usr/bin/tee /etc/*`!**
    *   See the "Editing Sudoers Safely" section below for how to modify this file.

*   **Tailwind (`templates/index.html`):**
    *   The `tailwind.config` object within the `<script>` tag can be modified to customize colors, fonts, etc., without needing a build step (thanks to the Play CDN).

## Editing Sudoers Safely (using `visudo`)

The `install.sh` script creates the necessary `sudoers` file (`/etc/sudoers.d/90-servicemanager`) automatically. However, if you need to modify it later (e.g., to add or remove `tee` permissions for file editing, or change the allowed commands), **always use the `visudo` command**. Never edit `sudoers` files directly with a text editor like `nano` or `vim`.

`visudo` locks the `sudoers` file and performs syntax checking before saving, preventing you from locking yourself out of `sudo` access due to errors.

**Steps:**

1.  **Open the specific file with `visudo`:**
    ```bash
    sudo visudo -f /etc/sudoers.d/90-servicemanager
    ```
    *(Replace `90-servicemanager` if you changed the `SUDOERS_FILE_NAME` in `install.sh`)*

2.  **Edit the file:** `visudo` will open the file in your system's default command-line editor (often `nano` or `vi`). Make your changes carefully. For example, to enable editing service files in `/etc/systemd/system/`:
    ```sudoers
    # Add or uncomment these lines:
    www-data ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/systemd/system/*.service
    ```
    To disable editing, comment out or delete those `/usr/bin/tee` lines.

3.  **Save and Exit:**
    *   **Nano:** Press `Ctrl+X`, then `Y` to confirm saving, then `Enter` to confirm the filename.
    *   **Vi/Vim:** Press `Esc`, then type `:wq` and press `Enter`.

4.  **Syntax Check:** `visudo` will automatically check the syntax.
    *   If it says `"parsed OK"`, the changes are saved.
    *   If it reports a syntax error, it will usually ask what you want to do. Choose to **edit the file again (`e`)** to fix the error. **Do not exit without fixing the error**, as this could break `sudo`.

**Important:** Always double-check the permissions you are granting, especially `NOPASSWD` commands and file writing permissions like `tee`.

> **⚠️ WARNING:** Granting `NOPASSWD` for service file editing and/or journal access effectively grants root privileges for those operations without requiring a password. Misconfiguration or compromise of the web UI could:
> - Modify or delete critical system unit files.
> - Enable an attacker to install or alter services.
> - Expose or tamper with sensitive system logs.
>
> **Recommendations:**
> - Restrict commands to the narrowest possible paths and arguments (e.g., `/etc/systemd/system/*.service`).
> - Avoid broad wildcards that may cover unintended files.
> - Always validate changes with `visudo -c` and keep backup copies of sudoers files.
> - Consider enabling logging/auditing (e.g., via `auditd`) to monitor sudo and journal access.

## Usage

1.  **Access the UI:** Open your web browser and navigate to:
    *   `http://<your-server-ip>:5001` (Replace `<your-server-ip>` and `5001` if you changed the port).
    *   `http://localhost:5001` if accessing from the server itself.
    *   Or, if the alias was successfully added, open a terminal and run `service_manager`.

2.  **Interface Overview:**
    *   **Filter Bar:** Type to filter services dynamically across multiple fields.
    *   **Refresh Button:** Reloads the service list from the backend.
    *   **Reload Daemon Button:** Runs `sudo systemctl daemon-reload`.
    *   **Table Headers:** Click sortable headers (Unit, Load, Active, etc.) to sort the list. Click again to reverse order.
    *   **Service Rows:** Display information about each service.
    *   **Action Buttons:** Icons for Start, Stop, Restart, Enable, Disable, Status (opens status modal with integrated **View Logs**), and View/Edit File. Hover for tooltips.
    *   **Modals:**
    *       * **Status Modal:** Shows unit load/active/sub status and provides a **View Logs** button to fetch recent journal entries.
    *       * **File Modal:** Displays and optionally edits unit file content within configured `ALLOWED_WRITE_DIRS`.

## Security Considerations

**Please read carefully:**

*   **Sudo Access:** The web server user (`www-data`) is granted passwordless `sudo` access for *specific* `systemctl` commands and potentially `tee`. This is the primary security risk. Ensure the `sudoers` file (`/etc/sudoers.d/90-servicemanager`) is correctly configured, has `0440` permissions, is owned by `root:root`, and only allows necessary commands. Use `visudo` for editing.
*   **File Editing Risk:**
    *   **Requires specific `sudoers` rules for `/usr/bin/tee` to function.**
    *   Allowing file edits via a web UI is **inherently dangerous**. An attacker gaining access to the UI could potentially modify any allowed service file, leading to system compromise.
    *   The application performs basic path validation (`ALLOWED_WRITE_DIRS` in `app.py`) and checks against symlinks, but these might not be foolproof.
    *   **STRONGLY RECOMMEND:** Only enable this feature if absolutely necessary and after carefully restricting the allowed paths in *both* `app.py` and the `sudoers` file.
*   **Network Exposure:** By default, Flask runs on `0.0.0.0`, making the UI accessible from any machine on the network.
    *   Run this application only on trusted networks.
    *   For untrusted networks, configure a reverse proxy (like Nginx or Apache) in front of the Flask app to handle HTTPS/TLS and potentially add authentication (e.g., HTTP Basic Auth, OAuth).
*   **No Built-in Authentication:** The application does not have any login or user authentication mechanism. Access control relies entirely on network access and potentially a reverse proxy setup.
*   **Input Sanitation:** Basic input sanitation is performed (e.g., on service names), but could potentially be bypassed.
*   **Dependencies:** Keep Flask and other system dependencies updated to patch potential vulnerabilities.

## Troubleshooting

*   **UI shows "No services found..." but services exist:**
    1.  Check the application logs: `sudo journalctl -u servicemanager.service -f`
    2.  Look for errors related to `sudo`, `systemctl`, or Python parsing (`parse_list_units`).
    3.  Verify the `sudoers` configuration: `sudo visudo -c` and check permissions/content of `/etc/sudoers.d/90-servicemanager`. Use `sudo visudo -f /etc/sudoers.d/90-servicemanager` to edit if needed.
    4.  Test the command manually as the service user: `sudo -u www-data /bin/systemctl list-units --type=service --all --no-legend --no-pager`. Does it work? Does the output look parseable?
*   **Permission Denied / Sudo Errors in Logs:** Likely an issue with the `sudoers` file. See previous point and the "Editing Sudoers Safely" section.
*   **Service Fails to Start (`sudo systemctl status servicemanager.service`):** Check the logs (`journalctl -u servicemanager.service`) for Python errors, path issues, or port conflicts. Ensure the `ExecStart` path in the `.service` file is correct.
*   **UI Appears Broken / Styles Missing:** Hard refresh your browser (Ctrl+Shift+R or Cmd+Shift+R) to clear the cache. Check the browser's developer console (F12) for errors loading CSS, JS, or API requests.
*   **File Editing Fails:**
    1.  Check `sudoers` rules for `/usr/bin/tee` using `sudo visudo -f /etc/sudoers.d/90-servicemanager`. Are they present and correct for the target path?
    2.  Check `ALLOWED_WRITE_DIRS` in `app.py`. Does it include the parent directory of the target file?
    3.  Check application logs (`journalctl`) for specific errors from `app.py` or the `tee` command.

## Uninstallation

A script is provided to remove the application and its configurations.

**Warning:** This will permanently delete the application files and configuration.

1.  Navigate *outside* the application directory (e.g., `cd ..`).
2.  Run the uninstallation script:
    ```bash
    sudo ./service-manager/uninstall.sh # Adjust path if you cloned to a different name
    ```
    The script will attempt to:
    *   Stop and disable the `servicemanager.service`.
    *   Remove the systemd service file (`/etc/systemd/system/servicemanager.service`).
    *   Remove the sudoers file (`/etc/sudoers.d/90-servicemanager`).
    *   Remove the application directory (default: `/opt/servicemanager`, will prompt for confirmation).
    *   Attempt to remove the bash alias from the original user's `.bashrc`.

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs, feature requests, or improvements.
