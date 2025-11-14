#!/usr/bin/env bash

set -euo pipefail

#
# MySQL restore script using myloader
# © Jim Cronqvist <jim.cronqvist@gmail.com>
#

###############################################################################
# GLOBAL VARIABLES & DEFAULTS
###############################################################################

# Which parameters remain on the myloader command line?
CMD_LINE_PARAMS=("verbose" "debug" "logfile")

# Parameters that go under the [client] section
CLIENT_PARAMS=("host" "port" "user" "password" "protocol" "ssl-mode")

# Hardcoded defaults (lowest priority).
declare -A PARAMS=(
    # [client] defaults
    ["protocol"]="tcp"
    ["port"]="3306"
    ["ssl"]="true"
    ["compress-protocol"]="ZSTD"
    # We'll leave 'user' empty initially, fill in dynamically with root or admin, depending on if the host is an rds endpoint
    ["host"]="localhost"
    ["user"]=""
    ["password"]="" # empty by default

    # [myloader] defaults
    ["verbose"]="3"
    ["show-warnings"]="true"
    ["threads"]="12"
    ["skip-definer"]="true"
    ["overwrite-tables"]="true"
    ["queries-per-transaction"]="1"
    ["innodb-optimize-keys"]="SKIP"
    ["set-gtid-purged"]="false"
    ["enable-binlog"]="true"
    ["disable-redo-log"]="false"

    # Log file
    ["logfile"]="myloader.\${TIMESTAMP}.log"

    # Defaults file
    ["defaults-extra-file"]="myloader.\${TIMESTAMP}.cnf"

    # Mandatory field
    ["directory"]=""

    # Optional fields but commonly used to specify what should be restored and to where
    ["source-db"]=""
    ["database"]=""
    ["regex"]=""
    ["tables-list"]=""

    # Import triggers, events, stored procedures, functions?
    ["skip-triggers"]="true"
    ["skip-post"]="true"
)

# The myloader command
CMD=()

# Keep track if --dry-run was provided
DRY_RUN="false"

# Track if we should handle redo log ourselves
DISABLE_REDO_LOG="false"

# We'll parse multiple --table arguments and convert them into a single comma-delimited tables-list
TABLES=()

# Current timestamp for envsubst
export TIMESTAMP
TIMESTAMP="$(date +%Y-%m-%dT%H%M%S)"

###############################################################################
# FUNCTION DEFINITIONS
###############################################################################

timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

usage() {
    cat <<EOF
Usage: $0 [--key=value ...] [--table=db1.table1 ...] [--dry-run]

Mandatory field:
  --directory=/path/to/dump   (the folder where the dump is located)

Optional fields to control what should be restored, see examples below for usage:
  --source-db=db1
  --database=restored-db1
  --regex='^(db1\.table1)$'
  --tables-list=db1.table1,db2.table2,...
  --table=db1.table1 --table=db2.table2 ...

NOTE: If you use --database to restore a db to a different name, you must also provide the --source-db option.

Priority of parameters (highest -> lowest):
  1) CLI arguments (e.g. --user=alice)
  2) Environment variables (MYLOADER_MYSQL_... or MYLOADER_...)
  3) Default values (in script, plus dynamic checks)

## Examples:

1) Import a full backup (the dump metadata has the DBs):
   $0 --directory=~/mysql-restore/

2) Import a single database "db1":
   $0 --directory=~/mysql-restore/ --source-db=db1

3) Import a single database "db1" to a different name "restored-db1":
   $0 --directory=~/mysql-restore/ --source-db=db1 --database=restored-db1

4) Import a specific table(s):
   # Option A (--table)
   $0 --directory=~/mysql-restore/ --table=db1.table1 --table=db2.table2

   # Option B (--tables-list)
   $0 --directory=~/mysql-restore/ --tables-list=db1.table1,db2.table2

   # Option C (--regex)
   $0 --directory=~/mysql-restore/ --regex='^(db1\.table1|db2\.table2)$'

6) Other options you might want to tweak
   $0 --directory=~/mysql-restore/ --disable-redo-log --threads=12 --logfile=restore.log

