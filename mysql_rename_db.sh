#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

OLD_DB=""
NEW_DB=""
DRY_RUN=0
YES=0
VERBOSE=0
COPY_GRANTS=0
REVOKE_OLD_GRANTS=0

MYSQL_ARGS=()
TMP_DIR=""

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [script options] <old_database> <new_database> [-- mysql options]

Renames a MySQL database by creating the new database, moving/recreating
objects, and dropping the old database only if no objects remain.

Script options:
  --copy-grants           Copy grants from old_database.* and old objects to
                          the new database/objects.

  --revoke-old-grants     Revoke grants from old_database.* and old objects.

  --rename-grants         Shortcut for --copy-grants and --revoke-old-grants.

  --dry-run               Discover objects and print generated SQL without executing.
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
  - Do not pass -e or --execute after --; this script generates SQL itself.
  - Database names are limited to letters, numbers, and underscores.
  - localhost passed as a MySQL host is normalized to 127.0.0.1.
  - mysqldump is used for views, triggers, routines, and events.
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

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

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
    local arg

    printf 'mysql'

    for arg in "${MYSQL_ARGS[@]}"; do
        printf ' '
        shell_quote "$arg"
    done

    printf ' < generated-sql-file\n'
}

print_mysql_command_e() {
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

validate_mysql_identifier_value() {
    local label="$1"
    local value="$2"

    if [[ -z "$value" ]]; then
        error "$label cannot be empty."
    fi

    if [[ ! "$value" =~ ^[a-zA-Z0-9_]+$ ]]; then
        error "Invalid $label '$value'. Only letters, numbers, and underscores are allowed."
    fi
}

validate_mysql_passthrough_args() {
    local arg

    for arg in "${MYSQL_ARGS[@]}"; do
        case "$arg" in
            -e|-e?*|--execute|--execute=*)
                error "Do not pass '$arg' after --. This script provides its own SQL."
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

mysql_query() {
    local sql="$1"

    mysql "${MYSQL_ARGS[@]}" --batch --raw --skip-column-names -e "$sql"
}

mysql_execute() {
    local sql="$1"

    mysql "${MYSQL_ARGS[@]}" -e "$sql"
}

mysqldump_to_file() {
    local output_file="$1"
    shift

    mysqldump "${MYSQL_ARGS[@]}" "$@" > "$output_file"
}

transform_dump_file() {
    local input_file="$1"
    local output_file="$2"

    sed \
        -e "s/\`$OLD_DB\`\./\`$NEW_DB\`\./g" \
        -e "s/USE \`$OLD_DB\`;/USE \`$NEW_DB\`;/g" \
        "$input_file" > "$output_file"
}

append_section() {
    local file="$1"
    local title="$2"

    {
        echo
        echo "--"
        echo "-- $title"
        echo "--"
    } >> "$file"
}

append_query_output() {
    local file="$1"
    local sql="$2"
    local output

    output="$(mysql_query "$sql")"

    if [[ -n "$output" ]]; then
        printf '%s\n' "$output" >> "$file"
    fi
}

append_file_if_not_empty() {
    local source_file="$1"
    local target_file="$2"

    if [[ -s "$source_file" ]]; then
        cat "$source_file" >> "$target_file"
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

confirm_rename() {
    local answer=""
    local expected="$OLD_DB->$NEW_DB"

    if [[ "$YES" -eq 1 ]]; then
        return 0
    fi

    if [[ ! -t 0 ]]; then
        error "Confirmation required, but stdin is not interactive. Re-run with --yes to execute non-interactively."
    fi

    echo "You are about to rename this database:"
    echo
    echo "  $OLD_DB -> $NEW_DB"
    echo
    echo "The old database will be dropped only if no objects remain."
    echo

    read -r -p "Type '$expected' to confirm: " answer

    if [[ "$answer" != "$expected" ]]; then
        echo "Aborted."
        exit 0
    fi
}

read_object_names() {
    local query="$1"
    local line

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        printf '%s\n' "$line"
    done < <(mysql_query "$query")
}

get_schema_exists_count() {
    local db_name="$1"
    local db_lit

    db_lit="$(sql_string_literal "$db_name")"
    mysql_query "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = $db_lit;"
}

get_remaining_object_count() {
    local db_lit

    db_lit="$(sql_string_literal "$OLD_DB")"

    mysql_query "
SELECT
    (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = $db_lit) +
    (SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = $db_lit) +
    (SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = $db_lit) +
    (SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA = $db_lit);
"
}

append_base_table_rename_sql() {
    local file="$1"
    shift
    local -a base_tables=("$@")
    local table
    local first=1

    if [[ "${#base_tables[@]}" -eq 0 ]]; then
        return 0
    fi

    append_section "$file" "Move base tables"

    printf 'RENAME TABLE\n' >> "$file"

    for table in "${base_tables[@]}"; do
        if [[ "$first" -eq 1 ]]; then
            first=0
        else
            printf ',\n' >> "$file"
        fi

        printf '  %s.%s TO %s.%s' \
            "$(quote_identifier "$OLD_DB")" \
            "$(quote_identifier "$table")" \
            "$(quote_identifier "$NEW_DB")" \
            "$(quote_identifier "$table")" >> "$file"
    done

    printf ';\n' >> "$file"
}

append_drop_triggers_sql() {
    local file="$1"
    shift
    local -a triggers=("$@")
    local trigger

    if [[ "${#triggers[@]}" -eq 0 ]]; then
        return 0
    fi

    append_section "$file" "Drop old triggers before moving tables"

    for trigger in "${triggers[@]}"; do
        printf 'DROP TRIGGER %s.%s;\n' \
            "$(quote_identifier "$OLD_DB")" \
            "$(quote_identifier "$trigger")" >> "$file"
    done
}

append_drop_views_sql() {
    local file="$1"
    shift
    local -a views=("$@")
    local view

    if [[ "${#views[@]}" -eq 0 ]]; then
        return 0
    fi

    append_section "$file" "Drop old views"

    for view in "${views[@]}"; do
        printf 'DROP VIEW %s.%s;\n' \
            "$(quote_identifier "$OLD_DB")" \
            "$(quote_identifier "$view")" >> "$file"
    done
}

append_drop_routines_sql() {
    local file="$1"
    local routine_rows_file="$2"
    local line
    local routine_type
    local routine_name

    if [[ ! -s "$routine_rows_file" ]]; then
        return 0
    fi

    append_section "$file" "Drop old routines"

    while IFS=$'\t' read -r routine_type routine_name; do
        [[ -n "$routine_type" && -n "$routine_name" ]] || continue

        case "$routine_type" in
            PROCEDURE|FUNCTION)
                printf 'DROP %s %s.%s;\n' \
                    "$routine_type" \
                    "$(quote_identifier "$OLD_DB")" \
                    "$(quote_identifier "$routine_name")" >> "$file"
                ;;
            *)
                error "Unexpected routine type '$routine_type' for routine '$routine_name'."
                ;;
        esac
    done < "$routine_rows_file"
}

