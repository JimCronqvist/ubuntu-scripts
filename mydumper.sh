#!/usr/bin/env bash

set -euo pipefail

#
# MySQL backup script using mydumper
# © Jim Cronqvist <jim.cronqvist@gmail.com>
#
# https://github.com/JimCronqvist/ubuntu-scripts/blob/master/mydumper.sh
#


# Create a 'mydumper' backup user
# CREATE USER 'mydumper'@'%' IDENTIFIED BY '<complex-password-here>';
# ALTER USER 'mydumper'@'%' REQUIRE SSL; # If the user is not bound to a local IP, this is strongly recommended.
# GRANT SELECT, RELOAD, LOCK TABLES, REPLICATION CLIENT, SHOW VIEW, EVENT, TRIGGER ON *.* TO 'mydumper'@'%';
# #GRANT SELECT ON performance_schema.* TO 'mydumper'@'%'; # Only needed for certain mysql version. Try to skip first.
# FLUSH PRIVILEGES;


# Example YAML file
# app:
#   host: db.xyz.eu-north-1.rds.amazonaws.com
#   password: ${MYSQL_PASSWORD}
#   database: app
#   #all-tablespaces: true
#   keep-backups: 2
#   s3path: <s3-bucket>/
#   table-limits:
#     app.logs: 0

if ! dpkg-query --show --showformat='${db:Status-Status}\n' 'libatomic1' | grep -q 'installed' || ! hash mydumper mysql zstd yq pv envsubst &>/dev/null; then
    echo "Missing dependencies and/or mydumper is not installed"
    #exit 1

    sudo apt-get install mysql-client libatomic1 libglib2.0-0 libpcre3 zstd pv gettext-base -y
    sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq

    MYDUMPER_VERSION="$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/mydumper/mydumper/releases/latest | cut -d'/' -f8)"
    wget "https://github.com/mydumper/mydumper/releases/download/${MYDUMPER_VERSION}/mydumper_${MYDUMPER_VERSION:1}.$(lsb_release -cs)_amd64.deb"
    sudo dpkg -i "mydumper_${MYDUMPER_VERSION:1}.$(lsb_release -cs)_amd64.deb"
    rm -f "mydumper_${MYDUMPER_VERSION:1}.$(lsb_release -cs)_amd64.deb"
fi

YAML_FILE="mydumper.yaml" # Path to your YAML file

if [ ! -f "$YAML_FILE" ]; then
    echo "The config YAML file does not exist: $YAML_FILE"
    exit 1
fi

if [ "$#" -ne 1 ]; then
    echo "# Usage: script.sh <config-key>"
    exit 2
fi

# Export two variables to be used in the script with 'envsubst'
export CONFIG="$1"
export TIMESTAMP=$(date +%Y-%m-%dT%H%M%S)

timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

confirm_aws_profile() {
    if aws configure --profile "${1}" list | grep -q "could not be found"; then
        echo "The AWS profile ${1} has not been established. You need to set this up prior to running this script."
        exit 1
    fi
}

mysql_query() {
    local QUERY="$1"
    local FIRST_ROW_FIRST_COL_ONLY="${2:-false}"

    #echo "Running query: $QUERY" >&2

    # Capture both stdout and stderr into 'OUTPUT'
    local OUTPUT
    OUTPUT="$(mysql --defaults-extra-file="${MYSQL_DEFAULTS_EXTRA_FILE}" -N -B -e "$QUERY" 2>&1)"
    local EXIT_CODE=$?

    # If mysql command actually failed (e.g., bad syntax in command line args, no server, etc.).
    if [[ $EXIT_CODE -ne 0 ]]; then
        echo "Error running MySQL command (exit code $EXIT_CODE):" >&2
        echo "$OUTPUT" >&2
        # Abort this function. You can also do 'exit' if you want to exit the entire script.
        return $EXIT_CODE
    fi

    # If MySQL ran but returned an SQL error (it often says 'ERROR ...'). MySQL may still return 0 exit code. We grep for 'ERROR'.
    if echo "$OUTPUT" | grep -qi "^ERROR"; then
        echo "MySQL query returned an error:" >&2
        echo "$OUTPUT" >&2
        return 1
    fi

    # If there's no error, proceed to parse the output.
    if [[ "$FIRST_ROW_FIRST_COL_ONLY" == "true" || "$FIRST_ROW_FIRST_COL_ONLY" == "1" ]]; then
        # Print only the first column of the first row
        echo "$OUTPUT" | head -n 1 | cut -f1
    else
        # Print entire output
        echo "$OUTPUT"
    fi

    # Print the number of rows returned
    echo "The query returned $(echo -n "$OUTPUT" | wc -l) rows." >&2

    # Example usage of the function, loop out the result.
    #RESULT="$(mysql_query "SELECT col1, col2 FROM table")"
    #while read -r col1 col2; do
    #    echo "Col1: $col1, Col2: $col2"
    #done<<< "${RESULT}"
}

