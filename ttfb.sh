#!/usr/bin/env bash
#
# ttfb.sh - A script to measure time to first byte for one or more URLs
#
# Refactored and based on https://github.com/jaygooby/ttfb.sh
#
# Notes:
#   - To get a more "DevTools-like" TTFB (subtracting TLS handshake time), you can look at: %{time_starttransfer} - %{time_appconnect}
#   - Debug mode stores response headers in a log file. When multiple URLs or multiple requests
#     are tested, logs get concatenated into a single file per URL.
#   - Sorting and median calculation rely on 'bc' for arithmetic with decimal points, and 'column'
#     for tabular output.
#
# Usage:
#   ./ttfb.sh [options] url [url...]
#

set -eu  # Exit on error or undefined variable

# -----------------------------------------------------------------------
# Global Variables (populated during argument parsing)
# -----------------------------------------------------------------------
DEBUG_MODE=0
CUSTOM_LOG=""
NUM_REQUESTS=0
VERBOSE=0
CURL_OPTIONS=()
HTTP_VERSION=""
URLS=()

# -----------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------

# Show usage message
show_usage() {
  cat <<EOF
Usage: ttfb [options] url [url...]

Options:
  -d                Enable debug mode (logs response headers)
  -l <log file>     Specify a custom log file path (implies -d). Default: ./ttfb.log
  -n <number>       Number of times to test time to first byte
  -o <option>       Extra options to pass to curl
  -v                Verbose output: shows detailed timing breakdown

Examples:
  ttfb https://example.com
  ttfb -n 5 https://example.com
  ttfb -n 5 google.com google.se

EOF
}

# Ensure dependencies exist (curl, bc, column)
check_dependencies() {
    local dependencies=("curl" "bc" "column")
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo "Error: '$dep' must be installed and in your PATH." >&2
            exit 1
        fi
    done
}

# Configure locale so that 'bc' receives decimal points in a consistent format
configure_locale() {
    if locale -a 2>/dev/null | grep -q "^C.UTF-8$"; then
        export LC_ALL=C.UTF-8
    else
        export LC_ALL=C
    fi
}

# Check if curl can use HTTP/2; fallback to HTTP/1.1 if not
set_http_version() {
    if curl -so /dev/null --http2 https://example.com 2>/dev/null; then
        HTTP_VERSION="--http2"
    else
        HTTP_VERSION="--http1.1"
    fi
}

# Parse and validate command-line arguments
parse_arguments() {
    while getopts ":dl:n:o:v" opt; do
        case "${opt}" in
            d)
                DEBUG_MODE=1
                ;;
            l)
                CUSTOM_LOG="${OPTARG}"
                DEBUG_MODE=1  # Custom log path implies debug
                ;;
            n)
                NUM_REQUESTS="${OPTARG}"
                ;;
            o)
                # We store extra options in an array (splitting by xargs for multiple words)
                CURL_OPTIONS+=("$(echo "${OPTARG}" | xargs)")
                ;;
            v)
                VERBOSE=1
                ;;
            \?)
                show_usage
                exit 1
                ;;
        esac
    done
    shift $((OPTIND - 1))

    # Remaining args are URLs
    if [ $# -eq 0 ]; then
        show_usage
        exit 1
    fi
    URLS=("$@")

    # If no custom log provided, use the default
    if [ -z "${CUSTOM_LOG}" ]; then
        CUSTOM_LOG="./ttfb.log"
    fi
}