append_drop_events_sql() {
    local file="$1"
    shift
    local -a events=("$@")
    local event

    if [[ "${#events[@]}" -eq 0 ]]; then
        return 0
    fi

    append_section "$file" "Drop old events"

    for event in "${events[@]}"; do
        printf 'DROP EVENT %s.%s;\n' \
            "$(quote_identifier "$OLD_DB")" \
            "$(quote_identifier "$event")" >> "$file"
    done
}

append_copy_grants_sql() {
    local file="$1"
    local old_lit
    local new_lit

    old_lit="$(sql_string_literal "$OLD_DB")"
    new_lit="$(sql_string_literal "$NEW_DB")"

    append_section "$file" "Copy grants to new database and objects"

    append_query_output "$file" "
SET SESSION group_concat_max_len = 1048576;
SELECT CONCAT(
    'GRANT ',
    GROUP_CONCAT(PRIVILEGE_TYPE ORDER BY PRIVILEGE_TYPE SEPARATOR ', '),
    ' ON ', CHAR(96), $new_lit, CHAR(96), '.* TO ',
    GRANTEE,
    IF(IS_GRANTABLE = 'YES', ' WITH GRANT OPTION', ''),
    ';'
)
FROM information_schema.SCHEMA_PRIVILEGES
WHERE TABLE_SCHEMA = $old_lit
GROUP BY GRANTEE, IS_GRANTABLE
ORDER BY GRANTEE, IS_GRANTABLE;
"

    append_query_output "$file" "
SET SESSION group_concat_max_len = 1048576;
SELECT CONCAT(
    'GRANT ',
    GROUP_CONCAT(PRIVILEGE_TYPE ORDER BY PRIVILEGE_TYPE SEPARATOR ', '),
    ' ON ', CHAR(96), $new_lit, CHAR(96), '.',
    CHAR(96), REPLACE(TABLE_NAME, CHAR(96), CONCAT(CHAR(96), CHAR(96))), CHAR(96),
    ' TO ', GRANTEE,
    IF(IS_GRANTABLE = 'YES', ' WITH GRANT OPTION', ''),
    ';'
)
FROM information_schema.TABLE_PRIVILEGES
WHERE TABLE_SCHEMA = $old_lit
GROUP BY GRANTEE, TABLE_NAME, IS_GRANTABLE
ORDER BY GRANTEE, TABLE_NAME, IS_GRANTABLE;
"

    append_query_output "$file" "
SET SESSION group_concat_max_len = 1048576;
SELECT CONCAT(
    'GRANT ', PRIVILEGE_TYPE,
    ' (',
    GROUP_CONCAT(
        CONCAT(CHAR(96), REPLACE(COLUMN_NAME, CHAR(96), CONCAT(CHAR(96), CHAR(96))), CHAR(96))
        ORDER BY COLUMN_NAME
        SEPARATOR ', '
    ),
    ') ON ', CHAR(96), $new_lit, CHAR(96), '.',
    CHAR(96), REPLACE(TABLE_NAME, CHAR(96), CONCAT(CHAR(96), CHAR(96))), CHAR(96),
    ' TO ', GRANTEE,
    IF(IS_GRANTABLE = 'YES', ' WITH GRANT OPTION', ''),
    ';'
)
FROM information_schema.COLUMN_PRIVILEGES
WHERE TABLE_SCHEMA = $old_lit
GROUP BY GRANTEE, TABLE_NAME, PRIVILEGE_TYPE, IS_GRANTABLE
ORDER BY GRANTEE, TABLE_NAME, PRIVILEGE_TYPE, IS_GRANTABLE;
"

    append_query_output "$file" "
SET SESSION group_concat_max_len = 1048576;
SELECT CONCAT(
    'GRANT ', p.privileges,
    ' ON ', p.Routine_type, ' ', CHAR(96), $new_lit, CHAR(96), '.',
    CHAR(96), REPLACE(p.Routine_name, CHAR(96), CONCAT(CHAR(96), CHAR(96))), CHAR(96),
    ' TO ', p.grantee,
    IF(p.has_grant_option = 1, ' WITH GRANT OPTION', ''),
    ';'
)
FROM (
    SELECT
        CONCAT(QUOTE(User), '@', QUOTE(Host)) AS grantee,
        Routine_name,
        Routine_type,
        REPLACE(
            REPLACE(
                TRIM(BOTH ',' FROM REPLACE(REPLACE(Proc_priv, 'Grant', ''), ',,', ',')),
                'Execute', 'EXECUTE'
            ),
            'Alter Routine', 'ALTER ROUTINE'
        ) AS privileges,
        IF(FIND_IN_SET('Grant', Proc_priv) > 0, 1, 0) AS has_grant_option
    FROM mysql.procs_priv
    WHERE Db = $old_lit
) AS p
WHERE p.privileges <> ''
ORDER BY p.grantee, p.Routine_type, p.Routine_name;
"
}