function get_tables_with_primary_col() {
    local DATABASE="$1"
    local TABLE="${2:-}"
    local FLAG="${3:-}"
    local RESULT

    local WHERE_DATABASE=""
    local WHERE_DATABASE_JOIN=""
    if [ -n "$DATABASE" ]; then
        WHERE_DATABASE="AND information_schema.TABLES.table_schema = '${DATABASE}'"
        WHERE_DATABASE_JOIN="AND information_schema.columns.table_schema = '${DATABASE}'"
    fi
    local WHERE_TABLES=""
    if [ -n "$TABLE" ]; then
        WHERE_TABLES="AND information_schema.TABLES.table_name LIKE '${TABLE//\*/%}'"
    fi
    if [[ "$FLAG" == "only-missing-primary-key" ]]; then
        WHERE_TABLES="${WHERE_TABLES} AND info_columns.column_name IS NULL"
    fi
    if [[ "$FLAG" == "no-missing-primary-key" ]]; then
        WHERE_TABLES="${WHERE_TABLES} AND info_columns.column_name IS NOT NULL"
    fi

    local QUERY=$(cat <<-EOF
        SELECT
            information_schema.TABLES.TABLE_SCHEMA as 'database_name',
            information_schema.TABLES.table_name as 'table_name',
            info_columns.column_name as 'primary_key_column'
        FROM
            information_schema.TABLES
        LEFT JOIN (
            SELECT *
            FROM information_schema.columns
            WHERE 1
                ${WHERE_DATABASE_JOIN}
                AND information_schema.columns.column_key = 'PRI'
            ORDER BY
                information_schema.columns.table_name,
                CASE WHEN information_schema.columns.extra LIKE '%auto_increment%' THEN 1 ELSE 2 END ASC,
                information_schema.columns.ordinal_position ASC
        ) as info_columns ON info_columns.table_name = information_schema.TABLES.table_name AND info_columns.table_schema = information_schema.TABLES.table_schema
        WHERE 1
            AND information_schema.TABLES.TABLE_TYPE = 'BASE TABLE'
            AND information_schema.TABLES.table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys')
            ${WHERE_DATABASE}
            ${WHERE_TABLES}
        GROUP BY
            information_schema.TABLES.table_schema,
            information_schema.TABLES.table_name
EOF
    )

    if ! RESULT="$(mysql_query "$QUERY")"; then
        echo "Error fetching tables with primary column, query: $QUERY" >&2
        return 1
    fi

    echo "$RESULT"
}

