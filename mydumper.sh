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

if ! dpkg-query --show --showformat='${db:Status-Status}\n' 'libatomic1' | grep -q 'installed' || ! hash mydumper zstd yq pv &>/dev/null; then
    echo "Missing dependencies and/or mydumper is not installed"
    #exit 1

    sudo apt-get install libatomic1 zstd pv -y
    sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq

    MYDUMPER_VERSION="$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/mydumper/mydumper/releases/latest | cut -d'/' -f8)"
    wget "https://github.com/mydumper/mydumper/releases/download/${MYDUMPER_VERSION}/mydumper_${MYDUMPER_VERSION:1}.$(lsb_release -cs)_amd64.deb"
    sudo dpkg -i "mydumper_${MYDUMPER_VERSION:1}.$(lsb_release -cs)_amd64.deb"
    rm -f "mydumper_${MYDUMPER_VERSION:1}.$(lsb_release -cs)_amd64.deb"
fi

if [ -z "$1" ]; then
    echo "# Usage: script.sh <config-key>"
    exit 1
fi

YAML_FILE="mydumper.yaml" # Path to your YAML file

if [ ! -f "$YAML_FILE" ]; then
    echo "The config YAML file does not exist: $YAML_FILE"
    exit 1
fi

# Export two variables to be used in the script with 'envsubst'
export CONFIG="$1"
export TIMESTAMP=$(date +%Y-%m-%dT%H%M%S)

timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

mysql_query() {
    local QUERY="$1"
    local FIRST_ROW_FIRST_COL_ONLY="${2:-false}"
    local RESULT="$(mysql --defaults-extra-file="${MYSQL_DEFAULTS_EXTRA_FILE}" -N -B -e "$QUERY")"

    if [[ "$FIRST_ROW_FIRST_COL_ONLY" == "true" || "$FIRST_ROW_FIRST_COL_ONLY" == "1" ]]; then
        echo "$RESULT" | head -n 1 | cut -f1
    else
        echo "$RESULT"
    fi

    # Example usage of the function, loop out the result.
    #RESULT="$(mysql_query "SELECT col1, col2 FROM table")"
    #while read -r col1 col2; do
    #    echo "Col1: $col1, Col2: $col2"
    #done<<< "${RESULT}"
}

function get_tables_with_primary_col() {
    local DATABASE="$1"
    local TABLE="$2"

    local WHERE_TABLES=""
    if [ -n "$TABLE" ]; then
        WHERE_TABLES="AND information_schema.TABLES.table_name LIKE '${TABLE//\*/%}'"
    fi

    local QUERY=$(cat <<-EOF
        SELECT
            information_schema.TABLES.table_name as name,
            info_columns.column_name as primary_col
        FROM
            information_schema.TABLES
        LEFT JOIN (
            SELECT *
            FROM information_schema.columns
            WHERE information_schema.columns.table_schema = '${DATABASE}'
            AND information_schema.columns.column_key = 'PRI'
            ORDER BY
            information_schema.columns.table_name,
            CASE WHEN information_schema.columns.extra LIKE '%auto_increment%' THEN 1 ELSE 2 END ASC,
            information_schema.columns.ordinal_position ASC
        ) as info_columns ON info_columns.table_name = information_schema.TABLES.table_name AND info_columns.table_schema = information_schema.TABLES.table_schema
        WHERE
            information_schema.TABLES.table_schema = '${DATABASE}'
            ${WHERE_TABLES}
        GROUP BY
            information_schema.TABLES.table_name
EOF
    )

    local RESULT="$(mysql_query "$QUERY")"
    echo "$RESULT"
}

echo "Config chosen: $CONFIG"

# Define and initialize an associative array for parameters with sane defaults
declare -A PARAMS=(
    ["port"]=3306
    ["verbose"]=3
    ["compress-protocol"]="ZSTD"
    ["compress"]="ZSTD"
    ["long-query-guard"]=1800
    ["skip-definer"]=true
    ["build-empty-files"]=true
    ["trx-consistency-only"]=false # Not an option for RDS, requires SUPER. Equivalent to --single-transaction.
    ["lock-all-tables"]=true       # Consistent backup on RDS
    #["no-locks"]=true
    #["less-locking"]=true
    ["rows"]=250000 # Splitting tables into chunks of this many rows. It can be MIN:START_AT:MAX. MAX can be 0 which means that there is no limit. It will double the chunk size if query takes less than 1 second and half of the size if it is more than 2 seconds
    ["order-by-primary"]=false
    ["threads"]=8
    ["user"]="mydumper"
    ["defaults-extra-file"]='mydumper.${CONFIG}.cnf'
    ["outputdir"]='./mysql-backups/'
    ["ssl"]=true
    #["checksum-all"]=true
    #["check-row-count"]=true
    ["triggers"]=false
    ["events"]=false
    ["routines"]=false
    #["all-tablespaces"]=true # To backup all
    #["database"]=mysql       # To backup only the specified database
)

# Define and initialize an associative array for internal parameters, that won't be part of the backup command.
declare -A INTERNAL_PARAMS=(
    ["tar"]=false
    ["keep-backups"]=0 # 0 = unlimited (only applies locally, not to s3 - use lifecycle policies for that)
    ["config"]=""
    ["password"]=""
    ["s3region"]=eu-north-1
    ["s3profile"]=default
    ["s3tar"]=false
)
INTERNAL_KEYS=("s3path" "password" "tar" "s3tar" "keep-backups" "s3region" "s3profile" "config" "table-limits")

