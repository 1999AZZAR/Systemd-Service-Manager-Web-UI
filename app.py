#!/usr/bin/env python3
import subprocess
import json
import re
import os
import logging
import shlex  # For safe command string splitting if needed
from flask import Flask, request, jsonify, render_template, abort

app = Flask(__name__)

# --- Logging Configuration ---
logging.basicConfig(level=logging.INFO)
formatter = logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s")
if not app.logger.handlers:
    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(formatter)
    app.logger.addHandler(stream_handler)
    app.logger.propagate = False
app.logger.setLevel(logging.INFO)

# --- Configuration ---
SERVICE_USER = "www-data"
SYSTEMCTL_PATH = "/bin/systemctl"
# **SECURITY**: Define allowed write directories *explicitly*
ALLOWED_WRITE_DIRS = [
    "/etc/systemd/system/"
]  # Add other paths like /etc/systemd/user/ if needed, with caution
# --- End Configuration ---


def run_systemctl(args, use_sudo=True, input_data=None):
    """Executes a systemctl command, optionally with sudo and input."""
    command = []
    is_root = os.geteuid() == 0
    should_use_sudo = use_sudo and not is_root

    if should_use_sudo:
        command.append("/usr/bin/sudo")

    # Handle cases where args might be a single command string or a list
    if isinstance(args, str):
        command.extend(shlex.split(args))  # Split string safely
    elif isinstance(args, list):
        # Ensure SYSTEMCTL_PATH is added if it's a systemctl command
        if (
            args[0] != SYSTEMCTL_PATH and args[0] != "/usr/bin/tee"
        ):  # Add systemctl path unless it's tee
            command.append(SYSTEMCTL_PATH)
        command.extend(args)
    else:
        raise ValueError("args must be a string or a list")

    command_str = " ".join(command)
    app.logger.debug(f"Running command: {command_str}")
    if input_data:
        app.logger.debug(f"Command Input Data (first 100 chars): {input_data[:100]}...")

    try:
        result = subprocess.run(
            command,
            input=input_data,  # Pass input data here
            capture_output=True,
            text=True,
            check=False,  # Handle non-zero exit manually
            timeout=20,  # Slightly longer timeout for potential writes
        )
        app.logger.info(
            f"Command finished: '{command_str}'. Return Code: {result.returncode}"
        )

        stdout_trimmed = result.stdout.strip()
        stderr_trimmed = result.stderr.strip()

        if result.returncode != 0:
            if stdout_trimmed:
                app.logger.warning(
                    f"Command STDOUT (non-zero exit):\n{stdout_trimmed[:1000]}"
                )
            if stderr_trimmed:
                app.logger.warning(
                    f"Command STDERR (non-zero exit):\n{stderr_trimmed[:1000]}"
                )
        elif app.logger.isEnabledFor(logging.DEBUG):
            if stdout_trimmed:
                app.logger.debug(
                    f"Command STDOUT (exit code 0):\n{stdout_trimmed[:1000]}"
                )
            if stderr_trimmed:
                app.logger.warning(
                    f"Command STDERR (exit code 0):\n{stderr_trimmed[:1000]}"
                )

        return result.returncode, result.stdout, result.stderr
    except FileNotFoundError:
        app.logger.error(f"Error: Command or path not found - {command_str}")
        return -1, "", f"Error: Command or path not found - {command_str}"
    except subprocess.TimeoutExpired:
        app.logger.error(f"Error: Command timed out - {command_str}")
        return -1, "", f"Error: Command timed out - {command_str}"
    except Exception as e:
        app.logger.error(f"Error running command {command_str}: {e}", exc_info=True)
        return -1, "", f"Error running command {command_str}: {e}"