function sql_user_grants {
    local query

    query=$(cat <<-"EOF"
        SET SESSION group_concat_max_len = 4294967295;
        SELECT
          GROUP_CONCAT(
            sub.stmt
            ORDER BY
              -- Sort first by user, then host,
              sub.user_sort,
              sub.host_sort,
              -- then by statement type (create=1, global=2, db=3, table=4),
              sub.ordering,
              -- then by database, table, etc.
              sub.db_sort,
              sub.table_sort
            SEPARATOR '\n\n'  -- two line breaks between statements
          ) AS full_script
        FROM
        (
          --
          -- 1) CREATE USER statements
          --
          SELECT CONCAT(
            '-- CREATE USER for: ', user, '@', host, '\n',
            'CREATE USER IF NOT EXISTS `', user, '`@`', host, '` ',

            /* Authentication plugin (e.g., mysql_native_password) */
            CASE
              WHEN plugin IS NOT NULL AND plugin <> ''
                THEN CONCAT('IDENTIFIED WITH \'', plugin, '\' ')
              ELSE ''
            END,

            /* Password hash (authentication_string) */
            CASE
              WHEN authentication_string IS NOT NULL
                   AND authentication_string <> ''
                THEN CONCAT('AS \'', REPLACE(authentication_string, '\'', '\\\''), '\' ')
              ELSE ''
            END,

            /* SSL requirements */
            CASE
              WHEN ssl_type = '' OR ssl_type IS NULL THEN ''
              WHEN ssl_type = 'ANY'    THEN 'REQUIRE SSL '
              WHEN ssl_type = 'X509'   THEN 'REQUIRE X509 '
              WHEN ssl_type = 'SPECIFIED' THEN
                CONCAT(
                  'REQUIRE',
                  CASE
                    WHEN (ssl_cipher IS NOT NULL AND ssl_cipher <> '')
                      THEN CONCAT(' CIPHER \'', REPLACE(ssl_cipher, '\'', '\\\''), '\'')
                    ELSE ''
                  END,
                  CASE
                    WHEN (x509_issuer IS NOT NULL AND x509_issuer <> '')
                      THEN CONCAT(
                        CASE
                          WHEN (ssl_cipher IS NOT NULL AND ssl_cipher <> '') THEN ' AND'
                          ELSE ''
                        END,
                        ' ISSUER \'', REPLACE(x509_issuer, '\'', '\\\''), '\''
                      )
                    ELSE ''
                  END,
                  CASE
                    WHEN (x509_subject IS NOT NULL AND x509_subject <> '')
                      THEN CONCAT(
                        CASE
                          WHEN (
                            (ssl_cipher IS NOT NULL AND ssl_cipher <> '')
                            OR (x509_issuer IS NOT NULL AND x509_issuer <> '')
                          ) THEN ' AND'
                          ELSE ''
                        END,
                        ' SUBJECT \'', REPLACE(x509_subject, '\'', '\\\''), '\''
                      )
                    ELSE ''
                  END,
                  ' '
                )
              ELSE ''
            END,

            /* Resource limits (MAX_*) */
            'WITH ',
              'MAX_QUERIES_PER_HOUR ', max_questions, ' ',
              'MAX_UPDATES_PER_HOUR ', max_updates, ' ',
              'MAX_CONNECTIONS_PER_HOUR ', max_connections, ' ',
              'MAX_USER_CONNECTIONS ', max_user_connections, ' ',

            /* Unlock account */
            'ACCOUNT UNLOCK;'
          ) AS stmt,
          1 AS ordering,
          user AS user_sort,
          host AS host_sort,
          ''   AS db_sort,
          ''   AS table_sort
          FROM mysql.user
          WHERE user NOT IN (
            'mysql.infoschema','mysql.session','mysql.sys','root','debian-sys-maint',
            'mysqlxsys','mysql','phpmyadmin','sys','',
            'admin','rdsadmin','rdsrepladmin','rds_superuser_role'  -- exclude these as well
          )

          UNION ALL

          --
          -- 2) Global-level GRANTS (from mysql.user)
          --
          SELECT CONCAT(
            '-- Global GRANTS for: ', user, '@', host, '\n',
            'GRANT ',
            CONCAT_WS(
              ',',
              IF(Select_priv='Y','SELECT',NULL),
              IF(Insert_priv='Y','INSERT',NULL),
              IF(Update_priv='Y','UPDATE',NULL),
              IF(Delete_priv='Y','DELETE',NULL),
              IF(Create_priv='Y','CREATE',NULL),
              IF(Drop_priv='Y','DROP',NULL),
              IF(Reload_priv='Y','RELOAD',NULL),
              IF(Shutdown_priv='Y','SHUTDOWN',NULL),
              IF(Process_priv='Y','PROCESS',NULL),
              IF(File_priv='Y','FILE',NULL),
              IF(Grant_priv='Y','GRANT OPTION',NULL),
              IF(References_priv='Y','REFERENCES',NULL),
              IF(Index_priv='Y','INDEX',NULL),
              IF(Alter_priv='Y','ALTER',NULL),
              IF(Show_db_priv='Y','SHOW DATABASES',NULL),
              IF(Super_priv='Y','SUPER',NULL),
              IF(Create_tmp_table_priv='Y','CREATE TEMPORARY TABLES',NULL),
              IF(Lock_tables_priv='Y','LOCK TABLES',NULL),
              IF(Execute_priv='Y','EXECUTE',NULL),
              IF(Repl_slave_priv='Y','REPLICATION SLAVE',NULL),
              IF(Repl_client_priv='Y','REPLICATION CLIENT',NULL),
              IF(Create_view_priv='Y','CREATE VIEW',NULL),
              IF(Show_view_priv='Y','SHOW VIEW',NULL),
              IF(Create_routine_priv='Y','CREATE ROUTINE',NULL),
              IF(Alter_routine_priv='Y','ALTER ROUTINE',NULL),
              IF(Create_user_priv='Y','CREATE USER',NULL),
              IF(Event_priv='Y','EVENT',NULL),
              IF(Trigger_priv='Y','TRIGGER',NULL),
              IF(Create_tablespace_priv='Y','CREATE TABLESPACE',NULL)
            ),
            ' ON *.* TO `', user, '`@`', host, '`',
            IF(Grant_priv = 'Y',' WITH GRANT OPTION',''),
            ';'
          ) AS stmt,
          2 AS ordering,
          user AS user_sort,
          host AS host_sort,
          ''   AS db_sort,
          ''   AS table_sort
          FROM mysql.user
          WHERE user NOT IN (
            'mysql.infoschema','mysql.session','mysql.sys','root','debian-sys-maint',
            'mysqlxsys','mysql','phpmyadmin','sys','',
            'admin','rdsadmin','rdsrepladmin','rds_superuser_role'
          )
            AND (
              Select_priv='Y' OR Insert_priv='Y' OR Update_priv='Y' OR
              Delete_priv='Y' OR Create_priv='Y' OR Drop_priv='Y' OR
              Reload_priv='Y' OR Shutdown_priv='Y' OR Process_priv='Y' OR
              File_priv='Y'   OR Grant_priv='Y'   OR References_priv='Y' OR
              Index_priv='Y'  OR Alter_priv='Y'   OR Show_db_priv='Y'    OR
              Super_priv='Y'  OR Create_tmp_table_priv='Y'               OR
              Lock_tables_priv='Y' OR Execute_priv='Y' OR Repl_slave_priv='Y' OR
              Repl_client_priv='Y' OR Create_view_priv='Y' OR Show_view_priv='Y' OR
              Create_routine_priv='Y' OR Alter_routine_priv='Y' OR Create_user_priv='Y' OR
              Event_priv='Y' OR Trigger_priv='Y' OR Create_tablespace_priv='Y'
            )

          UNION ALL

          --
          -- 3) Database-level GRANTS (from mysql.db)
          --
          SELECT CONCAT(
            '-- DB-level GRANTS for: ', User, '@', Host, ' on `', Db, '`\n',
            'GRANT ',
            CONCAT_WS(
              ',',
              IF(Select_priv='Y','SELECT',NULL),
              IF(Insert_priv='Y','INSERT',NULL),
              IF(Update_priv='Y','UPDATE',NULL),
              IF(Delete_priv='Y','DELETE',NULL),
              IF(Create_priv='Y','CREATE',NULL),
              IF(Drop_priv='Y','DROP',NULL),
              IF(Grant_priv='Y','GRANT OPTION',NULL),
              IF(References_priv='Y','REFERENCES',NULL),
              IF(Index_priv='Y','INDEX',NULL),
              IF(Alter_priv='Y','ALTER',NULL),
              IF(Create_tmp_table_priv='Y','CREATE TEMPORARY TABLES',NULL),
              IF(Lock_tables_priv='Y','LOCK TABLES',NULL),
              IF(Execute_priv='Y','EXECUTE',NULL),
              IF(Create_view_priv='Y','CREATE VIEW',NULL),
              IF(Show_view_priv='Y','SHOW VIEW',NULL),
              IF(Create_routine_priv='Y','CREATE ROUTINE',NULL),
              IF(Alter_routine_priv='Y','ALTER ROUTINE',NULL),
              IF(Event_priv='Y','EVENT',NULL),
              IF(Trigger_priv='Y','TRIGGER',NULL)
            ),
            ' ON `', Db, '`.* TO `', User, '`@`', Host, '`',
            IF(Grant_priv='Y',' WITH GRANT OPTION',''),
            ';'
          ) AS stmt,
          3 AS ordering,
          User AS user_sort,
          Host AS host_sort,
          Db   AS db_sort,
          ''   AS table_sort
          FROM mysql.db
          WHERE User NOT IN (
            'mysql.infoschema','mysql.session','mysql.sys','root','debian-sys-maint',
            'mysqlxsys','mysql','phpmyadmin','sys','',
            'admin','rdsadmin','rds_superuser_role'
          )
            AND (
              Select_priv='Y' OR Insert_priv='Y' OR Update_priv='Y' OR
              Delete_priv='Y' OR Create_priv='Y' OR Drop_priv='Y' OR
              Grant_priv='Y' OR References_priv='Y' OR Index_priv='Y'  OR
              Alter_priv='Y' OR Create_tmp_table_priv='Y' OR Lock_tables_priv='Y' OR
              Execute_priv='Y' OR Create_view_priv='Y' OR Show_view_priv='Y' OR
              Create_routine_priv='Y' OR Alter_routine_priv='Y' OR
              Event_priv='Y' OR Trigger_priv='Y'
            )

          UNION ALL

          --
          -- 4) Table-level GRANTS (from mysql.tables_priv)
          --
          SELECT CONCAT(
            '-- Table-level GRANTS for: ', User, '@', Host,
            ' on `', Db, '`.`', Table_name, '`\n',
            'GRANT ',
            Table_priv,
            ' ON `', Db, '`.`', Table_name, '` TO `', User, '`@`', Host, '`;'
          ) AS stmt,
          4 AS ordering,
          User       AS user_sort,
          Host       AS host_sort,
          Db         AS db_sort,
          Table_name AS table_sort
          FROM mysql.tables_priv
          WHERE User NOT IN (
            'mysql.infoschema','mysql.session','mysql.sys','root','debian-sys-maint',
            'mysqlxsys','mysql','phpmyadmin','sys','',
            'admin','rdsadmin','rdsrepladmin','rds_superuser_role'
          )
        ) AS sub
        /*
          We do GROUP_CONCAT to produce one big script (1 row).
          Sorted primarily by user, host, then statement type, db, table.
        */
        ORDER BY NULL;  -- let GROUP_CONCAT's ORDER BY handle sorting internally