# Extract all keys under the specified database configuration
KEYS=$(yq eval ".${CONFIG} | keys | .[]" "$YAML_FILE")

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
where = 1 ORDER BY \`id\` DESC    # Get the limit from the latest rows

EOF

# Generate the default-extra-file content for the 'table-limits' parameter
if [[ -v INTERNAL_PARAMS["table-limits"] ]]; then
    # Extract all keys under the specified database configuration for the 'table-limits' parameter
    KEYS=$(yq eval ".${CONFIG}.table-limits | keys | .[]" "$YAML_FILE")

    echo "Generating table-limits for the config: ${CONFIG}"
    # Loop through each key and generate a config for each match for the 'table-limits' parameter
    for KEY in $KEYS; do
        # Escape the key so we can use it with grep and get the variable content interpreted as a string, not a regex, as yq struggles with this.
        ESCAPED_KEY="$(printf '%s' "${KEY}" | sed 's/[.[\*^$()+?{}|]/\\&/g')"

        LIMIT=$(yq eval ".${CONFIG}.table-limits" "$YAML_FILE" | grep -e "^${ESCAPED_KEY}" | awk '{print $2}')
        echo "Generating config for: ${KEY}: ${LIMIT}"

        # Split the KEY into database and table
        IFS='.' read -ra ADDR <<< "${KEY}"
        DATABASE="${ADDR[0]}"
        TABLE="${ADDR[1]}"

        RESULT="$(get_tables_with_primary_col "${DATABASE}" "${TABLE}")"
        while read -r table col; do
            if [[ -z "$table" ]]; then
                echo "Could not find any tables matching the key: ${KEY}"
                continue
            fi
            #echo "$table.$col"
            ROW_LIMIT="limit = ${LIMIT}"
            if ! [[ "${LIMIT}" =~ ^[0-9]+$ ]] || (( LIMIT < 0 )); then
                ROW_LIMIT="" # If not a valid number, skip the limit
            fi
            ROW_WHERE="where = 1 ORDER BY \`$col\` DESC"
            if [[ $col == "NULL" ]]; then
                ROW_WHERE="" # Skip the ORDER BY part for tables without primary key
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

# Backup preparation
BACKUP_DIR=$(echo "${PARAMS['outputdir']}" | envsubst)
echo "Saving the backup output to: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"
echo "Running command: ${CMD[*]}"

# Execute the mydumper command
START=$(date +%s)
"${CMD[@]}"
# --exec="ls FILENAME"  # Execute a command after each file is written
RESULT=$?
END=$(date +%s)
SECONDS=$((END-START))
SIZE=$(du -sh "${BACKUP_DIR}" | awk '{print $1}')
echo "The backup runtime was ${SECONDS} seconds, finished at $(timestamp). Total size: ${SIZE}."

# Remove the password from the defaults-extra-file
sed -i -e 's/^password=.*/#password=\*\*\*\*\*/g' "${MYSQL_DEFAULTS_EXTRA_FILE}"

if [ $RESULT -ne 0 ]; then
    echo "But, the backup failed with exit code: $RESULT"
    exit $RESULT
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

        local attempts=1
        while true; do
            # Execute the command, capture the exit code
            if [[ "$TYPE" == "file" ]]; then
                echo aws s3 cp "${BACKUP_DIR}" "s3://${S3_PATH}" --region "${S3_REGION}" --profile "${S3_PROFILE}"
                     aws s3 cp "${BACKUP_DIR}" "s3://${S3_PATH}" --region "${S3_REGION}" --profile "${S3_PROFILE}" || true
            else
                echo aws s3 sync "${BACKUP_DIR}" "s3://${S3_PATH}" --region "${S3_REGION}" --profile "${S3_PROFILE}"
                     aws s3 sync "${BACKUP_DIR}" "s3://${S3_PATH}" --region "${S3_REGION}" --profile "${S3_PROFILE}" || true
            fi
            local RESULT=$?

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
    if [[ -v INTERNAL_PARAMS["tar"] ]] && [[ -v INTERNAL_PARAMS["s3tar"] ]]; then
        create_tar
        sync_to_s3 "${BACKUP_DIR}.tar" "file"
    else
        sync_to_s3 "${BACKUP_DIR}"
    fi
fi

# Check if the 'tar' parameter is set, if so, we will tar the directory and remove the original directory.
if [[ -v INTERNAL_PARAMS["tar"] ]] && ! [[ -v INTERNAL_PARAMS["s3tar"] ]]; then
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
echo "Backup completed at: $(timestamp)."
echo ""
echo "To restore the backup, use a variation of the following commands:"
echo ""
echo ""


cat << EOF
# Sync the backup from S3 to the local machine
aws s3 sync s3://$(echo "${INTERNAL_PARAMS['s3path']%/}/${CONFIG}/" | envsubst)<backup> ~/mysql-restore/ --region ${S3_REGION} --profile ${S3_PROFILE}

# If a tarball, decompress the file
tar -xvf ~/mysql-restore/${TIMESTAMP}.tar

# Restore the backup
myloader --host=<new-host> --user=root --ask-password --ssl --compress-protocol=ZSTD \\
         --directory="~/mysql-restore/" \\
         --threads=4 --verbose=3 \\
         --disable-redo-log --show-warnings --skip-definer \\
         --source-db="${DATABASE}" --database="restored-${DATABASE}" --overwrite-tables \\
         --regex="^${DATABASE}\.(table1|table2)$"

EOF