7) Restore triggers, events, stored procedures, functions
   $0 --directory=~/mysql-restore/ --skip-triggers=false --skip-post=false

8) Dry-run mode (no changes will be made)
    $0 --directory=~/mysql-restore/ --dry-run

For more options, see:
    https://mydumper.github.io/mydumper/docs/html/myloader_usage.html

## Performance tips:

For development or test servers (does not work on RDS):
- Consider disabling redo logs with --disable-redo-log, only do this if they are not already disabled.
- Consider disabling binlogs with --enable-binlog=false if that is not required. Typically, it's not that big of a performance gain, but it might help if the disk is limited.

For RDS
- For a ~25% faster restore, consider disabling automatic backups during the restore.
  Warning: Be aware of the implications such as point-in-time recovery. Do by:
  1) Disable backups: aws rds modify-db-instance --apply-immediately --backup-retention-period 0 --db-instance-identifier <instance-name>
  2) Do the restore
  3) Re-enable backups: aws rds modify-db-instance --apply-immediately --backup-retention-period 14 --db-instance-identifier <instance-name>
- Consider temporarily using a faster instance type during the restore, if you see CPU bottlenecks.
- Consider temporarily increasing the iops of the RDS instance during the restore, if you see io/disk bottlenecks.

EOF
    exit 1
}

###############################################################################
# 1) Check dependencies for the script, and auto-install if needed on Ubuntu
###############################################################################

# check_dependencies if you want to auto-install packages
check_dependencies() {
    if ! dpkg-query --show --showformat='${db:Status-Status}\n' libatomic1 | grep -q 'installed' \
        || ! command -v mydumper &>/dev/null \
        || ! command -v mysql &>/dev/null \
        || ! command -v zstd &>/dev/null \
        || ! command -v yq &>/dev/null \
        || ! command -v pv &>/dev/null \
        || ! command -v envsubst &>/dev/null; then

        echo "Missing dependencies and/or mydumper is not installed."
        exit 1

        sudo apt-get update -qq && sudo apt-get install -y mysql-client libatomic1 libglib2.0-0 libpcre3 zstd pv gettext-base

        sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq

        MYDUMPER_VERSION="$(curl -Ls -o /dev/null -w '%{url_effective}' https://github.com/mydumper/mydumper/releases/latest | cut -d'/' -f8)"
        wget "https://github.com/mydumper/mydumper/releases/download/${MYDUMPER_VERSION}/mydumper_${MYDUMPER_VERSION:1}.$(lsb_release -cs)_amd64.deb"

        sudo dpkg -i "mydumper_${MYDUMPER_VERSION:1}.$(lsb_release -cs)_amd64.deb"
        rm -f "mydumper_${MYDUMPER_VERSION:1}.$(lsb_release -cs)_amd64.deb"
    fi
}

###############################################################################
# 1) Merge environment variables into PARAMS
###############################################################################
apply_environment_overrides() {
    # For [client] => MYLOADER_MYSQL_*
    # For [myloader] => MYLOADER_*
    while IFS='=' read -r var_name var_value; do
        if [[ "$var_name" == MYLOADER_MYSQL_* ]]; then
            # e.g. MYLOADER_MYSQL_HOST -> host
            local param_key="${var_name#MYLOADER_MYSQL_}"
            param_key="$(echo "$param_key" | tr '[:upper:]' '[:lower:]')"
            PARAMS["$param_key"]="$var_value"

        elif [[ "$var_name" == MYLOADER_* ]]; then
            # e.g. MYLOADER_VERBOSE -> verbose
            local param_key="${var_name#MYLOADER_}"
            param_key="$(echo "$param_key" | tr '[:upper:]' '[:lower:]')"
            PARAMS["$param_key"]="$var_value"
        fi
    done < <(env)
}