EOF
    )

    mysql_query "$query" | sed 's/\\n/\n/g' > "${PARAMS["outputdir"]}/mysql_user_grants.sql"
}

function mydumper_version() {
    mydumper --version | grep -oP '(?<=v)\d+\.\d+\.\d+'
}

echo "Config chosen: $CONFIG"

# Define and initialize an associative array for parameters with sane defaults
declare -A PARAMS=(
    ["port"]=3306
    ["verbose"]=3
    ["compress-protocol"]="ZSTD"
    ["compress"]="ZSTD"
    ["long-query-guard"]=1800
    ["skip-definer"]=false
    ["build-empty-files"]=true
    ["trx-tables"]=false # If you only use InnoDB. Equivalent to --single-transaction. Typically AUTO below will result in this anyway.
    ["sync-thread-lock-mode"]="AUTO" # Consistent backup on RDS
    ["rows"]=250000 # Splitting tables into chunks of this many rows. It can be MIN:START_AT:MAX. MAX can be 0 which means that there is no limit. It will double the chunk size if query takes less than 1 second and half of the size if it is more than 2 seconds
    ["order-by-primary"]=true
    ["threads"]=8
    ["user"]="mydumper"
    ["defaults-extra-file"]='mydumper.${CONFIG}.cnf'
    ["outputdir"]='./mysql-backups/'
    ["ssl"]=true
    #["checksum-all"]=true
    #["check-row-count"]=true
    ["triggers"]=true
    ["events"]=true
    ["routines"]=true

    #["all-tablespaces"]=true # To backup all
    #["database"]=mysql       # To backup only the specified database
)

