#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

DB_NAME=""
IF_EXISTS=0
DRY_RUN=0
YES=0
VERBOSE=0

MYSQL_ARGS=()

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [script options] <database> [-- mysql options]

Drops a MySQL database.

Script options:
  --if-exists              Use DROP DATABASE IF EXISTS.

  --dry-run                Print the SQL and mysql command without executing.
  --yes                    Skip confirmation prompt.
  --verbose                Print extra details.

  -h, --help               Show this help.

MySQL options:
  Put mysql client options after --.

Examples:
  $SCRIPT_NAME my_app --dry-run -- --login-path=local

  $SCRIPT_NAME my_app \\
    --if-exists \\
    --yes \\
    -- \\
    --login-path=prod

  $SCRIPT_NAME my_app \\
    --yes \\
    -- \\
    --host=127.0.0.1 \\
    --user=root

Notes:
  - MySQL connection options must go after --.
  - Do not pass -e or --execute after --; this script generates the SQL.
  - Database names are limited to letters, numbers, and underscores.
  - This script refuses to drop MySQL system databases.
EOF
}

error() {
    echo "Error: $*" >&2
    exit 1
}

log() {
    if [[ "$VERBOSE" -eq 1 ]]; then
        echo "$*"
    fi
}

shell_quote() {
    local value="$1"

    # Leave simple arguments unquoted.
    if [[ "$value" =~ ^[a-zA-Z0-9_./:=@%+,-]+$ ]]; then
        printf '%s' "$value"
        return
    fi

    # Otherwise wrap in single quotes and escape embedded single quotes.
    printf "'"
    printf '%s' "$value" | sed "s/'/'\\\\''/g"
    printf "'"
}

print_mysql_command() {
    local sql="$1"
    local arg

    printf 'mysql'

    for arg in "${MYSQL_ARGS[@]}"; do
        printf ' '
        shell_quote "$arg"
    done

    printf ' -e '
    shell_quote "$sql"
    printf '\n'
}

quote_identifier() {
    local value="$1"

    # Escape backticks inside identifiers, then wrap in backticks.
    # The current validation prevents backticks, but this keeps the function safe.
    printf '`%s`' "${value//\`/\`\`}"
}