# Compute median from a list of numeric values
compute_median() {
    # Sort and store in array
    local arr=($(printf '%s\n' "$@" | sort -n))
    local count=${#arr[@]}
    local mid=$((count / 2))

    if ((count % 2 == 1)); then
        # Odd count, direct middle
        echo "${arr[$mid]}"
    else
        # Even count, average of the middle two
        local v1="${arr[$((mid - 1))]}"
        local v2="${arr[$mid]}"
        # bc for decimal arithmetic
        echo "scale=6; ($v1 + $v2)/2" | bc -l
    fi
}

# Performs a single curl request to measure TTFB and returns the
# entire timing breakdown line via stdout.
measure_single_request() {
    local url="$1"
    local log_file="$2"

    local command=(
        curl
        -o /dev/null
        -s
        -L
        "$HTTP_VERSION"
        -H "Cache-Control: no-cache"
        # The -w argument prints:
        #   DNS lookup: %{time_namelookup}
        #   TLS handshake: %{time_appconnect}
        #   TTFB including connection: %{time_starttransfer}
        #   TTFB (starttransfer - appconnect)
        #   Total time: %{time_total}
-w "echo DNS lookup: %{time_namelookup} TLS handshake: %{time_appconnect} \
TTFB including connection: %{time_starttransfer} \
TTFB: \$(echo %{time_starttransfer} - %{time_appconnect} | bc) \
Total time: %{time_total} \n"
    )

    # If debug is enabled, we want to capture headers
    if [ "${DEBUG_MODE}" -eq 1 ]; then
        command+=(-D "${log_file}")
    fi

    # Add any user-provided curl options
    command+=("${CURL_OPTIONS[@]}" "${url}")

    # Use 'eval' to allow in-string arithmetic expansions
    eval "$("${command[@]}")"
}

# Concatenate partial logs (when multiple requests or multiple URLs) into one
combine_logs() {
    local partial_pattern="$1"
    local final_file="$2"

    cat "${partial_pattern}"* > "${final_file}" 2>/dev/null || true
    rm -f "${partial_pattern}"* 2>/dev/null || true
}

# Process a single URL. If multiple requests are specified, measure multiple times.
# Print results in the requested format.
process_url() {
    local url="$1"
    local show_url=""
    local timing_results=()

    # If multiple URLs are given, prefix output with the URL itself
    if [ "${#URLS[@]}" -gt 1 ]; then
        show_url="${url}|"
    fi

    # Construct the debug log name for multi-URL scenarios
    # Replace non-alphanumeric characters with underscores
    local safe_url="${url//[^[:alnum:]]/_}"

    # If multiple requests are specified:
    if [ "${NUM_REQUESTS}" -gt 1 ]; then
        # Make multiple requests and store TTFB data
        for i in $(seq 1 "${NUM_REQUESTS}"); do
            # If debug, store logs with a suffix for each attempt
            local log_suffix=""
            if [ "${DEBUG_MODE}" -eq 1 ]; then
                log_suffix="${CUSTOM_LOG}_${i}"
                # If there's more than one URL, make it per-URL:
                [ "${#URLS[@]}" -gt 1 ] && log_suffix="${safe_url}-${log_suffix}"
            else
                # If debug is off, no suffix needed
                log_suffix="/dev/null"
            fi

            local result
            result="$(measure_single_request "${url}" "${log_suffix}")"
            # Extract just the TTFB portion: "TTFB: <value>"
            local ttfb_value
            ttfb_value="$(echo "${result}" | grep -oE 'TTFB: .{0,7}' | cut -d' ' -f2)"

            timing_results+=("${ttfb_value}")

            if [ "${VERBOSE}" -eq 1 ]; then
                echo "${result}" >&2
            else
                printf "." >&2
            fi
        done

        printf "\n" >&2

        # Combine partial logs (if any) into a single file
        if [ "${DEBUG_MODE}" -eq 1 ]; then
            local final_log="${CUSTOM_LOG}"
            [ "${#URLS[@]}" -gt 1 ] && final_log="${safe_url}-${CUSTOM_LOG}"
            combine_logs "${final_log}_" "${final_log}"
        fi

        # Sort TTFB array
        IFS=$'\n' timing_results=($(printf "%s\n" "${timing_results[@]}" | sort -n))
        unset IFS

        local fastest="${timing_results[0]}"
        local slowest="${timing_results[-1]}"
        local median_val
        median_val="$(compute_median "${timing_results[@]}")"

        echo -e "${show_url}\e[32mfastest \e[39m${fastest} \e[91mslowest \e[39m${slowest} \e[95mmedian \e[39m${median_val}\e[39m"
    else
        # Single request
        local single_result
        single_result="$(measure_single_request "${url}" "${CUSTOM_LOG}")"

        if [ "${VERBOSE}" -eq 1 ]; then
            echo -e "${show_url} ${single_result}"
        else
            local ttfb_value
            ttfb_value="$(echo "${single_result}" | grep -oE 'TTFB: .{0,7}' | cut -d' ' -f2)"
            echo -e "${show_url} ${ttfb_value}"
        fi
    fi
}

# Main entry point
main() {
    parse_arguments "$@"
    check_dependencies
    configure_locale
    set_http_version

    for url in "${URLS[@]}"; do
        process_url "${url}"
    done | column -s'|' -t
}

# Invoke main with all script arguments
main "$@"
