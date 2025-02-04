#!/usr/bin/env bash

set -euo pipefail

#
# s3-browser.sh - An interactive S3 browser to download a file or a folder using whiptail.
# © Jim Cronqvist <jim.cronqvist@gmail.com>
#
# Steps:
#   1) AWS Profile selection
#   2) S3 Bucket selection
#   3) Browse S3 bucket
#
# Also supports the following arguments to skip the interactive flow:
#   --profile <aws-profile>
#   --download
#   s3://bucket/prefix
#   <download-path>
#


################################################################################
# Pre-checks - Check dependencies
################################################################################

if ! command -v whiptail &>/dev/null; then
    echo "Error: whiptail not found. Please install 'whiptail' or 'newt'."
    exit 1
fi

if ! command -v aws &>/dev/null; then
    echo "Error: AWS CLI not found in PATH. Please install aws-cli."
    exit 1
fi

################################################################################
# GLOBALS
################################################################################

AWS_PROFILE=""            # Possibly set by --profile or interactively
AWS_CMD=("aws")           # Will be ["aws"] or ["aws" "--profile" "X"]

SELECTED_BUCKET=""        # Preset if s3://... was provided
PRESET_PREFIX=""          # Preset if s3://... was provided

SELECTED_PATH=""          # Final selection (file or folder)
SELECTED_ITEM_TYPE=""     # "file" or "folder"

FLAG_DOWNLOAD=false       # If --download was passed
FLAG_PRESIGN=false        # If --presign was passed
EXPIRES_IN=60             # Pre-sign expiration time in seconds, used with --presign
FLAG_LIST=false           # If --list was passed
FLAG_LATEST=false         # If --latest was passed

INTERACTIVE_MODE=true     # Will be set to false if --download and s3://... was provided

CURRENT_PATH="$(pwd)/"   # Default download path (current directory)
DOWNLOAD_PATH=""

################################################################################
# Print usage help
################################################################################

