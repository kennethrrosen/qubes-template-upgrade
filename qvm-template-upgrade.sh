#!/bin/bash
#
# Qubes OS Template Upgrade Script
# Supports Fedora and Debian Templates
# https://www.kennethrrosen.cloud
#
# Copyright (C) 2024 by Kenneth R. Rosen
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License; 
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

set -o nounset -o errexit
set -o noglob

PREFIX="$(tput setaf 7)$(tput bold)"
YELLOW="$(tput setaf 3)$(tput bold)"
POSTFIX="$(tput sgr0)"

usage() {
    cat >&2 <<EOF
Usage: ${0##*/} TEMPLATE [OPTIONS]...

A script for upgrading templates in Qubes OS.

Arguments:
  TEMPLATE           Name of the template to upgrade. Required.

Options:
  -h, --help         Display this help and exit.
  -c, --clone        Clone the template before upgrading. Optional.
  -N, --new-template New template name. Required if cloning.

Examples:
  1. Upgrade a template or StandaloneVM 
     ${0##*/} TEMPLATE

  2. Upgrade a template or StandaloneVM, keeping original and cloning into a new template or StandaloneVM which will be upgraded:
     ${0##*/} TEMPLATE --clone --new-template=TEMPLATENEW

EOF
}

# Initialize variables for options
clone=""
new_template_name=""

# Check for required positional arguments
if [ $# -lt 1 ]; then
    echo "Error: TEMPLATE is required." >&2
    usage
    exit 1
fi

template=$1
shift

# Use getopt for robust argument parsing
OPTS=$(getopt -o hcN: --long help,clone,new-template: -n 'parse-options' -- "$@")
if [ $? != 0 ]; then
    usage
    exit 1
fi
eval set -- "$OPTS"

# Process options
while true; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--clone)
            clone="y"
            shift
            ;;
        -N|--new-template)
            new_template_name="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

message() {
    echo "${PREFIX}${1}${POSTFIX}"
}

handle_error() {
    local exit_code=$?
    local last_command=$(history | tail -n 1 | sed -e 's/^[ ]*[0-9]\+[ ]*//')
    echo "An error occurred. Exiting with code $exit_code. The last command was: $last_command"
    exit $exit_code
}

trap 'handle_error' ERR

get_template_type() {
    local template=$1
    local type
    type=$(qvm-features "$template" os-distribution 2>/dev/null || qvm-run -p "$template" "cat /etc/os-release | grep ^ID=" | cut -d'=' -f2) || {
        echo "unknown"
        exit 1
    }
    if [[ -z "$type" || "$type" == "unknown" ]]; then
        echo "Error: Could not determine template type for $template. It might be EOL." >&2
        exit 1
    fi
    echo "$type"
}

get_template_version() {
    local template=$1
    local version
    version=$(qvm-features "$template" os-version 2>/dev/null || 
              qvm-run -p "$template" "grep -oP '\d+' /etc/fedora-release" 2>/dev/null || 
              qvm-run -p "$template" "grep ^VERSION_CODENAME= /etc/os-release | cut -d'=' -f2" 2>/dev/null || 
              qvm-run -p "$template" "cat /etc/debian_version" 2>/dev/null) || {
        echo "unknown"
        exit 1
    }
    if [[ -z "$version" || "$version" == "unknown" ]]; then
        echo "Error: Could not determine template version for $template. It might be EOL." >&2
        exit 1
    fi
    echo "$version"
}

next_debian_version() {
    local current_version=$1
    case $current_version in
        buster) echo "bullseye" ;;
        bullseye) echo "bookworm" ;;
        bookworm) echo "trixie" ;;
        trixie) echo "fornextversion" ;;  # Update with the next version as necessary
        *) echo "unknown" ;;
    esac
}

upgrade_debian_template() {
    local template=$1
    local clone=$2
    local new_template_name=$3
    local old_name=$4
    local new_name=$5

    if [[ "$clone" == "y" && -z "$new_template_name" ]]; then
        message "Error: New template name required when cloning."
        exit 1
    elif [[ "$clone" == "y" ]]; then
        message "Cloning $template to $new_template_name..."
        if ! qvm-clone "$template" "$new_template_name"; then
            message "Failed to clone template. Exiting."
            exit 1
        fi
        template="$new_template_name"
    fi

    message "Upgrading $template from $old_name to $new_name..."
    qvm-start --skip-if-running "$template"

    message "Updating APT repositories..."
    qvm-run -u root "$template" "sed -i 's/$old_name/$new_name/g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list"

    message "Performing upgrade. Patience..."
    qvm-run -p -u root "$template" "apt update && apt full-upgrade -y && apt autoremove -y && apt clean"

    message "Trimming the new template..."
    qvm-run -u root "$template" "fstrim -av"

    message "Shutting down $template..."
    qvm-shutdown --wait "$template"

    message "Upgrade to $new_name completed successfully for $template."
}

upgrade_fedora_template() {
    local template=$1
    local clone=$2
    local new_template_name=$3
    local current_num=$4
    local new_num=$((current_num + 1))

    if [[ $clone == "y" ]]; then
        message "Cloning $template to $new_template_name..."
        qvm-clone "$template" "$new_template_name"
        template="$new_template_name"
    else
        new_template_name="$template"
    fi

    message "Performing upgrade. Patience..."
    qvm-start --skip-if-running "$template"
    qvm-run -p -u root "$template" "dnf clean all && dnf --releasever=$new_num distro-sync --best --allowerasing -y && dnf update -y && dnf upgrade -y"

    message "Shutting down $template..."
    qvm-shutdown --wait "$template"

    message "Upgrade completed successfully for $template."
}

change_qvm_features() {
    qvm-run -u root "$template" qubes.PostInstall
}

if ! type qvm-ls >/dev/null 2>&1; then
    echo "This script is intended to run in a Qubes OS environment." >&2
    exit 1
fi

message "Determining template type and version..."
template_type=$(get_template_type "$template")
template_version=$(get_template_version "$template")

message "Template type: $template_type"
message "Template version: $template_version"

if [[ -z "$template_type" || "$template_type" == "unknown" ]]; then
    echo "Error: Could not determine template type for $template." >&2
    exit 1
fi

if [[ -z "$template_version" || "$template_version" == "unknown" ]]; then
    echo "Error: Could not determine template version for $template." >&2
    exit 1
fi

if [[ "$template_type" == "debian" ]]; then
    new_name=$(next_debian_version "$template_version")
    if [[ "$new_name" == "unknown" ]]; then
        echo "Error: Unknown Debian version." >&2
        exit 1
    fi
    upgrade_debian_template "$template" "$clone" "$new_template_name" "$template_version" "$new_name"
    change_qvm_features "$template" "$new_template_name"
elif [[ "$template_type" == "fedora" ]]; then
    upgrade_fedora_template "$template" "$clone" "$new_template_name" "$template_version"
    change_qvm_features "$template" "$new_template_name"
else
    echo "Error: Unsupported template type. Use 'debian' or 'fedora'." >&2
    usage
    exit 1
fi