append_revoke_old_grants_sql() {
    local file="$1"
    local old_lit

    old_lit="$(sql_string_literal "$OLD_DB")"

    append_section "$file" "Revoke grants from old database and objects"

    append_query_output "$file" "
SET SESSION group_concat_max_len = 1048576;
SELECT CONCAT(
    'REVOKE ',
    GROUP_CONCAT(PRIVILEGE_TYPE ORDER BY PRIVILEGE_TYPE SEPARATOR ', '),
    ' ON ', CHAR(96), $old_lit, CHAR(96), '.* FROM ',
    GRANTEE,
    ';'
)
FROM information_schema.SCHEMA_PRIVILEGES
WHERE TABLE_SCHEMA = $old_lit
GROUP BY GRANTEE
ORDER BY GRANTEE;
"

    append_query_output "$file" "
SET SESSION group_concat_max_len = 1048576;
SELECT CONCAT(
    'REVOKE ',
    GROUP_CONCAT(PRIVILEGE_TYPE ORDER BY PRIVILEGE_TYPE SEPARATOR ', '),
    ' ON ', CHAR(96), $old_lit, CHAR(96), '.',
    CHAR(96), REPLACE(TABLE_NAME, CHAR(96), CONCAT(CHAR(96), CHAR(96))), CHAR(96),
    ' FROM ', GRANTEE,
    ';'
)
FROM information_schema.TABLE_PRIVILEGES
WHERE TABLE_SCHEMA = $old_lit
GROUP BY GRANTEE, TABLE_NAME
ORDER BY GRANTEE, TABLE_NAME;
"

    append_query_output "$file" "
SET SESSION group_concat_max_len = 1048576;
SELECT CONCAT(
    'REVOKE ', PRIVILEGE_TYPE,
    ' (',
    GROUP_CONCAT(
        CONCAT(CHAR(96), REPLACE(COLUMN_NAME, CHAR(96), CONCAT(CHAR(96), CHAR(96))), CHAR(96))
        ORDER BY COLUMN_NAME
        SEPARATOR ', '
    ),
    ') ON ', CHAR(96), $old_lit, CHAR(96), '.',
    CHAR(96), REPLACE(TABLE_NAME, CHAR(96), CONCAT(CHAR(96), CHAR(96))), CHAR(96),
    ' FROM ', GRANTEE,
    ';'
)
FROM information_schema.COLUMN_PRIVILEGES
WHERE TABLE_SCHEMA = $old_lit
GROUP BY GRANTEE, TABLE_NAME, PRIVILEGE_TYPE
ORDER BY GRANTEE, TABLE_NAME, PRIVILEGE_TYPE;
"

    append_query_output "$file" "
SET SESSION group_concat_max_len = 1048576;
SELECT CONCAT(
    'REVOKE ', p.privileges,
    ' ON ', p.Routine_type, ' ', CHAR(96), $old_lit, CHAR(96), '.',
    CHAR(96), REPLACE(p.Routine_name, CHAR(96), CONCAT(CHAR(96), CHAR(96))), CHAR(96),
    ' FROM ', p.grantee,
    ';'
)
FROM (
    SELECT
        CONCAT(QUOTE(User), '@', QUOTE(Host)) AS grantee,
        Routine_name,
        Routine_type,
        REPLACE(
            REPLACE(
                TRIM(BOTH ',' FROM REPLACE(REPLACE(Proc_priv, 'Grant', ''), ',,', ',')),
                'Execute', 'EXECUTE'
            ),
            'Alter Routine', 'ALTER ROUTINE'
        ) AS privileges
    FROM mysql.procs_priv
    WHERE Db = $old_lit
) AS p
WHERE p.privileges <> ''
ORDER BY p.grantee, p.Routine_type, p.Routine_name;
"
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

    log "mysql client found."

    local old_exists
    local new_exists
    local old_lit
    local new_lit
    local schema_row
    local charset
    local collation
    local sql_file
    local view_dump_raw
    local view_dump_sql
    local trigger_dump_raw
    local trigger_dump_sql
    local routine_event_dump_raw
    local routine_event_dump_sql
    local remaining_count

    old_exists="$(get_schema_exists_count "$OLD_DB")"
    if [[ "$old_exists" != "1" ]]; then
        error "Old database '$OLD_DB' does not exist."
    fi

    new_exists="$(get_schema_exists_count "$NEW_DB")"
    if [[ "$new_exists" != "0" ]]; then
        error "New database '$NEW_DB' already exists."
    fi

    old_lit="$(sql_string_literal "$OLD_DB")"
    new_lit="$(sql_string_literal "$NEW_DB")"

    schema_row="$(mysql_query "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = $old_lit;")"
    IFS=$'\t' read -r charset collation <<< "$schema_row"

    validate_mysql_identifier_value "charset" "$charset"
    validate_mysql_identifier_value "collation" "$collation"

    local -a base_tables=()
    local -a views=()
    local -a triggers=()
    local -a events=()
    local line

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        base_tables+=("$line")
    done < <(read_object_names "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = $old_lit AND TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME;")

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        views+=("$line")
    done < <(read_object_names "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = $old_lit AND TABLE_TYPE = 'VIEW' ORDER BY TABLE_NAME;")

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        triggers+=("$line")
    done < <(read_object_names "SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = $old_lit ORDER BY EVENT_OBJECT_TABLE, ACTION_TIMING, EVENT_MANIPULATION, TRIGGER_NAME;")

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        events+=("$line")
    done < <(read_object_names "SELECT EVENT_NAME FROM information_schema.EVENTS WHERE EVENT_SCHEMA = $old_lit ORDER BY EVENT_NAME;")

    TMP_DIR="$(mktemp -d)"
    sql_file="$TMP_DIR/rename.sql"
    view_dump_raw="$TMP_DIR/views.raw.sql"
    view_dump_sql="$TMP_DIR/views.sql"
    trigger_dump_raw="$TMP_DIR/triggers.raw.sql"
    trigger_dump_sql="$TMP_DIR/triggers.sql"
    routine_event_dump_raw="$TMP_DIR/routines_events.raw.sql"
    routine_event_dump_sql="$TMP_DIR/routines_events.sql"
    local routine_rows_file="$TMP_DIR/routines.tsv"

    mysql_query "SELECT ROUTINE_TYPE, ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = $old_lit ORDER BY ROUTINE_TYPE, ROUTINE_NAME;" > "$routine_rows_file"

    local routine_count
    routine_count="$(wc -l < "$routine_rows_file" | tr -d ' ')"

    if [[ "${#views[@]}" -gt 0 || "${#triggers[@]}" -gt 0 || "$routine_count" -gt 0 || "${#events[@]}" -gt 0 ]]; then
        if ! command -v mysqldump >/dev/null 2>&1; then
            error "mysqldump client was not found in PATH. It is required when views, triggers, routines, or events exist."
        fi

        log "mysqldump client found."
    fi

    : > "$sql_file"

    append_section "$sql_file" "Create new database"
    printf 'CREATE DATABASE %s DEFAULT CHARACTER SET %s DEFAULT COLLATE %s;\n' \
        "$(quote_identifier "$NEW_DB")" \
        "$charset" \
        "$collation" >> "$sql_file"

    if [[ "${#views[@]}" -gt 0 ]]; then
        local -a ignore_table_args=()
        local table

        for table in "${base_tables[@]}"; do
            ignore_table_args+=("--ignore-table=${OLD_DB}.${table}")
        done

        mysqldump_to_file "$view_dump_raw" \
            --no-data \
            --skip-triggers \
            --skip-routines \
            --skip-events \
            "${ignore_table_args[@]}" \
            "$OLD_DB"

        transform_dump_file "$view_dump_raw" "$view_dump_sql"
    fi

    if [[ "${#triggers[@]}" -gt 0 ]]; then
        mysqldump_to_file "$trigger_dump_raw" \
            --no-data \
            --no-create-info \
            --triggers \
            --skip-routines \
            --skip-events \
            "$OLD_DB"

        transform_dump_file "$trigger_dump_raw" "$trigger_dump_sql"
    fi

    if [[ -s "$routine_rows_file" || "${#events[@]}" -gt 0 ]]; then
        mysqldump_to_file "$routine_event_dump_raw" \
            --no-data \
            --no-create-info \
            --skip-triggers \
            --routines \
            --events \
            "$OLD_DB"

        transform_dump_file "$routine_event_dump_raw" "$routine_event_dump_sql"
    fi

    append_drop_triggers_sql "$sql_file" "${triggers[@]}"
    append_base_table_rename_sql "$sql_file" "${base_tables[@]}"

    if [[ "${#views[@]}" -gt 0 ]]; then
        append_section "$sql_file" "Create views in new database"
        printf 'USE %s;\n' "$(quote_identifier "$NEW_DB")" >> "$sql_file"
        append_file_if_not_empty "$view_dump_sql" "$sql_file"
    fi

    if [[ -s "$routine_event_dump_sql" ]]; then
        append_section "$sql_file" "Create routines and events in new database"
        printf 'USE %s;\n' "$(quote_identifier "$NEW_DB")" >> "$sql_file"
        append_file_if_not_empty "$routine_event_dump_sql" "$sql_file"
    fi

    if [[ -s "$trigger_dump_sql" ]]; then
        append_section "$sql_file" "Create triggers in new database"
        printf 'USE %s;\n' "$(quote_identifier "$NEW_DB")" >> "$sql_file"
        append_file_if_not_empty "$trigger_dump_sql" "$sql_file"
    fi

    append_drop_views_sql "$sql_file" "${views[@]}"
    append_drop_routines_sql "$sql_file" "$routine_rows_file"
    append_drop_events_sql "$sql_file" "${events[@]}"

    if [[ "$COPY_GRANTS" -eq 1 ]]; then
        append_copy_grants_sql "$sql_file"
    fi

    if [[ "$REVOKE_OLD_GRANTS" -eq 1 ]]; then
        append_revoke_old_grants_sql "$sql_file"
    fi

    if [[ "$VERBOSE" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
        echo "Old database: $OLD_DB"
        echo "New database: $NEW_DB"
        echo "Charset:      $charset"
        echo "Collation:    $collation"
        echo
        echo "Objects discovered:"
        echo "  Base tables: ${#base_tables[@]}"
        echo "  Views:       ${#views[@]}"
        echo "  Triggers:    ${#triggers[@]}"
        echo "  Routines:    $routine_count"
        echo "  Events:      ${#events[@]}"
        echo
        echo "Grant actions:"
        echo "  Copy grants:       $([[ "$COPY_GRANTS" -eq 1 ]] && echo yes || echo no)"
        echo "  Revoke old grants: $([[ "$REVOKE_OLD_GRANTS" -eq 1 ]] && echo yes || echo no)"
        echo
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "SQL:"
        cat "$sql_file"
        echo
        echo "Final cleanup step:"
        echo "  The script will check whether '$OLD_DB' has remaining objects."
        echo "  If no objects remain, it will run:"
        printf '  '
        print_mysql_command_e "DROP DATABASE $(quote_identifier "$OLD_DB");"
        echo
        echo "Command for generated SQL:"
        print_mysql_command_stdin
        exit 0
    fi

    confirm_rename

    mysql "${MYSQL_ARGS[@]}" < "$sql_file"

    remaining_count="$(get_remaining_object_count)"

    if [[ "$remaining_count" == "0" ]]; then
        mysql_execute "DROP DATABASE $(quote_identifier "$OLD_DB");"
        echo "Renamed database '$OLD_DB' to '$NEW_DB'. Old database was dropped because it is empty."
    else
        echo "Rename operations completed, but old database '$OLD_DB' still contains $remaining_count object(s)." >&2
        echo "Old database was not dropped." >&2
        exit 1
    fi
}

main "$@"
