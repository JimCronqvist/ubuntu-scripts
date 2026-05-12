#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR_SQL="${GENERATOR_SQL:-$SCRIPT_DIR/sql/mysql/generate_rename_db.sql}"

OLD_DB=""
NEW_DB=""
DRY_RUN=0
YES=0
VERBOSE=0
COPY_GRANTS=0
REVOKE_OLD_GRANTS=0

MYSQL_ARGS=()

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [script options] <old_database> <new_database> [-- mysql options]

Renames a MySQL database by generating and executing SQL from:
  $GENERATOR_SQL

Script options:
  --copy-grants           Copy grants from old_database.* and old objects to
                          the new database/objects.

  --revoke-old-grants     Revoke grants from old_database.* and old objects.

  --rename-grants         Shortcut for --copy-grants and --revoke-old-grants.

  --dry-run               Print generated SQL without executing.
  --yes                   Skip confirmation prompt.
  --verbose               Print extra details.

  -h, --help              Show this help.

MySQL options:
  Put mysql client options after --.

Examples:
  $SCRIPT_NAME old_app new_app --dry-run -- --login-path=local

  $SCRIPT_NAME old_app new_app \\
    --rename-grants \\
    --yes \\
    -- \\
    --login-path=prod

Notes:
  - MySQL connection options must go after --.
  - Do not pass -e, --execute, -f, or --force after --.
  - Database names are limited to letters, numbers, and underscores.
  - localhost passed as a MySQL host is normalized to 127.0.0.1.
  - The old database is dropped only after the wrapper verifies it has no
    remaining tables, views, routines, triggers, or events.
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

print_mysql_command_stdin() {
    local input_name="$1"
    local arg

    printf 'mysql'

    for arg in "${MYSQL_ARGS[@]}"; do
        printf ' '
        shell_quote "$arg"
    done

    printf ' < '
    shell_quote "$input_name"
    printf '\n'
}

quote_identifier() {
    local value="$1"

    # Escape backticks inside identifiers, then wrap in backticks.
    printf '`%s`' "${value//\`/\`\`}"
}

sql_string_literal() {
    local value="$1"

    # Escape single quotes for SQL string literals.
    printf "'%s'" "${value//\'/\'\'}"
}

validate_db_name() {
    local label="$1"
    local value="$2"
    local lower_value="${value,,}"

    if [[ -z "$value" ]]; then
        error "$label database name cannot be empty."
    fi

    if [[ ${#value} -gt 64 ]]; then
        error "$label database name '$value' is too long. Maximum length is 64 characters."
    fi

    if [[ ! "$value" =~ ^[a-zA-Z0-9_]+$ ]]; then
        error "Invalid $label database name '$value'. Only letters, numbers, and underscores are allowed."
    fi

    case "$lower_value" in
        mysql|information_schema|performance_schema|sys)
            error "Refusing to use protected system database '$value' as the $label database."
            ;;
    esac
}

validate_mysql_passthrough_args() {
    local arg

    for arg in "${MYSQL_ARGS[@]}"; do
        case "$arg" in
            -e|-e?*|--execute|--execute=*)
                error "Do not pass '$arg' after --. This script provides its own SQL."
                ;;
            -f|--force)
                error "Do not pass '$arg' after --. This script must fail immediately on SQL errors."
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

            --copy-grants)
                COPY_GRANTS=1
                shift
                ;;

            --revoke-old-grants)
                REVOKE_OLD_GRANTS=1
                shift
                ;;

            --rename-grants)
                COPY_GRANTS=1
                REVOKE_OLD_GRANTS=1
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
                if [[ -z "$OLD_DB" ]]; then
                    OLD_DB="$1"
                elif [[ -z "$NEW_DB" ]]; then
                    NEW_DB="$1"
                else
                    error "Only two database names may be provided. Already got '$OLD_DB' and '$NEW_DB', then got '$1'."
                fi

                shift
                ;;
        esac
    done
}

mysql_scalar() {
    local sql="$1"

    mysql "${MYSQL_ARGS[@]}" \
        --batch \
        --raw \
        --skip-column-names \
        -e "$sql"
}

database_exists() {
    local db_name="$1"
    local db_literal
    local count

    db_literal="$(sql_string_literal "$db_name")"
    count="$(mysql_scalar "SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = ${db_literal};")"

    [[ "$count" == "1" ]]
}

old_db_remaining_count() {
    local old_db_literal

    old_db_literal="$(sql_string_literal "$OLD_DB")"

    mysql_scalar "
        SELECT
            (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ${old_db_literal}) +
            (SELECT COUNT(*) FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_SCHEMA = ${old_db_literal}) +
            (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TRIGGERS WHERE TRIGGER_SCHEMA = ${old_db_literal}) +
            (SELECT COUNT(*) FROM INFORMATION_SCHEMA.EVENTS WHERE EVENT_SCHEMA = ${old_db_literal});
    "
}