# Change some defaults based on the version
if [[ $(mydumper_version) < "0.17.2" ]]; then
    unset PARAMS["sync-thread-lock-mode"]
    unset PARAMS["trx-tables"]
    PARAMS["lock-all-tables"]=true # Consistent backup on RDS on older versions of mydumper
fi

# Define and initialize an associative array for internal parameters, that won't be part of the backup command.
declare -A INTERNAL_PARAMS=(
    ["tar"]=false
    ["keep-backups"]=0 # 0 = unlimited (only applies locally, not to s3 - use lifecycle policies for that)
    ["config"]=""
    ["password"]=""
    ["s3region"]=eu-north-1
    ["s3profile"]=""
    ["s3tar"]=false # Requires 'tar' to be set to true as well
    ["user-grants"]=false
)
INTERNAL_KEYS=("s3path" "password" "tar" "s3tar" "keep-backups" "s3region" "s3profile" "config" "table-limits" "user-grants")

# Extract all keys under the specified database configuration
KEYS=$(yq eval ".${CONFIG} | keys | .[]" "$YAML_FILE" 2>/dev/null || echo "")
if [[ -z "$KEYS" ]]; then
    echo "The config key '${CONFIG}' does not exist in the YAML file: ${YAML_FILE}"
    exit 2
fi

# Loop through each key and append it to the command array
for KEY in $KEYS; do
    # Extract the value for the key
    VALUE=$(yq eval ".${CONFIG}.${KEY}" "$YAML_FILE")

    # Check if the key is in the INTERNAL_KEYS array, otherwise set the new value in the PARAMS associative array
    if [[ " ${INTERNAL_KEYS[@]} " =~ " ${KEY} " ]]; then
        INTERNAL_PARAMS["$KEY"]="$VALUE"
    else
        PARAMS["$KEY"]="$VALUE"
    fi
done


# Create the default-extra-file for the mydumper command
MYSQL_DEFAULTS_EXTRA_FILE=$(echo "${PARAMS['defaults-extra-file']}" | envsubst)
echo "Creating the defaults-extra-file: ${MYSQL_DEFAULTS_EXTRA_FILE}"
MYSQL_HOST=$(echo "${PARAMS['host']}" | envsubst)
MYSQL_PORT=$(echo "${PARAMS['port']}" | envsubst)
MYSQL_USER=$(echo "${PARAMS['user']}" | envsubst)
MYSQL_PASSWORD=$(echo "${INTERNAL_PARAMS['password']}" | envsubst)
CUSTOM_CONFIG=$(echo "${INTERNAL_PARAMS['config']}" | envsubst)
cat << EOF | envsubst | tee "${MYSQL_DEFAULTS_EXTRA_FILE}" >/dev/null
[client]
host=${MYSQL_HOST}
port=${MYSQL_PORT}
user=${MYSQL_USER}
password=${MYSQL_PASSWORD}

[mydumper]