usage() {
    cat <<EOF
Usage:
  ${0##*/}                            # Fully interactive
  ${0##*/} --profile <aws-profile>    # Interactive, but sets profile to <PROF>
  ${0##*/} s3://bucket/prefix         # Interactive, but pre-select bucket+prefix
  ${0##*/} s3://bucket/prefix ./dst   # Interactive, but pre-select bucket+prefix and download to <download-path>
  ${0##*/} --download s3://...        # Immediately downloads the file or folder
  ${0##*/} --presign s3://...         # Immediately prints out the pre-sign url for s3 for the file
  ${0##*/} --list --latest s3://...   # Immediately print the latest folder or file path, can be used with --download
  ${0##*/} --profile <aws-profile> --download s3://... /tmp/dst # Immediately downloads the file or folder with the specified profile and download path

Options:
  --profile <PROF>    Use that AWS profile (only within this script)
  --download          Immediately download the file or folder (no menus)
  --presign           Immediately print out the pre-sign url for the file (no menus)
  --expires-in <NUM>  Set the expiration time for the pre-sign url in seconds (default: 60)
  --list              Immediately print a list of content in the path provided (no menus)
  --latest            Print the current path to the latest file or folder in the path provided, can be used with --download, otherwise print (no menus)
  -h, --help          Show this help
EOF
}

################################################################################
# Dynamically calculate height, width, and menu-height based on terminal size
# if available, and prints them as "<height> <width> <menu_height>".
################################################################################

calc_whiptail_size() {
    local term_rows=24
    local term_cols=80

    if command -v tput &>/dev/null; then
        local r c
        r=$(tput lines)
        c=$(tput cols)
        [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -gt 0 ] && term_rows="$r"
        [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt 0 ] && term_cols="$c"
    fi

    (( term_rows < 10 )) && term_rows=10
    (( term_cols < 40 )) && term_cols=40

    local dh=$(( term_rows - 4 ))
    local dw=$(( term_cols - 10 ))
    (( dh < 10 )) && dh=10
    (( dw < 40 )) && dw=40

    local dm=$(( dh - 8 ))
    (( dm < 5 )) && dm=5

    # echo them so the caller can insert them inline
    echo "$dh $dw $dm"
}

################################################################################
# A few standard helper functions
################################################################################

human_readable_size() {
    local bytes="$1"
    if   [ "$bytes" -lt 1024 ]; then echo "${bytes} B"
    elif [ "$bytes" -lt 1048576 ]; then echo "$(( bytes / 1024 )) KB"
    elif [ "$bytes" -lt 1073741824 ]; then echo "$(( bytes / 1048576 )) MB"
    else echo "$(( bytes / 1073741824 )) GB"
    fi
}

timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

################################################################################
# Helper function to parse an s3 path (s3://bucket/prefix)
# into SELECTED_BUCKET and PRESET_PREFIX
################################################################################

parse_s3_path() {
    local s3url="$1"
    local no_scheme="${s3url#s3://}"

    SELECTED_BUCKET="${no_scheme%%/*}"
    local remainder="${no_scheme#*/}"
    [ "$remainder" = "$no_scheme" ] && remainder=""
    PRESET_PREFIX="$remainder"
}

################################################################################
# Helper function to resolve a relative path to an absolute path
################################################################################

resolve_path() {
    local path="$1"

    # Remove the '~' at the beginning of the path
    path="$(echo "$path" | sed -e "s|^~\(\/.*\)$|$HOME\1|" -e "s|^~$|$HOME|")"

    # If the path is already absolute, return it
    if [[ "$path" == /* ]]; then
        echo "$path"
        return 0
    fi

    # Get the current working directory
    local current_dir
    current_dir=$(pwd)

    # Resolve the absolute path
    local resolved_path
    resolved_path="$current_dir/$path"

    # Remove occurrences of '/./' in the middle of the path
    resolved_path=$(echo "$resolved_path" | sed -e 's#/\./#/#g')

    # Remove './' at the beginning of the path
    resolved_path=$(echo "$resolved_path" | sed -e 's#^\./##')

    # Remove trailing '/.' but keep the '/'
    resolved_path=$(echo "$resolved_path" | sed -e 's#/\.$#/#')

    # Resolve '../' by removing the preceding directory
    resolved_path=$(echo "$resolved_path" | sed -e 's#/[^/][^/]*/\.\./#/#g')

    echo "$resolved_path"
}

################################################################################
# Configure AWS_CMD based on AWS_PROFILE (if set)
################################################################################

configure_aws_cmd() {
    if [ -n "$AWS_PROFILE" ]; then
        AWS_CMD=("aws" "--profile" "$AWS_PROFILE")
    else
        AWS_CMD=("aws")
    fi
}

################################################################################
# Choose an AWS profile if AWS_PROFILE is not set.
################################################################################

pick_profile() {
    # If the AWS_PROFILE is already set, skip.
    # Do we want to check this in the main loop instead? That way we can change profile even if one is set when called.
    if [ -n "$AWS_PROFILE" ]; then
        return 0
    fi
    # Kubernetes when 'eks.amazonaws.com/role-arn' is set, skip.
    if [ -n "${AWS_ROLE_ARN:-}" ] && [ -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ]; then
        return 0
    fi

    local local_profiles=()
    mapfile -t local_profiles < <(aws configure list-profiles 2>/dev/null)
    if [ ${#local_profiles[@]} -eq 0 ]; then
        # No local profiles found
        return 0
    fi

    local items=()
    for p in "${local_profiles[@]}"; do
        items+=("$p" " AWS Profile")
    done
    #items+=("QUIT" " Exit script")

    local choice
    choice=$(
        # shellcheck disable=SC2046
        whiptail --title "Select AWS Profile" \
                 --menu "Choose a profile" \
                 --default-item="${AWS_PROFILE:-default}" \
                 $(calc_whiptail_size) \
                 "${items[@]}" \
                 3>&1 1>&2 2>&3
    )
    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        return 1
    fi

    if [ "$choice" = "QUIT" ]; then
        return 2
    fi

    AWS_PROFILE="$choice"
    #export AWS_PROFILE="$AWS_PROFILE"
    return 0
}

################################################################################
# Choose a S3 bucket from a list of all buckets that the user has access to if
# SELECTED_BUCKET is not set.
################################################################################

pick_bucket() {
    if [ -n "$SELECTED_BUCKET" ]; then
        return 0
    fi

    local buckets=()
    mapfile -t buckets < <("${AWS_CMD[@]}" s3 ls 2>/dev/null | awk '{print $3}')
    if [ ${#buckets[@]} -eq 0 ]; then
        whiptail --title "ERROR (Profile: ${AWS_PROFILE:-NONE})" \
                 --msgbox "No S3 buckets found or accessible. Run 'aws configure' first." \
                 8 40
        return 1
    fi

    local items=("BACK" " Go Back to Profile Selection")
    for b in "${buckets[@]}"; do
        items+=("s3://$b" " Bucket")
    done

    local choice
    choice=$(
        # shellcheck disable=SC2046
        whiptail --title "Select S3 Bucket (Profile: ${AWS_PROFILE:-NONE})" \
                 --menu "Choose a bucket" \
                 $(calc_whiptail_size) \
                 "${items[@]}" \
                 3>&1 1>&2 2>&3
    )
    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        exit 2
    fi

    if [ "$choice" = "BACK" ]; then
        return 2
    fi

    # Strips any 's3://' prefix
    SELECTED_BUCKET="${choice#s3://}"
    return 0
}

################################################################################
# Browse the selected bucket and prefix (if set), and let the user pick a file
# or folder. Sets SELECTED_PATH and SELECTED_ITEM_TYPE=file|folder.
################################################################################

browse_bucket() {
    local current_prefix="$PRESET_PREFIX"

    while true; do
        local menu_items=()

        # If at root, allow to go back to previous menu
        if [ -z "$current_prefix" ]; then
            menu_items+=("BACK" " Go back to Bucket Selection")
        fi

        # If not root, allow to go up one folder level
        if [ -n "$current_prefix" ]; then
            menu_items+=("../" " Go up one prefix level")
        fi

        menu_items+=("./" " Download current folder")

        # List objects in current prefix
        local aws_cmd="${AWS_CMD[@]} s3 ls s3://${SELECTED_BUCKET}/${current_prefix}"
        local raw_list=()
        # Filter out empty objects (size=0) that may have been created in error, they do not seem to appear in the AWS s3 console either.
        mapfile -t raw_list < <($aws_cmd | awk '$3 != "0"' 2>/dev/null)
        #echo "$aws_cmd | awk '\$3 != \"0\"'"

        for line in "${raw_list[@]}"; do
            if [[ "$line" =~ ^.*PRE\ (.+)/$ ]]; then
                local folder_name="${BASH_REMATCH[1]}"
                menu_items+=("${folder_name}/" " Folder")
            else
                local size filename
                size=$(echo "$line" | awk '{print $3}')
                filename=$(echo "$line" | awk '{print $4}')
                menu_items+=("${filename}" " File ($(human_readable_size "$size"))")
            fi
        done

        local selection
        selection=$(
            # shellcheck disable=SC2046
            whiptail --title "Browsing: s3://${SELECTED_BUCKET}/${current_prefix}" \
                     --menu "Select an item" \
                     $(calc_whiptail_size) \
                     "${menu_items[@]}" \
                     3>&1 1>&2 2>&3
        )
        # shellcheck disable=SC2181
        if [ $? -ne 0 ]; then
            exit 2
        fi

        case "$selection" in
            "BACK")
                return 2
                ;;
            "../")
                local trimmed="${current_prefix%/}"
                if [[ "$trimmed" == *"/"* ]]; then
                    trimmed="${trimmed%/*}"
                    current_prefix="${trimmed}/"
                else
                    current_prefix=""
                fi
                ;;
            "./")
                # Current folder selected
                SELECTED_PATH="s3://${SELECTED_BUCKET}/${current_prefix}"
                [ -z "$current_prefix" ] && SELECTED_PATH="s3://${SELECTED_BUCKET}"
                SELECTED_ITEM_TYPE="folder"
                return 0
                ;;
            *)
                # A subfolder or file selected
                if [[ "$selection" == */ ]]; then
                    current_prefix="${current_prefix}${selection}"
                else
                    SELECTED_PATH="s3://${SELECTED_BUCKET}/${current_prefix}${selection}"
                    SELECTED_ITEM_TYPE="file"
                    return 0
                fi
                ;;
        esac
    done
}

################################################################################
# Parse script arguments and set globals accordingly, as well as show --help.
################################################################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile=*)
            AWS_PROFILE="${1#--profile=}"
            shift
            ;;
        --profile)
            shift
            AWS_PROFILE="$1"
            shift
            ;;
        --download)
            FLAG_DOWNLOAD=true
            INTERACTIVE_MODE=false # Skip interactive mode and proceed to download
            shift
            ;;
        --presign)
            FLAG_PRESIGN=true
            INTERACTIVE_MODE=false # Skip interactive mode and proceed to download
            shift
            ;;
        --expires-in=*)
            EXPIRES_IN="${1#--expires-in=}"
            shift
            ;;
        --expires-in)
            shift
            EXPIRES_IN="$1"
            shift
            ;;
        --list)
            FLAG_LIST=true
            INTERACTIVE_MODE=false # Skip interactive mode and proceed to list
            shift
            ;;
        --latest)
            FLAG_LATEST=true
            INTERACTIVE_MODE=false # Skip interactive mode and proceed to latest list/download
            shift
            ;;
        s3://*)
            parse_s3_path "$1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            # If it doesn't match any known option or start with s3://, we treat it as the destination path (unless we already have one).
            if [ -z "$DOWNLOAD_PATH" ]; then
                DOWNLOAD_PATH="$1"
                shift
            else
                echo "Error: Unknown argument '$1'"
                usage
                exit 1
            fi
            ;;
    esac
done

################################################################################
# Main flow - Non-interactive mode (s3://... must be provided)
################################################################################

if [ "$INTERACTIVE_MODE" = false ] && [ -n "$SELECTED_BUCKET" ]; then
    configure_aws_cmd

    SELECTED_PATH="s3://${SELECTED_BUCKET}/${PRESET_PREFIX}"
    if [[ -z "$PRESET_PREFIX" || "$PRESET_PREFIX" == */ ]]; then
        SELECTED_ITEM_TYPE="folder"

        if [ "$FLAG_LIST" = true ] || [ "$FLAG_LATEST" = true ]; then
            #echo "Running command: ${AWS_CMD[*]} s3 ls $SELECTED_PATH | awk '\$3 != \"0\"' | awk '{print \$4}' | sort"
            FILES="$("${AWS_CMD[@]}" s3 ls "$SELECTED_PATH" | awk '$3 != "0"' | awk '{print $4}' | sort)"

            if [ "$FLAG_LATEST" = true ] && [ "$SELECTED_ITEM_TYPE" = "folder" ]; then
                # Get the latest file in the folder, if it is a folder
                FILES="$(echo "${FILES[@]}" | tail -n 1)"
                SELECTED_PATH="s3://${SELECTED_BUCKET}/${PRESET_PREFIX}${FILES}"
                if [[ -z "$FILES" || "$FILES" != */ ]]; then
                    SELECTED_ITEM_TYPE="file"
                fi
            fi

            if [ "$FLAG_LIST" = true ]; then
                echo "$FILES"
                exit 0
            fi
        fi

        if [ "$FLAG_PRESIGN" = true ]; then
            if [ "$SELECTED_ITEM_TYPE" = "folder" ]; then
                echo "Error: Can't pre-sign a folder path. Exiting."
                exit 1
            fi
            # Validate that EXPIRES_IN is a positive integer within the range 60-604800
            if ! [[ "$EXPIRES_IN" =~ ^[0-9]+$ ]] || (( EXPIRES_IN < 60 || EXPIRES_IN > 604800 )); then
                echo "Error: --expires-in={\d} must be an integer within the range 60-604800, got '$EXPIRES_IN'. Exiting." >&2
                exit 1
            fi
            #echo "Running command: ${AWS_CMD[*]} s3 presign $SELECTED_PATH --expires-in $EXPIRES_IN"
            PRESIGNED_URL="$("${AWS_CMD[@]}" s3 presign "$SELECTED_PATH" --expires-in "$EXPIRES_IN")"
            echo "$PRESIGNED_URL"
            exit 0
        fi
    else
        SELECTED_ITEM_TYPE="file"
    fi
fi

################################################################################
# Main flow - Interactive mode
################################################################################

while $INTERACTIVE_MODE; do
    # 1) pick_profile
    if ! pick_profile; then
        # User did not pick an AWS profile. Exiting."
        exit 1
    fi
    configure_aws_cmd

    # 2) pick_bucket
    while true; do
        if ! pick_bucket; then
            # user pressed BACK -> re-pick profile
            SELECTED_BUCKET=""
            AWS_PROFILE=""
            break
        fi

        # 3) browse_bucket
        if ! browse_bucket; then
            # user pressed BACK -> re-pick bucket
            SELECTED_PATH=""
            SELECTED_ITEM_TYPE=""
            SELECTED_BUCKET=""
            continue
        fi

        # A file or folder was successfully selected, we can break, and proceed to download
        break 2
    done
done

################################################################################
# Download the file or folder from S3
################################################################################

if [ -z "$SELECTED_PATH" ] || [ -z "$SELECTED_ITEM_TYPE" ]; then
    echo "Error: No file or folder selected. Exiting."
    exit 1
fi

# Set a sane default download path if none is provided, no matter which mode we are in.
if [ -z "$DOWNLOAD_PATH" ]; then
    DOWNLOAD_PATH="${CURRENT_PATH}$(basename "$SELECTED_PATH")"
    if [ "$SELECTED_ITEM_TYPE" = "folder" ]; then
        DOWNLOAD_PATH="$DOWNLOAD_PATH/"
    fi
fi

# If interactive mode, allow the user to change the download path
if [ $INTERACTIVE_MODE = true ]; then
    read -r -e -i "$DOWNLOAD_PATH" -p "Enter $SELECTED_ITEM_TYPE download path: " DOWNLOAD_PATH
    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        exit 2
    fi
    if [ -z "$DOWNLOAD_PATH" ]; then
        echo "Error: No download path provided. Exiting"
        exit 1
    fi
fi

# Resolve the download path to an absolute path
DOWNLOAD_PATH=$(resolve_path "$DOWNLOAD_PATH")

# Sanity check the download path (must be a directory if downloading a folder)
if [ "$SELECTED_ITEM_TYPE" = "folder" ] && [ "$DOWNLOAD_PATH" = "${DOWNLOAD_PATH%%/}" ]; then
    DOWNLOAD_PATH="${DOWNLOAD_PATH}/"
fi

# Ensure the download path exists
if [[ "$DOWNLOAD_PATH" == */ ]]; then
    mkdir -p "$DOWNLOAD_PATH"
else
    mkdir -p "$(dirname "$DOWNLOAD_PATH")/"
fi

# Download the file or folder
START=$(date +%s)
if [ "$SELECTED_ITEM_TYPE" = "file" ]; then
    echo "Downloading the file at '$SELECTED_PATH' to '$DOWNLOAD_PATH'..."
    echo "Running command: ${AWS_CMD[*]}" s3 cp "$SELECTED_PATH" "$DOWNLOAD_PATH"
    "${AWS_CMD[@]}" s3 cp "$SELECTED_PATH" "$DOWNLOAD_PATH"
else
    echo "Downloading the folder at '$SELECTED_PATH' to '$DOWNLOAD_PATH'..."
    echo "Running command: ${AWS_CMD[*]}" s3 sync "$SELECTED_PATH" "$DOWNLOAD_PATH"
    "${AWS_CMD[@]}" s3 sync "$SELECTED_PATH" "$DOWNLOAD_PATH"
fi
END=$(date +%s)
SECONDS=$((END-START))

################################################################################
# All done!
################################################################################

echo ""
echo "Source path:   $SELECTED_PATH"
echo "Download path: $DOWNLOAD_PATH"
echo "Download time: $SECONDS seconds, finished at $(timestamp)"
echo ""
echo "Download completed!"

exit 0