###############################################################################
# 2) Parse CLI arguments, overriding environment & defaults
###############################################################################
parse_cli_params() {
    local arg key value
    for arg in "$@"; do
        if [[ "$arg" == "--dry-run" ]]; then
            DRY_RUN="true"
            continue
        fi

        # Our multiple --table= approach, which we'll unify into tables-list
        if [[ "$arg" =~ ^--table=(.*)$ ]]; then
            local table_val="${arg#--table=}"
            TABLES+=("$table_val")
            continue
        fi

        # Expect format: --key=value or --key
        if [[ "$arg" =~ ^--([^=]+)(=(.*))?$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[3]:-true}"
            PARAMS["$key"]="$value"
        else
            echo "Error: unrecognized argument: $arg"
            exit 1
        fi
    done
}

###############################################################################
# 3) Check mandatory and invalid combos
###############################################################################
check_mandatory_fields() {
    # directory is mandatory
    if [[ -z "${PARAMS[directory]:-}" ]]; then
        echo "Error: 'directory' is mandatory. Please provide --directory=/path/to/dump"
        exit 1
    fi

    # If --database is provided with no --source-db, abort
    if [[ -n "${PARAMS[database]}" && -z "${PARAMS[source-db]}" ]]; then
        echo "Error: --database was provided but no --source-db. This is not recommended."
        echo "Please provide both --source-db=old_db_name and --database=new_db_name to rename properly."
        exit 1
    fi
}

###############################################################################
# 3.1) Check for FIFO files in the directory
###############################################################################
check_for_fifo_files() {
    local dir="${PARAMS[directory]}"
    [ -z "$dir" ] && return

    # Check if any FIFO (p) files exist in the directory
    if find "$dir" -type p -print -quit 2>/dev/null | grep -q '^'; then
        echo "ERROR: Found at least one FIFO (named pipe) under '$dir'."
        echo "In a myloader context, this often means a partial or streaming-based dump"
        echo "was createdand might possibly be running."
        echo "myloader cannot safely proceed with these FIFO files present. Aborting."
        echo ""
        echo "If you'd like to remove them, you could run (USE WITH CAUTION):"
        echo "  find \"$dir\" -type p -print -delete"
        echo ""
        exit 1
    fi
}

###############################################################################
# 4) Post-process logic
###############################################################################
post_process_params() {
    local host="${PARAMS["host"]}"
    local user="${PARAMS["user"]}"

    # If host is localhost, change to 127.0.0.1 (myloader bug: https://github.com/mydumper/mydumper/issues/547)
    if [[ "$host" == "localhost" ]]; then
        host="127.0.0.1"
    fi

    # If user is still empty, pick a sane default based on if the host is an RDS endpoint
    if [[ -z "$user" ]]; then
        if [[ "$host" == *".rds.amazonaws.com" ]]; then
            user="admin"
        else
            user="root"
        fi
    fi

    PARAMS["host"]="$host"
    PARAMS["user"]="$user"

    # If user gave multiple --table= but also provided a tables-list, abort
    if [[ "${#TABLES[@]}" -gt 0 && -n "${PARAMS["tables-list"]}" ]]; then
        echo "Error: You cannot use both --table=... and --tables-list=... in the same run."
        exit 1
    fi

    # If user gave multiple (or single) --table=..., combine them into a comma-delimited tables-list
    if [[ "${#TABLES[@]}" -gt 0 ]]; then
        local combined="${TABLES[*]}"   # space-separated
        combined="${combined// /,}"     # replace spaces with commas, i.e. TABLES=(db.table1 db.table2) -> db.table1,db.table2
        PARAMS["tables-list"]="$combined"
    fi

    # If --disable-redo-log was requested, handle it ourselves (workaround myloader bug)
    if [[ "${PARAMS["disable-redo-log"]:-false}" == "true" ]]; then
        DISABLE_REDO_LOG="true"
        # Prevent myloader from attempting this; we'll manage it manually
        PARAMS["disable-redo-log"]="false"
    fi
}

###############################################################################
# 5) Build the myloader command line
###############################################################################
build_command() {
    CMD=("myloader")

    local defaults_file
    defaults_file="$(envsubst <<< "${PARAMS["defaults-extra-file"]}")"
    CMD+=("--defaults-extra-file=${defaults_file}")

    # List of keys to ignore
    local ignore_keys=("logfile")

    # Add those parameters specifically designated for the command line
    for keep_key in "${CMD_LINE_PARAMS[@]}"; do
        [[ " ${ignore_keys[*]} " =~ " ${keep_key} " ]] && continue # skip if part of the ignored keys list

        local val="${PARAMS[$keep_key]:-}"
        [ -z "${val}" ] && continue  # skip if not set

        if [[ "${val}" == "true" ]]; then
            CMD+=("--${keep_key}")
        elif [[ "${val}" == "false" ]]; then
            # omit if false
            :
        else
            CMD+=("--${keep_key}=${val}")
        fi
    done
}

###############################################################################
# 6) Create the defaults-extra-file
###############################################################################
create_defaults_file() {
    local defaults_file
    defaults_file="$(envsubst <<< "${PARAMS["defaults-extra-file"]}")"

    local client_lines=()
    local myloader_lines=()

    for key in "${!PARAMS[@]}"; do
        # Skip certain keys that are strictly CLI parameters
        [[ "$key" == "defaults-extra-file" ]] && continue
        if [[ " ${CMD_LINE_PARAMS[*]} " =~ " ${key} " ]]; then
            continue
        fi

        # Evaluate the final value
        local val
        val="$(envsubst <<< "${PARAMS[$key]}")"

        # If empty, skip
        [[ -z "$val" ]] && continue

        if [[ " ${CLIENT_PARAMS[*]} " =~ " ${key} " ]]; then
            # This belongs in [client]
            client_lines+=("${key}=${val}")
        else
            # This belongs in [myloader]
            case "$val" in
                true)  myloader_lines+=("${key}=true")  ;;
                false) :  ;; # Skip false
                *)     myloader_lines+=("${key}=${val}") ;;
            esac
        fi
    done

    # Write the defaults file
    {
        echo "[client]"
        for line in "${client_lines[@]}"; do
            echo "${line}"
        done

        echo ""
        echo "[myloader]"
        for line in "${myloader_lines[@]}"; do
            echo "${line}"
        done
    } | tee "${defaults_file}" >/dev/null
}