[\`test\`.\`<table>\`]
rows = -1                         # Disable chunks when using limit, to only get 1*limit rows.
limit = 0                         # Effectively 'no-data' mode
where = 1 ORDER BY \`id\` DESC      # Get the limit from the latest rows

EOF


# Check if we need to apply special logic to fix the issue that mydumper does not handle missing primary keys properly when using --order-by-primary
if [[ -n "${PARAMS[order-by-primary]}" && "${PARAMS[order-by-primary]}" == "true" ]]; then
    db_filter="${PARAMS['database']:-}"

    echo "Order by primary set as default. Check if we have any tables with a missing primary key to avoid errors."
    if ! RESULT=$(get_tables_with_primary_col "$db_filter" "" "only-missing-primary-key"); then
        echo "Error fetching tables with missing primary key."
        exit 1
    fi
    ROW_COUNT="$(echo -n "$RESULT" | wc -l)"
    echo "Found $ROW_COUNT tables with missing primary key."

    # If we have any tables with missing primary keys, or if table-limits is used, we need to disable the global order-by-primary flag, and generate per table configs instead.
    if [[ $ROW_COUNT -gt 0 || -v INTERNAL_PARAMS["table-limits"] ]]; then
        echo "Setting order-by-primary to false for all tables and add a per table config to sort by the primary col."
        PARAMS["order-by-primary"]=false

        if ! RESULT=$(get_tables_with_primary_col "$db_filter"); then
            echo "Error fetching tables with primary key column."
            exit 1
        fi
        # Unfortunately mydumper does not support setting the order-by-primary flag per table yet, so we have to set the 'order by' manually instead.
        echo "# order-by-primary fix for tables that has a primary key to avoid errors on tables that are missing it" >> "${MYSQL_DEFAULTS_EXTRA_FILE}"
        while read -r db table col; do
            if [[ -z "$table" ]]; then
                echo "Could not find any primary key tables"
                continue
            fi
            if [[ $col == "NULL" ]]; then
                echo "Skipping to set a ORDER BY clause due to no primary key column on table: '${db}.${table}'"
                continue
            fi
            #echo "Set ORDER BY for '${db}.${table}' to '${col}'"
            ROW_ORDER_BY="where = 1 ORDER BY \`$col\` ASC"
            cat << EOF | envsubst | tee -a "${MYSQL_DEFAULTS_EXTRA_FILE}" >/dev/null
[\`${db}\`.\`${table}\`]
${ROW_ORDER_BY}
EOF
        done <<< "${RESULT}"
        echo "" >> "${MYSQL_DEFAULTS_EXTRA_FILE}"
    fi
fi


# Generate the default-extra-file content for the 'table-limits' parameter
if [[ -v INTERNAL_PARAMS["table-limits"] ]]; then
    # Extract all keys under the specified database configuration for the 'table-limits' parameter
    KEYS=$(yq eval ".${CONFIG}.table-limits | keys | .[]" "$YAML_FILE")

    echo "Generating table-limits for the config: ${CONFIG}"
    # Loop through each key and generate a config for each match for the 'table-limits' parameter
    for KEY in $KEYS; do
        # Escape the key so we can use it with grep and get the variable content interpreted as a string, not a regex, as yq struggles with this.
        ESCAPED_KEY="$(printf '%s' "${KEY}" | sed 's/[.[\*^$()+?{}|]/\\&/g')"

        LIMIT=$(yq eval ".${CONFIG}.table-limits" "$YAML_FILE" | grep -E "^${ESCAPED_KEY}:" | awk '{print $2}')
        echo "Generating config for: ${KEY}: ${LIMIT}"

        # Split the KEY into database and table
        IFS='.' read -ra ADDR <<< "${KEY}"
        DATABASE="${ADDR[0]}"
        TABLE="${ADDR[1]}"

        RESULT="$(get_tables_with_primary_col "${DATABASE}" "${TABLE}")"
        # shellcheck disable=SC2034
        while read -r db table col; do
            if [[ -z "$table" ]]; then
                echo "Could not find any tables matching the key: ${KEY}"
                continue
            fi
            #echo "$table.$col"
            ROW_LIMIT="limit = ${LIMIT}"
            ROW_WHERE="where = 1 ORDER BY \`$col\` DESC"
            if ! [[ "${LIMIT}" =~ ^[0-9]+$ ]] || (( LIMIT < 0 )); then
                ROW_LIMIT="limit = 18446744073709551615" # If not a valid number, skip the limit (by setting it to the max value)
                ROW_WHERE="" # Skip the ORDER BY part for tables where we don't want to limit the rows
            fi
            if [[ $col == "NULL" ]] || [[ "${LIMIT}" == "0" ]]; then
                ROW_WHERE="" # Skip the ORDER BY part for tables without primary key, or if the limit is set to 0
            fi
            cat << EOF | envsubst | tee -a "${MYSQL_DEFAULTS_EXTRA_FILE}" >/dev/null
[\`${DATABASE}\`.\`${table}\`]
rows = -1
${ROW_LIMIT}
${ROW_WHERE}

EOF
        done<<< "${RESULT}"
    done
fi

echo "${CUSTOM_CONFIG}" >> "${MYSQL_DEFAULTS_EXTRA_FILE}"


# Override the default output directory to append the config and timestamp
PARAMS["outputdir"]="${PARAMS["outputdir"]%/}/${CONFIG}/${TIMESTAMP}"

# Build the command using the parameters in the array
CMD=("mydumper")
for KEY in "${!PARAMS[@]}"; do
    VALUE=$(echo "${PARAMS[$KEY]}" | envsubst)
    if [[ "${VALUE}" == "true" ]]; then
        # Check if the key is a single character
        if [[ "${#KEY}" -eq 1 ]]; then
            CMD+=("-${KEY}")
        else
            CMD+=("--$KEY")
        fi
    elif [[ "${VALUE}" != "false" ]]; then
        # Check if the key is a single character
        if [[ "${#KEY}" -eq 1 ]]; then
            CMD+=("-${KEY} ${VALUE}")  # Use single-character flag with space
        else
            CMD+=("--${KEY}=${VALUE}")
        fi
    fi
done


# Backup preparation
BACKUP_DIR=$(echo "${PARAMS['outputdir']}" | envsubst)
echo "Saving the backup output to: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"
echo "Running command: ${CMD[*]}"

# Execute the mydumper command
START=$(date +%s)
"${CMD[@]}" || EXIT_CODE=$?
# --exec="ls FILENAME"  # Execute a command after each file is written
EXIT_CODE=${EXIT_CODE:-0}
echo ""

if [[ -n "${INTERNAL_PARAMS[user-grants]}" && "${INTERNAL_PARAMS[user-grants]}" == "true" ]]; then

    echo "Generating an SQL file for user grants, separate from mydumper."
    sql_user_grants # Generate the SQL script for the user grants
    echo ""
else
    echo "Not generating a separate sql file for user grants. Set 'user-grants: true' to enable this feature."
fi

END=$(date +%s)
SECONDS=$((END-START))
SIZE=$(du -sh "${BACKUP_DIR}" | awk '{print $1}')
echo "The backup runtime was ${SECONDS} seconds, finished at $(timestamp). Total size: ${SIZE}."

# Remove the password from the defaults-extra-file
sed -i -e 's/^password=.*/#password=\*\*\*\*\*/g' "${MYSQL_DEFAULTS_EXTRA_FILE}"

if [ "$EXIT_CODE" -ne 0 ]; then
    echo "But, the backup failed with exit code: $EXIT_CODE"
    exit "$EXIT_CODE"
fi

function sync_to_s3() {
    local BACKUP_DIR="$1"
    local TYPE="${2:-folder}"
    if [[ -v INTERNAL_PARAMS["s3path"] ]]; then
        if [[ "$TYPE" == "file" ]]; then
            S3_PATH=$(echo "${INTERNAL_PARAMS['s3path']%/}/${CONFIG}/" | envsubst)
        else
            S3_PATH=$(echo "${INTERNAL_PARAMS['s3path']%/}/${CONFIG}/${TIMESTAMP}" | envsubst)
        fi

        S3_REGION=$(echo "${INTERNAL_PARAMS['s3region']}" | envsubst)
        S3_PROFILE=$(echo "${INTERNAL_PARAMS['s3profile']}" | envsubst)
        echo ""
        echo "Upload files to S3, path: ${S3_PATH}"

        if [[ "$TYPE" == "file" ]]; then
            local CMD=(aws s3 cp "${BACKUP_DIR}" "s3://${S3_PATH}" --region "${S3_REGION}")
        else
            local CMD=(aws s3 sync "${BACKUP_DIR}" "s3://${S3_PATH}" --region "${S3_REGION}")
        fi

        # Append the S3 profile if it is set
        if [[ -n "${S3_PROFILE}" ]]; then
            confirm_aws_profile "${S3_PROFILE}"
            CMD+=("--profile" "${S3_PROFILE}")
        fi

        echo "Executing command: ${CMD[*]}"

        local attempts=1
        while true; do
            set +e           # Temporarily disable exit on error
            "${CMD[@]}"      # Run the S3 command
            local RESULT=$?  # Store the exit code
            set -e           # Re-enable exit on error

            # Check if the last command was successful
            if [ $RESULT -eq 0 ]; then
                echo "File(s) synced to S3 successfully."
                break
            else
                echo "File sync to s3 failed with exit code $RESULT."
            fi

            # Increment the counter
            ((attempts++))

            # Break the loop if the maximum number of iterations is reached
            if [ $attempts -gt 5 ]; then
                echo "The file sync to s3 has reached the maximum attempts allowed. Giving up."
                exit 1
            fi
        done
    fi
}

function create_tar() {
    echo ""
    echo "Creating a tar file."
    echo "$BACKUP_DIR.tar"

    # Perform the tar operation with progress display and capture the exit code
    tar -C "${BACKUP_DIR}" . -cf - | (pv -p --timer --rate --bytes > "${BACKUP_DIR}.tar")

    # Get the full pipeline's exit code automatically due to us using pipefail in the script.
    TAR_EXIT_CODE=$?
    if [ $TAR_EXIT_CODE -eq 0 ]; then
        echo "Tar command completed successfully."
        rm -rf "${BACKUP_DIR}"
        echo "Decompress by: tar -xvf ${BACKUP_DIR}.tar"
        echo "View content by: vi ${BACKUP_DIR}.tar"
    else
        echo "Tar command failed with exit code $TAR_EXIT_CODE."
        exit 1
    fi
}

# Check if the 's3path' parameter is set, if so, move the files to the specified S3 path.
if [[ -v INTERNAL_PARAMS["s3path"] ]]; then
    if [[ -n "${INTERNAL_PARAMS['tar']+set}" && "${INTERNAL_PARAMS['tar']}" != "false" ]] && [[ -n "${INTERNAL_PARAMS['s3tar']+set}" && "${INTERNAL_PARAMS['s3tar']}" != "false" ]]; then
        create_tar
        sync_to_s3 "${BACKUP_DIR}.tar" "file"
    else
        sync_to_s3 "${BACKUP_DIR}"
    fi
fi

# Check if only the 'tar' parameter is set, if so, we will tar the directory and remove the original directory.
if [[ -n "${INTERNAL_PARAMS['tar']+set}" && "${INTERNAL_PARAMS['tar']}" != "false" ]] && ! [[ -n "${INTERNAL_PARAMS['s3tar']+set}" && "${INTERNAL_PARAMS['s3tar']}" != "false" ]]; then
    create_tar
fi


# Check if the 'keep-backups' parameter is set, if so, delete the oldest backups up to that number of backups to keep.
if [[ -v INTERNAL_PARAMS["keep-backups"] ]] && [[ INTERNAL_PARAMS["keep-backups"] -gt 0 ]]; then
    KEEP_BACKUPS=$(( ${INTERNAL_PARAMS['keep-backups']} + 0 ))
    echo ""
    echo "Keep a maximum of ${KEEP_BACKUPS} backups."
    PREFIX="$(dirname "${BACKUP_DIR}")/"
    NUM_BACKUPS=$(( $(ls -ctr "${PREFIX}" | wc -l) + 0 ))
    echo "Found a total of $NUM_BACKUPS backups in ${PREFIX}"
    if [ $NUM_BACKUPS -gt $KEEP_BACKUPS ]; then
        NUM_REMOVE=$(( NUM_BACKUPS - $KEEP_BACKUPS ))
        echo "Removing $NUM_REMOVE backup(s)..."
        REMLIST=$(ls -ctr "${PREFIX}" | head -n ${NUM_REMOVE})
        for i in $REMLIST
        do
            rm -v -rf "${PREFIX}${i}"
        done

        if [[ -v INTERNAL_PARAMS["s3path"] ]]; then
            echo "Please note that this does not remove anything from S3. Use lifecycle policies for that."
        fi
    fi
fi

echo ""
echo ""
echo "The dump runtime was ${SECONDS} seconds. Total dump size: ${SIZE}."
echo "Backup completed at: $(timestamp)."
echo ""
echo "To restore the backup, use a variation of the following commands:"
echo ""
echo ""


cat << EOF
# 1) Sync the backup from S3 to the local machine
aws s3 sync s3://$(echo "${INTERNAL_PARAMS['s3path']%/}/${CONFIG}/" | envsubst)<backup> ~/mysql-restore/ --region ${S3_REGION} --profile <optional-profile>
or
./s3-browser.sh s3://$(echo "${INTERNAL_PARAMS['s3path']%/}/${CONFIG}/" | envsubst) ~/mysql-restore/ --latest --download

# 1a) If a tarball, decompress the file
tar -xvf ~/mysql-restore/${TIMESTAMP}.tar

# 2) Restore the backup
./myloader.sh --host="<new-host>" --directory="~/mysql-restore/" --logfile="~/myloader.log" \\
              --source-db="${DATABASE:-app}" --database="restored-${DATABASE:-app}" \\
              --table="${DATABASE:-app}.table1" \\
              --skip-post=false --skip-triggers=false # If you want to restore triggers, procedures/functions, events. By default skipped.

Notes:
- Consider using --disable-redo-log to significantly speed up the restore time on test environments, but only if it isn't already disabled.
- For restoring in GTID-enabled setups (e.g., GTID replication), pay attention to --set-gtid-purged, only use it if you know you need it.
- For better performance, the likely bottlenecks are disk I/O and CPU.
- Try to adjust the --threads parameter to find the optimal value for your setup. It should never be more than the number of cores available.

EOF