def parse_list_units(output):
    """Parses the output of `systemctl list-units --type=service --all --no-legend`."""
    services = []
    lines = output.strip().split("\n")
    app.logger.info(
        f"Attempting to parse {len(lines)} lines from list-units output (assuming no header)."
    )
    parsed_count = 0
    skipped_count = 0
    for i, line in enumerate(lines):
        line = line.strip()
        if (
            not line
            or line.startswith("●")
            or line.lower().endswith("loaded units listed.")
            or line.startswith("LEGEND:")
            or line.startswith("To show")
            or line.startswith("Pass --all")
        ):
            skipped_count += 1
            continue
        parts = re.split(r"\s+", line, maxsplit=4)
        if len(parts) >= 5 and parts[0] and "." in parts[0]:
            try:
                service_data = {
                    "unit": parts[0],
                    "load": parts[1],
                    "active": parts[2],
                    "sub": parts[3],
                    "description": parts[4],
                    "enabled": "unknown",
                }
                services.append(service_data)
                parsed_count += 1
            except IndexError:
                skipped_count += 1
                app.logger.warning(f"IndexError parsing line {i}: '{line[:100]}...'")
        else:
            skipped_count += 1
            app.logger.debug(
                f"Skipping line {i} (doesn't look like service, parts={len(parts)}): '{line[:100]}...'"
            )
    app.logger.info(
        f"Finished parsing: {parsed_count} potential services found, {skipped_count} lines skipped."
    )
    if parsed_count == 0 and len(lines) > 0:
        app.logger.warning("Parsing found zero potential services.")
    return services


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/services", methods=["GET"])
def get_services():
    app.logger.info("API request received for /api/services")
    ret_code, stdout, stderr = run_systemctl(
        ["list-units", "--type=service", "--all", "--no-legend", "--no-pager"],
        use_sudo=True,
    )
    if ret_code != 0:
        return jsonify(
            {"error": f"Failed to list services via systemctl: {stderr or stdout}"}
        ), 500
    if app.logger.isEnabledFor(logging.DEBUG):
        app.logger.debug(f"Raw list-units STDOUT:\n{stdout}")
    services = parse_list_units(stdout)
    app.logger.info("Fetching enabled statuses...")
    enabled_status_map = {}
    ret_code_files, stdout_files, stderr_files = run_systemctl(
        ["list-unit-files", "--type=service", "--no-legend", "--no-pager"],
        use_sudo=True,
    )
    if ret_code_files == 0:
        parsed_enabled_count = 0
        lines = stdout_files.strip().split("\n")
        for line in lines:
            parts = re.split(r"\s+", line.strip(), maxsplit=1)
            if len(parts) == 2 and parts[0].endswith(".service"):
                enabled_status_map[parts[0]] = parts[1]
                parsed_enabled_count += 1
            elif line.strip() and not line.strip().endswith("unit files listed."):
                app.logger.warning(
                    f"Could not parse line from list-unit-files: '{line.strip()}'"
                )
        app.logger.info(f"Parsed {parsed_enabled_count} enabled statuses.")
    else:
        app.logger.error(f"Failed to list unit files: {stderr_files or stdout_files}")
    app.logger.info(f"Merging enabled status into {len(services)} services...")
    for service in services:
        service["enabled"] = enabled_status_map.get(service["unit"], "unknown")
    app.logger.info(f"Returning {len(services)} services to client.")
    return jsonify(services)


@app.route("/api/services/<service_name>/<action>", methods=["POST"])
def service_action(service_name, action):
    app.logger.info(f"API action request: Action='{action}', Service='{service_name}'")
    allowed_actions = ["start", "stop", "restart", "enable", "disable", "daemon-reload"]
    if action not in allowed_actions:
        abort(400, description="Invalid action.")
    if action != "daemon-reload" and not re.match(r"^[\w.\-@]+$", service_name):
        abort(400, description="Invalid service name format.")
    cmd_args = [action]
    display_name = "daemon" if action == "daemon-reload" else service_name
    if action != "daemon-reload":
        cmd_args.append(service_name)
    ret_code, stdout, stderr = run_systemctl(cmd_args, use_sudo=True)
    if ret_code != 0:
        err_msg = f"Action '{action}' failed for {display_name}: {stderr or stdout}"
        app.logger.error(err_msg)
        return jsonify({"error": err_msg}), 500
    else:
        success_msg = f"Action '{action}' successful for {display_name}."
        app.logger.info(success_msg)
        return jsonify({"success": success_msg, "output": stdout or stderr})


@app.route("/api/services/<service_name>/status", methods=["GET"])
def get_service_status(service_name):
    app.logger.info(f"API status request for: {service_name}")
    if not re.match(r"^[\w.\-@]+$", service_name):
        abort(400, description="Invalid service name format.")
    ret_code, stdout, stderr = run_systemctl(
        ["status", service_name, "--no-pager", "--full"], use_sudo=False
    )
    if ret_code != 0 and (
        "command not found" in stderr or "sudo" in stderr or "Error:" in stderr
    ):
        err_msg = f"Failed to execute status command for {service_name}: {stderr}"
        app.logger.error(err_msg)
        return jsonify({"error": err_msg}), 500
    elif ret_code != 0:
        app.logger.info(
            f"Status command for {service_name} returned non-zero ({ret_code})"
        )
    return jsonify({"status_output": stdout or stderr})


@app.route("/api/services/<service_name>/file", methods=["GET"])
def get_service_file(service_name):
    app.logger.info(f"API file content request for: {service_name}")
    if not re.match(r"^[\w.\-@]+$", service_name):
        abort(400, description="Invalid service name format.")
    app.logger.debug(f"Trying 'systemctl cat {service_name}'")
    ret_code_cat, stdout_cat, stderr_cat = run_systemctl(
        ["cat", service_name], use_sudo=True
    )
    if ret_code_cat == 0:
        app.logger.info(
            f"Successfully retrieved file content using 'systemctl cat {service_name}'"
        )
        file_path_info = "N/A (using systemctl cat)"
        if stdout_cat.startswith("# /"):
            try:
                file_path_info = stdout_cat.split("\n", 1)[0][2:].strip()
            except Exception:
                pass
        return jsonify({"file_content": stdout_cat, "file_path": file_path_info})
    app.logger.warning(
        f"'systemctl cat {service_name}' failed (code {ret_code_cat}). Error: {stderr_cat or stdout_cat}"
    )
    return jsonify(
        {"error": f"'systemctl cat {service_name}' failed: {stderr_cat or stdout_cat}"}
    ), 404  # Don't fallback if cat fails