###############################################################################
# 7) Run the myloader command (or skip if --dry-run)
###############################################################################
mysql_query() {
    local QUERY="$1"
    local FIRST_ROW_FIRST_COL_ONLY="${2:-false}"

    local OUTPUT
    OUTPUT="$(mysql --defaults-extra-file="${MYSQL_DEFAULTS_EXTRA_FILE}" -N -B -e "$QUERY" 2>&1)"
    local EXIT_CODE=$?

    if [[ $EXIT_CODE -ne 0 ]]; then
        echo "Error running MySQL command (exit code $EXIT_CODE):" >&2
        echo "$OUTPUT" >&2
        return $EXIT_CODE
    fi

    if echo "$OUTPUT" | grep -qi "^ERROR"; then
        echo "MySQL query returned an error:" >&2
        echo "$OUTPUT" >&2
        return 1
    fi

    if [[ "$FIRST_ROW_FIRST_COL_ONLY" == "true" || "$FIRST_ROW_FIRST_COL_ONLY" == "1" ]]; then
        echo "$OUTPUT" | head -n 1 | cut -f1
    else
        echo "$OUTPUT"
    fi

    echo "The query returned $(echo -n "$OUTPUT" | wc -l) rows." >&2
}

disable_redo_log() {
    echo "Disabling InnoDB redo log before restore (handled by wrapper)."
    if mysql_query "ALTER INSTANCE DISABLE INNODB REDO_LOG;"; then
        echo "Redo log disabled successfully."
    else
        echo "Warning: Failed to disable redo log via ALTER INSTANCE. Proceeding." >&2
    fi
}

enable_redo_log() {
    echo "Re-enabling InnoDB redo log after restore."
    if mysql_query "ALTER INSTANCE ENABLE INNODB REDO_LOG;"; then
        echo "Redo log enabled successfully."
    else
        echo "Warning: Failed to re-enable redo log via ALTER INSTANCE. Please verify manually." >&2
    fi
}