print_object_summary() {
    local old_db_literal

    old_db_literal="$(sql_string_literal "$OLD_DB")"

    echo "Object summary for '$OLD_DB':"
    mysql "${MYSQL_ARGS[@]}" --batch --raw --table <<SQL
SELECT 'base tables' AS object_type, COUNT(*) AS count
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = ${old_db_literal}
  AND TABLE_TYPE = 'BASE TABLE'
UNION ALL
SELECT 'views', COUNT(*)
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = ${old_db_literal}
  AND TABLE_TYPE = 'VIEW'
UNION ALL
SELECT 'triggers', COUNT(*)
FROM INFORMATION_SCHEMA.TRIGGERS
WHERE TRIGGER_SCHEMA = ${old_db_literal}
UNION ALL
SELECT 'procedures/functions', COUNT(*)
FROM INFORMATION_SCHEMA.ROUTINES
WHERE ROUTINE_SCHEMA = ${old_db_literal}
UNION ALL
SELECT 'events', COUNT(*)
FROM INFORMATION_SCHEMA.EVENTS
WHERE EVENT_SCHEMA = ${old_db_literal};
SQL
}

generate_rename_sql() {
    [[ -f "$GENERATOR_SQL" ]] || error "Generator SQL file not found: $GENERATOR_SQL"

    {
        printf 'SET @oldDb = %s;\n' "$(sql_string_literal "$OLD_DB")"
        printf 'SET @newDb = %s;\n' "$(sql_string_literal "$NEW_DB")"
        printf 'SET @copyGrants = %d;\n' "$COPY_GRANTS"
        printf 'SET @revokeOldGrants = %d;\n' "$REVOKE_OLD_GRANTS"
        cat "$GENERATOR_SQL"
    } | mysql "${MYSQL_ARGS[@]}" \
        --batch \
        --raw \
        --skip-column-names
}

confirm_rename() {
    local answer=""

    if [[ "$YES" -eq 1 ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        error "Confirmation required, but stdin is not interactive. Re-run with --yes to execute non-interactively."
    fi

    echo "You are about to rename this MySQL database:"
    echo
    echo "  From: $OLD_DB"
    echo "  To:   $NEW_DB"
    echo

    if [[ "$COPY_GRANTS" -eq 1 || "$REVOKE_OLD_GRANTS" -eq 1 ]]; then
        echo "Grant handling:"
        if [[ "$COPY_GRANTS" -eq 1 ]]; then
            echo "  - copy old grants to the new database/objects"
        fi
        if [[ "$REVOKE_OLD_GRANTS" -eq 1 ]]; then
            echo "  - revoke old grants from the old database/objects"
        fi
        echo
    fi

    echo "The old database will be dropped only if it is empty after the rename."
    echo

    read -r -p "Type the new database name to confirm: " answer

    if [[ "$answer" != "$NEW_DB" ]]; then
        echo "Aborted."
        exit 0
    fi
}

execute_generated_sql() {
    local generated_sql="$1"
    local tmp_sql

    tmp_sql="$(mktemp)"
    printf '%s\n' "$generated_sql" > "$tmp_sql"

    mysql "${MYSQL_ARGS[@]}" < "$tmp_sql"

    rm -f "$tmp_sql"
}

drop_old_db_if_empty() {
    local remaining
    local quoted_old_db

    remaining="$(old_db_remaining_count)"

    if [[ "$remaining" != "0" ]]; then
        error "Old database '$OLD_DB' still has $remaining remaining object(s). Leaving it in place."
    fi

    quoted_old_db="$(quote_identifier "$OLD_DB")"
    mysql "${MYSQL_ARGS[@]}" -e "DROP DATABASE ${quoted_old_db};"

    echo "Dropped empty old database '$OLD_DB'."
}

main() {
    parse_args "$@"

    if [[ -z "$OLD_DB" || -z "$NEW_DB" ]]; then
        usage
        exit 1
    fi

    validate_db_name "old" "$OLD_DB"
    validate_db_name "new" "$NEW_DB"

    if [[ "$OLD_DB" == "$NEW_DB" ]]; then
        error "Old and new database names must be different."
    fi

    normalize_mysql_host_args
    validate_mysql_passthrough_args

    if ! command -v mysql >/dev/null 2>&1; then
        error "mysql client was not found in PATH."
    fi

    [[ -f "$GENERATOR_SQL" ]] || error "Generator SQL file not found: $GENERATOR_SQL"

    log "Using generator SQL: $GENERATOR_SQL"

    if ! database_exists "$OLD_DB"; then
        error "Old database '$OLD_DB' does not exist."
    fi

    if database_exists "$NEW_DB"; then
        error "New database '$NEW_DB' already exists."
    fi

    if [[ "$VERBOSE" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
        echo "Old database: $OLD_DB"
        echo "New database: $NEW_DB"
        echo "Copy grants: $COPY_GRANTS"
        echo "Revoke old grants: $REVOKE_OLD_GRANTS"
        echo
        print_object_summary
        echo
    fi

    local generated_sql
    generated_sql="$(generate_rename_sql)"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "Generated SQL:"
        echo "$generated_sql"
        echo
        echo "Execution command:"
        print_mysql_command_stdin "generated-sql-file"
        echo
        echo "Final cleanup performed by wrapper after execution:"
        echo "  - verify old database has zero remaining objects"
        echo "  - DROP DATABASE $(quote_identifier "$OLD_DB")"
        exit 0
    fi

    confirm_rename

    execute_generated_sql "$generated_sql"
    drop_old_db_if_empty

    echo "Database '$OLD_DB' has been renamed to '$NEW_DB'."
}

main "$@"