validate_db_name() {
    local value="$1"
    local lower_value="${value,,}"

    if [[ -z "$value" ]]; then
        error "Database name cannot be empty."
    fi

    if [[ ${#value} -gt 64 ]]; then
        error "Database name '$value' is too long. Maximum length is 64 characters."
    fi

    if [[ ! "$value" =~ ^[a-zA-Z0-9_]+$ ]]; then
        error "Invalid database name '$value'. Only letters, numbers, and underscores are allowed."
    fi

    case "$lower_value" in
        mysql|information_schema|performance_schema|sys)
            error "Refusing to drop protected system database '$value'."
            ;;
    esac
}

validate_mysql_passthrough_args() {
    local arg

    for arg in "${MYSQL_ARGS[@]}"; do
        case "$arg" in
            -e|-e?*|--execute|--execute=*)
                error "Do not pass '$arg' after --. This script provides its own SQL via mysql -e."
                ;;
        esac
    done
}

normalize_mysql_host_args() {
    local -a normalized_args=()
    local arg
    local next
    local host
    local i=0

    while [[ "$i" -lt "${#MYSQL_ARGS[@]}" ]]; do
        arg="${MYSQL_ARGS[$i]}"

        case "$arg" in
            --host=*)
                host="${arg#*=}"

                if [[ "${host,,}" == "localhost" ]]; then
                    normalized_args+=("--host=127.0.0.1")
                    log "Changed MySQL host from localhost to 127.0.0.1."
                else
                    normalized_args+=("$arg")
                fi
                ;;

            --host)
                normalized_args+=("$arg")

                if [[ $((i + 1)) -lt ${#MYSQL_ARGS[@]} ]]; then
                    next="${MYSQL_ARGS[$((i + 1))]}"

                    if [[ "${next,,}" == "localhost" ]]; then
                        normalized_args+=("127.0.0.1")
                        log "Changed MySQL host from localhost to 127.0.0.1."
                    else
                        normalized_args+=("$next")
                    fi

                    i=$((i + 1))
                fi
                ;;

            -h)
                normalized_args+=("$arg")

                if [[ $((i + 1)) -lt ${#MYSQL_ARGS[@]} ]]; then
                    next="${MYSQL_ARGS[$((i + 1))]}"

                    if [[ "${next,,}" == "localhost" ]]; then
                        normalized_args+=("127.0.0.1")
                        log "Changed MySQL host from localhost to 127.0.0.1."
                    else
                        normalized_args+=("$next")
                    fi

                    i=$((i + 1))
                fi
                ;;

            -h*)
                host="${arg#-h}"

                if [[ "${host,,}" == "localhost" ]]; then
                    normalized_args+=("-h127.0.0.1")
                    log "Changed MySQL host from localhost to 127.0.0.1."
                else
                    normalized_args+=("$arg")
                fi
                ;;

            *)
                normalized_args+=("$arg")
                ;;
        esac

        i=$((i + 1))
    done

    MYSQL_ARGS=("${normalized_args[@]}")
}

confirm_drop() {
    local answer=""

    if [[ "$YES" -eq 1 ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        error "Confirmation required, but stdin is not interactive. Re-run with --yes to execute non-interactively."
    fi

    echo "You are about to permanently drop this database:"
    echo
    echo "  $DB_NAME"
    echo
    echo "This cannot be undone."
    echo

    read -r -p "Type the database name to confirm: " answer

    if [[ "$answer" != "$DB_NAME" ]]; then
        echo "Aborted."
        exit 0
    fi
}

parse_args() {
    local passthrough=0

    while [[ $# -gt 0 ]]; do
        if [[ "$passthrough" -eq 1 ]]; then
            MYSQL_ARGS+=("$1")
            shift
            continue
        fi

        case "$1" in
            --)
                passthrough=1
                shift
                ;;

            --if-exists)
                IF_EXISTS=1
                shift
                ;;

            --dry-run)
                DRY_RUN=1
                shift
                ;;

            --yes|-y)
                YES=1
                shift
                ;;

            --verbose|-v)
                VERBOSE=1
                shift
                ;;

            --help|-h)
                usage
                exit 0
                ;;

            -*)
                error "Unknown script option '$1'. MySQL options must be placed after --."
                ;;

            *)
                if [[ -n "$DB_NAME" ]]; then
                    error "Only one database name may be provided. Already got '$DB_NAME', then got '$1'."
                fi

                DB_NAME="$1"
                shift
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    if [[ -z "$DB_NAME" ]]; then
        usage
        exit 1
    fi

    validate_db_name "$DB_NAME"
    normalize_mysql_host_args
    validate_mysql_passthrough_args

    local quoted_db
    quoted_db="$(quote_identifier "$DB_NAME")"

    local if_exists_sql=""
    if [[ "$IF_EXISTS" -eq 1 ]]; then
        if_exists_sql=" IF EXISTS"
    fi

    local sql
    sql="DROP DATABASE${if_exists_sql} ${quoted_db};"

    if [[ "$VERBOSE" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
        echo "Database: $DB_NAME"
        echo

        echo "SQL:"
        echo "$sql"
        echo
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "Command:"
        print_mysql_command "$sql"
        exit 0
    fi

    if ! command -v mysql >/dev/null 2>&1; then
        error "mysql client was not found in PATH."
    fi

    log "mysql client found."

    confirm_drop

    mysql "${MYSQL_ARGS[@]}" -e "$sql"

    if [[ "$IF_EXISTS" -eq 1 ]]; then
        echo "Drop command completed for database '$DB_NAME'."
    else
        echo "Dropped database '$DB_NAME'."
    fi
}

main "$@"