run_command() {
    local defaults_file
    defaults_file="$(envsubst <<< "${PARAMS["defaults-extra-file"]}")"

    local logfile
    logfile="$(envsubst <<< "${PARAMS["logfile"]}")"

    echo ""
    echo "The restore started at: $(timestamp)."
    echo ""
    echo "Running command: ${CMD[*]} 2>&1 | tee -a $logfile"
    echo ""

    echo "---- Defaults file content ----"
    sed -E 's/^password=.+/password=\*\*\*\*\*/g' "${defaults_file}"
    echo "--------------------------------"
    echo ""

    # Set defaults file for mysql_query helper
    MYSQL_DEFAULTS_EXTRA_FILE="${defaults_file}"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "--dry-run option provided, skipping myloader execution."
        return
    fi

    local start end result seconds
    start="$(date +%s)"
    # If we the disable redo logs argument was provided, handle it here before running myloader
    if [[ "$DISABLE_REDO_LOG" == "true" && "$DRY_RUN" != "true" ]]; then
        disable_redo_log
    fi
    { "${CMD[@]}" 2>&1 | tee -a "$logfile"; } || result=$?
    result=${result:-0}
    end="$(date +%s)"
    seconds=$(( end - start ))

    echo "The restore runtime was ${seconds} seconds, finished at $(timestamp)."

    # Always try to restore redo log afterwards if the disable redo logs was provided
    if [[ "$DISABLE_REDO_LOG" == "true" && "$DRY_RUN" != "true" ]]; then
        enable_redo_log
    fi

    # Obscure the password in the defaults-extra-file
    sed -i -e 's/^password=.*/#password=\*\*\*\*\*/g' "${defaults_file}"

    if [ "$result" -ne 0 ]; then
        echo "Restore failed with exit code: $result"
        exit "$result"
    fi

    echo ""
    echo "The restore runtime was ${seconds} seconds."
    echo "Restore completed at: $(timestamp)."
}

###############################################################################
# 8) Check if the 'mysql_user_grants' file exists and inform the user
###############################################################################

function check_for_mysql_user_grants() {
    local dir="${PARAMS[directory]}"
    [ -z "$dir" ] && return
    local mysql_user_grants_file="mysql_user_grants.sql"

    if [ -f "${dir}/${mysql_user_grants_file}" ]; then
        echo ""
        echo "Important note:"
        echo "The file '${mysql_user_grants_file}' was found in the backup directory: ${dir}${mysql_user_grants_file}"
        echo "Please manually execute if you want to re-import the user grants."
        echo ""
    fi
}

###############################################################################
# 9) Check for common errors in the log file
###############################################################################

function check_for_common_errors_in_logfile() {
    local logfile
    logfile="$(envsubst <<< "${PARAMS["logfile"]}")"

    echo ""
    echo "Checking the log file against common errors to ensure a success."

    local errors=(
        "Warnings found during INSERT between lines"
        "Out of range value for column"
    )

    for match in "${errors[@]}"; do
        if grep -qF "$match" "$logfile"; then
            echo "Error: Found an the following error '$match' in logfile. Failing."
            exit 1
        fi
    done
    echo "No common errors found in the log file."
}

###############################################################################
# MAIN SCRIPT FLOW
###############################################################################

main() {
    # 0) Check dependencies for the script
    check_dependencies

    # If no args, print usage
    [ $# -eq 0 ] && usage

    # 1) Apply environment overrides (MYLOADER_ or MYLOADER_MYSQL_)
    apply_environment_overrides

    # 2) Parse CLI arguments
    parse_cli_params "$@"

    # 3) Check mandatory fields and some invalid combos
    check_mandatory_fields

    # 3.1) Check for FIFO files in the directory
    check_for_fifo_files

    # 4) Post-process logic
    post_process_params

    # 5) Build command
    build_command

    # 6) Create the defaults file
    create_defaults_file

    # 7) Run or skip if --dry-run
    run_command

    # 8) Check if the 'mysql_user_grants' file exists and inform the user
    check_for_mysql_user_grants

    # 9) Check for common errors in the log file
    check_for_common_errors_in_logfile

    echo ""
    echo "Restore completed successfully."
}

main "$@"