# --- *** FILE EDITING ENDPOINT *** ---
@app.route("/api/services/<service_name>/file", methods=["POST"])
def update_service_file(service_name):
    """API endpoint to update service unit file content."""
    app.logger.info(f"API file update request for: {service_name}")
    if not re.match(r"^[\w.\-@]+$", service_name):
        abort(400, description="Invalid service name format.")

    data = request.get_json()
    if not data or "content" not in data:
        abort(400, description="Missing 'content' in request body.")
    new_content = data["content"]
    # Basic check for excessively large files (e.g., > 1MB)
    if len(new_content.encode("utf-8")) > 1024 * 1024:
        abort(400, description="File content too large (> 1MB).")

    # 1. Find the primary file path using `systemctl show`
    # We need the real path to write to, `cat` is not sufficient here.
    app.logger.debug(f"Finding primary fragment path for {service_name} using 'show'")
    ret_code_path, stdout_path, stderr_path = run_systemctl(
        ["show", "-p", "FragmentPath", "--value", service_name], use_sudo=True
    )

    if (
        ret_code_path != 0
        or not stdout_path.strip()
        or stdout_path.strip() == "/dev/null"
    ):
        err_msg = f"Could not determine unit file path for {service_name} using 'systemctl show': {stderr_path or stdout_path}"
        app.logger.error(err_msg)
        return jsonify({"error": err_msg}), 404
    file_path = os.path.normpath(
        stdout_path.strip()
    )  # Normalize path (removes trailing slashes, etc.)
    app.logger.info(f"Determined file path for writing: {file_path}")

    # **SECURITY: Validate the file path is within allowed directories**
    is_allowed = False
    # Use os.path.abspath to resolve any '..' potentially embedded
    abs_file_path = os.path.abspath(file_path)
    for allowed_dir in ALLOWED_WRITE_DIRS:
        abs_allowed_dir = os.path.abspath(allowed_dir)
        # Check if the absolute file path starts with the absolute allowed directory path
        if abs_file_path.startswith(abs_allowed_dir + os.sep):
            # Basic check against directory traversal using '..' (abspath helps, but check again)
            if ".." not in os.path.relpath(abs_file_path, abs_allowed_dir):
                is_allowed = True
                app.logger.info(
                    f"Path {abs_file_path} is within allowed directory {abs_allowed_dir}"
                )
                break  # Found an allowed directory
            else:
                app.logger.warning(
                    f"Path {abs_file_path} contains '..' relative to allowed dir {abs_allowed_dir}"
                )

    if not is_allowed:
        err_msg = f"Writing to path '{file_path}' (resolved to '{abs_file_path}') is not allowed by configuration."
        app.logger.error(err_msg)
        return jsonify({"error": err_msg}), 403  # Forbidden

    # **SECURITY**: Ensure the target is actually a file and not a directory, symlink (to prevent overwriting important things)
    # Note: This check happens *before* writing. If the file doesn't exist yet, this might fail.
    # We rely on `tee` failing if trying to write to a directory. Checking for symlinks is good practice.
    if os.path.islink(file_path):
        err_msg = (
            f"Target path '{file_path}' is a symbolic link. Writing aborted for safety."
        )
        app.logger.error(err_msg)
        return jsonify({"error": err_msg}), 403

    # 2. Write the file content using `sudo tee`
    app.logger.info(f"Attempting to write content to {file_path} using 'sudo tee'")
    tee_command = ["/usr/bin/tee", file_path]
    write_ret_code, write_stdout, write_stderr = run_systemctl(
        tee_command, use_sudo=True, input_data=new_content
    )

    if write_ret_code != 0:
        err_msg = (
            f"Failed to write to {file_path} using tee: {write_stderr or write_stdout}"
        )
        app.logger.error(err_msg)
        return jsonify({"error": err_msg}), 500

    app.logger.info(f"Successfully wrote content to {file_path}")

    # 3. Reload the systemd daemon
    app.logger.info("Running 'sudo systemctl daemon-reload' after file update")
    reload_ret, reload_out, reload_err = run_systemctl(["daemon-reload"], use_sudo=True)

    if reload_ret != 0:
        # File saved, but daemon reload failed - return warning (207 Multi-Status)
        warn_msg = f"File {file_path} saved, but daemon-reload failed: {reload_err or reload_out}"
        app.logger.warning(warn_msg)
        return jsonify({"warning": warn_msg, "file_path": file_path}), 207
    else:
        success_msg = f"File {file_path} updated successfully. Daemon reloaded."
        app.logger.info(success_msg)
        return jsonify(
            {
                "success": success_msg,
                "file_path": file_path,
                "output": reload_out or reload_err,
            }
        )


if __name__ == "__main__":
    app.logger.info("Starting Flask development server.")
    app.run(
        host="0.0.0.0", port=5001, debug=False
    )  # Keep debug=False for production testing
