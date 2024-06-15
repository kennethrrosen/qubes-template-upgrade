#!/usr/bin/env python3

import sys
import argparse
import subprocess

# ANSI escape codes for colored output
PREFIX = "\033[1;37m"
YELLOW = "\033[1;33m"
POSTFIX = "\033[0m"

def message(text):
    print(f"{PREFIX}{text}{POSTFIX}")

def handle_error():
    exc_type, exc_value, exc_traceback = sys.exc_info()
    print(f"An error occurred: {exc_value}")
    sys.exit(1)

def usage():
    return """Usage: upgrade_template.py TEMPLATE [OPTIONS]...

A script for upgrading templates in Qubes OS.

Arguments:
  TEMPLATE           Name of the template to upgrade. Required.

Options:
  -h, --help         Display this help and exit.
  -c, --clone        Clone the template before upgrading. Optional.
  -N, --new-template New template name. Required if cloning.

Examples:
  1. Upgrade a template or StandaloneVM 
     upgrade_template.py TEMPLATE

  2. Upgrade a template or StandaloneVM, keeping original and cloning into a new template or StandaloneVM which will be upgraded:
     upgrade_template.py TEMPLATE --clone --new-template TEMPLATENEW
"""

def run_command(command):
    result = subprocess.run(command, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip())
    return result.stdout.strip()

def get_template_type(template):
    try:
        type = run_command(f"qvm-features {template} os-distribution")
        if not type:
            type = run_command(f"qvm-run -p {template} 'grep ^ID= /etc/os-release' | cut -d'=' -f2")
    except RuntimeError:
        type = "unknown"
    if not type or type == "unknown":
        raise ValueError(f"Could not determine template type for {template}. It might be EOL.")
    return type

def get_template_version(template):
    try:
        version = run_command(f"qvm-features {template} os-version")
        if not version:
            version = run_command(f"qvm-run -p {template} 'grep -oP '\\d+' /etc/fedora-release'")
        if not version:
            version = run_command(f"qvm-run -p {template} 'grep ^VERSION_CODENAME= /etc/os-release' | cut -d'=' -f2")
        if not version:
            version = run_command(f"qvm-run -p {template} 'cat /etc/debian_version'")
    except RuntimeError:
        version = "unknown"
    if not version or version == "unknown":
        raise ValueError(f"Could not determine template version for {template}. It might be EOL.")
    return version

def next_debian_version(current_version):
    versions = {
        "buster": "bullseye",
        "bullseye": "bookworm",
        "bookworm": "trixie",
        "trixie": "fornextversion"
    }
    return versions.get(current_version, "unknown")

def upgrade_debian_template(template, clone, new_template_name, old_name, new_name):
    if clone and not new_template_name:
        raise ValueError("New template name required when cloning.")
    elif clone:
        message(f"Cloning {template} to {new_template_name}...")
        run_command(f"qvm-clone {template} {new_template_name}")
        template = new_template_name

    message(f"Upgrading {template} from {old_name} to {new_name}...")
    run_command(f"qvm-start --skip-if-running {template}")

    message("Updating APT repositories...")
    run_command(f"qvm-run -u root {template} 'sed -i s/{old_name}/{new_name}/g /etc/apt/sources.list /etc/apt/sources.list.d/*.list'")

    message("Performing upgrade. Patience...")
    run_command(f"qvm-run -p -u root {template} 'apt update && apt full-upgrade -y && apt autoremove -y && apt clean'")

    message("Trimming the new template...")
    run_command(f"qvm-run -u root {template} 'fstrim -av'")

    message(f"Shutting down {template}...")
    run_command(f"qvm-shutdown --wait {template}")

    message(f"Upgrade to {new_name} completed successfully for {template}.")

def upgrade_fedora_template(template, clone, new_template_name, current_num):
    new_num = int(current_num) + 1
    if clone:
        message(f"Cloning {template} to {new_template_name}...")
        run_command(f"qvm-clone {template} {new_template_name}")
        template = new_template_name

    message("Performing upgrade. Patience...")
    run_command(f"qvm-start --skip-if-running {template}")
    run_command(f"qvm-run -p -u root {template} 'dnf clean all && dnf --releasever={new_num} distro-sync --best --allowerasing -y && dnf update -y && dnf upgrade -y'")

    message(f"Shutting down {template}...")
    run_command(f"qvm-shutdown --wait {template}")

    message(f"Upgrade completed successfully for {template}.")

def change_qvm_features(template, new_template_name):
    run_command(f"qvm-run -u root {template} qubes.PostInstall")

def main():
    try:
        parser = argparse.ArgumentParser(description="Upgrade Qubes OS templates.", usage=usage())
        parser.add_argument("template", help="Name of the template to upgrade.")
        parser.add_argument("-c", "--clone", action="store_true", help="Clone the template before upgrading.")
        parser.add_argument("-N", "--new-template", help="New template name. Required if cloning.")
        args = parser.parse_args()

        if not run_command("type qvm-ls"):
            print("This script is intended to run in a Qubes OS environment.", file=sys.stderr)
            sys.exit(1)

        message("Determining template type and version...")
        template_type = get_template_type(args.template)
        template_version = get_template_version(args.template)

        message(f"Template type: {template_type}")
        message(f"Template version: {template_version}")

        if template_type == "debian":
            new_name = next_debian_version(template_version)
            if new_name == "unknown":
                raise ValueError("Unknown Debian version.")
            upgrade_debian_template(args.template, args.clone, args.new_template, template_version, new_name)
            change_qvm_features(args.template, args.new_template)
        elif template_type == "fedora":
            upgrade_fedora_template(args.template, args.clone, args.new_template, template_version)
            change_qvm_features(args.template, args.new_template)
        else:
            print("Error: Unsupported template type. Use 'debian' or 'fedora'.", file=sys.stderr)
            parser.print_usage()
            sys.exit(1)

    except Exception:
        handle_error()

if __name__ == "__main__":
    main()
