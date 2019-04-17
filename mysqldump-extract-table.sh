#!/usr/bin/env bash

if [[ $# -lt 1 ]]; then
    echo "You have not passed any arguments, use this script like this:"
    echo "'bash mysqldump-extract.sh dbdump.sql'       -- This will list all tables available"
    echo "'bash mysqldump-extract.sh dbdump.sql table' -- This will extract one table into a separate sql dump file"
    echo ""
    exit 1
fi

FILE="$1"
TABLE="$2"
FILE_EXTRACT="${FILE}_${TABLE}.sql"

# List all tables available
if [[ $# -lt 2 ]]; then
    grep -n -E '^-- Table structure for table `(.*)`$' "${FILE}"
    exit 0
fi

# Extract one table into a separate sql dump file
if [[ "${FILE}" == *".gz" ]]; then
    echo "This script does not work on gzipped dumps, please gunzip before using this script."
    exit 1
fi

if [[ -f "${FILE_EXTRACT}"  ]]; then
    echo "A destination file already exist with that name, please remove before proceeding. File name: ${FILE_EXTRACT}"
    exit 1
fi

if [[ -f "${FILE_EXTRACT}"  ]]; then
    echo "A destination file already exist with that name, please remove before proceeding. File name: ${FILE_EXTRACT}"
    exit 1
fi

# @todo Handle scenarios when two tables matches

echo "Find positions for table \`${TABLE}\`..."

START_POSITION=$(grep -n -E "^-- Table structure for table \`${TABLE}\`$" "${FILE}" | sed 's/:.*//g')
START_POSITION=$((START_POSITION - 1))

END_POSITION=$(grep -n -E "^/\\*!40000 ALTER TABLE \`${TABLE}\` ENABLE KEYS \\*/;$" "${FILE}" | sed 's/:.*//g')

if sed -n "$((${END_POSITION} + 1))p" "${FILE}" | grep -q -E "^UNLOCK TABLES;$"; then
    END_POSITION=$((END_POSITION + 1))
fi

echo "Start position: $START_POSITION"
echo "End position: $END_POSITION"
echo "Extracting..."

# Extract the global heading
head -n33 "${FILE}" | grep -E '^--|^/\*![0-9]{5}|^$' | sed -n '1,5p;6,/--/ p' | head -n -1 > "${FILE_EXTRACT}"

# Extract the content related to the table
sed -n "${START_POSITION},${END_POSITION} p" "${FILE}" >> "${FILE_EXTRACT}"

# Extract the global footer
echo "" >> "${FILE_EXTRACT}"
tail -n 20 "${FILE}" | tac | grep -E '^--|^/\*![0-9]{5}|^$' | sed -n '1,5p;6,/--/ p' | head -n -1 | tac >> "${FILE_EXTRACT}"

echo "Complete!"
