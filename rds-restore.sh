#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
cancelled() { echo "Cancelled." >&2; exit 130; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

need aws
need jq

################################################################################
# Dynamically calculate height, width, and menu-height based on terminal size
# if available, and prints them as "<height> <width> <menu_height>".
################################################################################
calc_whiptail_size() {
  local term_rows=24
  local term_cols=80

  if command -v tput &>/dev/null; then
    local r c
    r=$(tput lines </dev/tty 2>/dev/null || true)
    c=$(tput cols </dev/tty 2>/dev/null || true)
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

  echo "$dh $dw $dm"
}

calc_whiptail_hw() {
  # prints "<height> <width>" suitable for inputbox
  local h w m
  read -r h w m < <(calc_whiptail_size)
  echo "$h $w"
}

# -------------------- Globals / flags --------------------
REGION="" # from --region; if empty, aws cli uses env/config

has_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }

# Default to interactive when /dev/tty is usable
INTERACTIVE=0
if has_tty; then
  INTERACTIVE=1
fi

YES=0
DRY_RUN=0
NO_WAIT=0

# Intent
LATEST=1
RESTORE_TIME_SPEC="" # user-supplied: ISO8601 or relative like -5m/-2h
RESTORE_TIME_ISO="" # computed ISO8601 for AWS (empty => latest)
SNAPSHOT_ID=""

# Source/target
SOURCE=""
SOURCE_ARG=""
TARGET=""
AURORA_WRITER_INSTANCE=""
source_type=""
SOURCE_KIND=""
SOURCE_AUTOMATED_BACKUP_ARN=""
SOURCE_CLUSTER_RESOURCE_ID=""
SOURCE_METADATA_REGION=""
SOURCE_BACKUP_EARLIEST=""
SOURCE_BACKUP_LATEST=""
SOURCE_BACKUP_RETENTION=""
SOURCE_ENGINE=""
SOURCE_SNAPSHOT_TIME=""

# Restorable bounds (raw + display)
EARLIEST_RESTORABLE=""
LATEST_RESTORABLE=""
RETENTION_DAYS=""
EARLIEST_DISPLAY=""
LATEST_DISPLAY=""

# Overrides (flags)
DB_INSTANCE_CLASS=""
DB_SUBNET_GROUP=""
VPC_SG_IDS=""
PUBLICLY_ACCESSIBLE="" # true|false (instance only)
MULTI_AZ="" # true|false (instance only)
DB_PARAMETER_GROUP=""
DB_CLUSTER_PARAMETER_GROUP=""
OPTION_GROUP=""

# Validation is intentionally delayed until after the execution plan is printed.
# That way a missing target-region resource still shows the command shape that
# needs to be fixed.
VALIDATION_ERRORS=()

usage() {
  cat <<'EOF_USAGE'
Usage:
  rds-restore.sh [--help] [--interactive] [--yes] [--dry-run] [--no-wait] [--region <region>]
    [--source <id>] [--target <new-id>]
    [--latest | --restore-time <ISO8601|relative> | --snapshot-id <snapshot-id>]
    [--aurora-writer-instance <id>]
    [--db-instance-class <class>]
    [--db-subnet-group <name>]
    [--vpc-sg-ids <sg-1,sg-2,...>]
    [--publicly-accessible true|false] (RDS instance only)
    [--multi-az true|false] (RDS instance only)
    [--db-parameter-group <name>] (RDS instance only)
    [--db-cluster-parameter-group <name>] (Aurora cluster only)
    [--option-group <name>]

Region behavior:
  The selected AWS region is the restore target region.
  Examples:
    AWS_REGION=eu-west-1 ./rds-restore.sh
    ./rds-restore.sh --region eu-west-1

Source selectors:
  Plain source IDs are supported, as before:
    --source db01

  The interactive menu can also select these explicit source forms:
    instance:<db-instance-id>
    cluster:<db-cluster-id>
    instance-backup:<db-instance-automated-backups-arn>
    cluster-backup:<db-cluster-resource-id>
    instance-snapshot:<db-snapshot-id>
    cluster-snapshot:<db-cluster-snapshot-id>

Defaults:
  - Interactive when /dev/tty is present
  - Non-interactive when /dev/tty is not present
  - Providing --yes forces non-interactive (no prompts)
  - Latest restore uses the latest restorable time in the target region/source selected

Restore target options:
  --latest
      Restore to latest available state (PITR latest).

  --restore-time <time>
      Restore to a specific time. Accepts ISO8601 UTC
      (e.g. 2026-01-20T10:30:00Z) or relative time:
      -<N>[s|m|h|d] (e.g. -5m, -2h, -1d)

  --snapshot-id <id>
      Restore from a specific snapshot identifier.

--no-wait behavior:
  - RDS instance: runs ONLY the restore call, then exits.
  - Aurora cluster: runs ONLY the cluster restore call, then exits
    (does NOT create writer yet).

Examples:
  Interactive guided restore:
    ./rds-restore.sh

  DR-region interactive restore from replicated backups:
    ./rds-restore.sh --region eu-west-1

  Dry-run:
    ./rds-restore.sh --dry-run

  Non-interactive restore to latest:
    ./rds-restore.sh --yes --source db01 --target db01-restore --latest

  Non-interactive restore to 2 hours ago:
    ./rds-restore.sh --yes --source db01 --target db01-restore --restore-time -2h

  Non-interactive restore from snapshot:
    ./rds-restore.sh --yes --source db01 --target db01-restore --snapshot-id rds:db01-2026-01-20-03-15
EOF_USAGE
}

# -------------------- UI helpers --------------------
confirm() {
  local msg="$1"
  local yes_flag="${2:-0}"
  if [[ "$yes_flag" == "1" ]]; then return 0; fi
  has_tty || die "No /dev/tty available. Use --yes for non-interactive mode."
  local ans
  read -r -p "$msg [y/N] " ans </dev/tty
  [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" || "$ans" == "YES" ]]
}

# Returns selected tag on stdout. Returns 1 on Cancel.
choose_one() {
  local title="$1"
  local prompt="$2"
  shift 2

  [[ "$INTERACTIVE" == "1" ]] || { echo "choose_one in non-interactive mode" >&2; return 2; }
  has_tty || { echo "No /dev/tty" >&2; return 2; }
  need whiptail
  export TERM="${TERM:-xterm-256color}"

  local choice
  choice=$(
    # shellcheck disable=SC2046
    whiptail --title "$title" \
      --menu "$prompt" \
      $(calc_whiptail_size) \
      "$@" \
      3>&1 1>&2 2>&3 </dev/tty
  ) || return 1

  echo "$choice"
}

choose_text() {
  local title="$1"
  local prompt="$2"
  local def="${3:-}"

  [[ "$INTERACTIVE" == "1" ]] || { echo "choose_text in non-interactive mode" >&2; return 2; }
  has_tty || { echo "No /dev/tty" >&2; return 2; }
  need whiptail
  export TERM="${TERM:-xterm-256color}"

  local h w
  read -r h w < <(calc_whiptail_hw)

  local text
  text=$(
    whiptail --title "$title" \
      --inputbox "$prompt" \
      "$h" "$w" \
      -- "$def" \
      3>&1 1>&2 2>&3 </dev/tty
  ) || return 1

  echo "$text"
}

choose_text_keep_default_if_empty() {
  local title="$1"
  local prompt="$2"
  local def="${3:-}"
  local out

  out=$(choose_text "$title" "$prompt" "$def") || return $?
  if [[ -z "$out" ]]; then
    echo "$def"
  else
    echo "$out"
  fi
}

# -------------------- Time helpers --------------------
epoch_now() { date -u +%s; }
epoch_to_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

resolve_restore_time_spec_to_iso() {
  local spec="$1"
  [[ -n "$spec" ]] || { echo ""; return 0; }

  if [[ "$spec" =~ ^-([0-9]+)([smhd])$ ]]; then
    local n="${BASH_REMATCH[1]}"
    local u="${BASH_REMATCH[2]}"
    local mult=1

    case "$u" in
      s) mult=1 ;;
      m) mult=60 ;;
      h) mult=3600 ;;
      d) mult=86400 ;;
      *) mult=1 ;;
    esac

    local now sec tgt
    now=$(epoch_now)
    sec=$(( n * mult ))
    tgt=$(( now - sec ))
    epoch_to_iso "$tgt"
    return 0
  fi

  echo "$spec"
}

time_display() {
  local v="${1:-}"
  if [[ -z "$v" || "$v" == "null" ]]; then
    echo "n/a"
  else
    echo "$v"
  fi
}

# -------------------- AWS helpers --------------------
aws_json_in_region() {
  local region="$1"
  shift

  local cmd=(aws)
  [[ -n "$region" ]] && cmd+=(--region "$region")
  cmd+=("$@")
  "${cmd[@]}"
}

aws_json() {
  aws_json_in_region "$REGION" "$@"
}

effective_region() {
  if [[ -n "$REGION" ]]; then
    echo "$REGION"
    return 0
  fi
  if [[ -n "${AWS_REGION:-}" ]]; then
    echo "$AWS_REGION"
    return 0
  fi
  if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    echo "$AWS_DEFAULT_REGION"
    return 0
  fi
  aws configure get region 2>/dev/null || true
}

region_label() {
  local region="$1"

  if [[ -n "$region" ]]; then
    echo "$region"
    return 0
  fi

  local eff
  eff=$(effective_region)
  if [[ -n "$eff" ]]; then
    echo "$eff"
  else
    echo "current AWS CLI region"
  fi
}

target_region_label() {
  region_label "$REGION"
}

arn_region() {
  local arn="$1"
  [[ "$arn" == arn:* ]] || { echo ""; return 0; }
  echo "$arn" | cut -d: -f4
}

source_metadata_region() {
  if [[ -n "$SOURCE_METADATA_REGION" ]]; then
    echo "$SOURCE_METADATA_REGION"
  else
    effective_region
  fi
}

instance_exists() {
  local id="$1"
  local region="${2:-$REGION}"
  aws_json_in_region "$region" rds describe-db-instances --db-instance-identifier "$id" >/dev/null 2>&1
}

cluster_exists() {
  local id="$1"
  local region="${2:-$REGION}"
  aws_json_in_region "$region" rds describe-db-clusters --db-cluster-identifier "$id" >/dev/null 2>&1
}

get_instance_full() {
  local id="$1"
  local region="${2:-$REGION}"
  aws_json_in_region "$region" rds describe-db-instances --db-instance-identifier "$id" | jq -r '.DBInstances[0]'
}

get_cluster_full() {
  local id="$1"
  local region="${2:-$REGION}"
  aws_json_in_region "$region" rds describe-db-clusters --db-cluster-identifier "$id" | jq -r '.DBClusters[0]'
}

split_to_array() {
  local csv="$1"
  local -n out_arr="$2"
  local tmp=()
  local item

  out_arr=()
  IFS=',' read -r -a tmp <<<"$csv"

  for item in "${tmp[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] && out_arr+=("$item")
  done
}

# -------------------- Automated backups and snapshots --------------------
get_instance_automated_backup_full() {
  local key="$1"
  local json

  if [[ "$key" == arn:* ]]; then
    json=$(aws_json rds describe-db-instance-automated-backups --db-instance-automated-backups-arn "$key")
  else
    json=$(aws_json rds describe-db-instance-automated-backups --db-instance-identifier "$key")
  fi

  echo "$json" | jq -r '.DBInstanceAutomatedBackups | sort_by(.RestoreWindow.LatestTime // "") | last // empty'
}

get_cluster_automated_backup_full() {
  local key="$1"
  local by_resource_id="${2:-0}"
  local json

  if [[ "$by_resource_id" == "1" ]]; then
    json=$(aws_json rds describe-db-cluster-automated-backups --db-cluster-resource-id "$key")
  else
    json=$(aws_json rds describe-db-cluster-automated-backups --db-cluster-identifier "$key")
  fi

  echo "$json" | jq -r '.DBClusterAutomatedBackups | sort_by(.RestoreWindow.LatestTime // "") | last // empty'
}

get_instance_snapshot_full() {
  local id="$1"
  aws_json rds describe-db-snapshots --db-snapshot-identifier "$id" | jq -r '.DBSnapshots[0] // empty'
}

get_cluster_snapshot_full() {
  local id="$1"
  aws_json rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "$id" | jq -r '.DBClusterSnapshots[0] // empty'
}

set_instance_automated_backup_source() {
  local backup_json="$1"
  local source_arg="${2:-}"

  SOURCE=$(echo "$backup_json" | jq -r '.DBInstanceIdentifier // empty')
  SOURCE_ARG="${source_arg:-instance-backup:$(echo "$backup_json" | jq -r '.DBInstanceAutomatedBackupsArn // empty')}"
  SOURCE_KIND="instance-backup"
  SOURCE_AUTOMATED_BACKUP_ARN=$(echo "$backup_json" | jq -r '.DBInstanceAutomatedBackupsArn // empty')
  SOURCE_METADATA_REGION=$(arn_region "$(echo "$backup_json" | jq -r '.DBInstanceArn // empty')")
  [[ -n "$SOURCE_METADATA_REGION" ]] || SOURCE_METADATA_REGION=$(echo "$backup_json" | jq -r '.Region // empty')
  SOURCE_BACKUP_EARLIEST=$(echo "$backup_json" | jq -r '.RestoreWindow.EarliestTime // empty')
  SOURCE_BACKUP_LATEST=$(echo "$backup_json" | jq -r '.RestoreWindow.LatestTime // empty')
  SOURCE_BACKUP_RETENTION=$(echo "$backup_json" | jq -r '.BackupRetentionPeriod // empty')
  SOURCE_ENGINE=$(echo "$backup_json" | jq -r '.Engine // empty')

  [[ -n "$SOURCE" ]] || die "Selected automated backup does not include a DB instance identifier."
  [[ -n "$SOURCE_AUTOMATED_BACKUP_ARN" ]] || die "Automated backup for '$SOURCE' does not include a DB instance automated backups ARN. Choose the live DB in this region, choose a snapshot, or verify backup replication."
  [[ -n "$SOURCE_METADATA_REGION" ]] || die "Could not determine the original source region for '$SOURCE'. The script needs it to read subnet/parameter/security-group defaults."
}

set_cluster_automated_backup_source() {
  local backup_json="$1"
  local source_arg="${2:-}"

  SOURCE=$(echo "$backup_json" | jq -r '.DBClusterIdentifier // empty')
  SOURCE_ARG="${source_arg:-cluster-backup:$(echo "$backup_json" | jq -r '.DbClusterResourceId // empty')}"
  SOURCE_KIND="cluster-backup"
  SOURCE_CLUSTER_RESOURCE_ID=$(echo "$backup_json" | jq -r '.DbClusterResourceId // empty')
  SOURCE_METADATA_REGION=$(arn_region "$(echo "$backup_json" | jq -r '.DBClusterArn // empty')")
  [[ -n "$SOURCE_METADATA_REGION" ]] || SOURCE_METADATA_REGION=$(echo "$backup_json" | jq -r '.Region // empty')
  SOURCE_BACKUP_EARLIEST=$(echo "$backup_json" | jq -r '.RestoreWindow.EarliestTime // empty')
  SOURCE_BACKUP_LATEST=$(echo "$backup_json" | jq -r '.RestoreWindow.LatestTime // empty')
  SOURCE_BACKUP_RETENTION=$(echo "$backup_json" | jq -r '.BackupRetentionPeriod // empty')
  SOURCE_ENGINE=$(echo "$backup_json" | jq -r '.Engine // empty')

  [[ -n "$SOURCE" ]] || die "Selected automated backup does not include a DB cluster identifier."
  [[ -n "$SOURCE_CLUSTER_RESOURCE_ID" ]] || die "Automated backup for '$SOURCE' does not include a source DB cluster resource ID."
  [[ -n "$SOURCE_METADATA_REGION" ]] || die "Could not determine the original source region for '$SOURCE'. The script needs it to read subnet/parameter/security-group defaults."
}

set_instance_snapshot_source() {
  local snapshot_json="$1"
  local source_arg="${2:-}"

  SOURCE=$(echo "$snapshot_json" | jq -r '.DBInstanceIdentifier // empty')
  SNAPSHOT_ID=$(echo "$snapshot_json" | jq -r '.DBSnapshotIdentifier // empty')
  SOURCE_ARG="${source_arg:-instance-snapshot:$SNAPSHOT_ID}"
  SOURCE_KIND="instance-snapshot"
  SOURCE_METADATA_REGION=$(echo "$snapshot_json" | jq -r '.SourceRegion // empty')
  [[ -n "$SOURCE_METADATA_REGION" ]] || SOURCE_METADATA_REGION=$(effective_region)
  SOURCE_ENGINE=$(echo "$snapshot_json" | jq -r '.Engine // empty')
  SOURCE_SNAPSHOT_TIME=$(echo "$snapshot_json" | jq -r '.SnapshotCreateTime // empty')

  [[ -n "$SOURCE" ]] || die "Selected DB snapshot does not include a DB instance identifier."
  [[ -n "$SNAPSHOT_ID" ]] || die "Selected DB snapshot does not include a snapshot identifier."
}

set_cluster_snapshot_source() {
  local snapshot_json="$1"
  local source_arg="${2:-}"

  SOURCE=$(echo "$snapshot_json" | jq -r '.DBClusterIdentifier // empty')
  SNAPSHOT_ID=$(echo "$snapshot_json" | jq -r '.DBClusterSnapshotIdentifier // empty')
  SOURCE_ARG="${source_arg:-cluster-snapshot:$SNAPSHOT_ID}"
  SOURCE_KIND="cluster-snapshot"
  SOURCE_METADATA_REGION=$(echo "$snapshot_json" | jq -r '.SourceRegion // empty')
  [[ -n "$SOURCE_METADATA_REGION" ]] || SOURCE_METADATA_REGION=$(effective_region)
  SOURCE_ENGINE=$(echo "$snapshot_json" | jq -r '.Engine // empty')
  SOURCE_SNAPSHOT_TIME=$(echo "$snapshot_json" | jq -r '.SnapshotCreateTime // empty')

  [[ -n "$SOURCE" ]] || die "Selected DB cluster snapshot does not include a DB cluster identifier."
  [[ -n "$SNAPSHOT_ID" ]] || die "Selected DB cluster snapshot does not include a snapshot identifier."
}

reset_source_metadata() {
  SOURCE_AUTOMATED_BACKUP_ARN=""
  SOURCE_CLUSTER_RESOURCE_ID=""
  SOURCE_METADATA_REGION=""
  SOURCE_BACKUP_EARLIEST=""
  SOURCE_BACKUP_LATEST=""
  SOURCE_BACKUP_RETENTION=""
  SOURCE_ENGINE=""
  SOURCE_SNAPSHOT_TIME=""
  SOURCE_KIND=""
}

# -------------------- Target resource validation --------------------
add_validation_error() {
  VALIDATION_ERRORS+=("$*")
}

print_validation_errors_and_exit_if_any() {
  ((${#VALIDATION_ERRORS[@]})) || return 0

  echo "Validation failed. The command plan above was not executed."
  echo "Fix the following target-region resources and re-run:"
  echo

  local err
  for err in "${VALIDATION_ERRORS[@]}"; do
    echo "  - $err"
  done

  echo
  echo "Placeholders such as '<error>' or '<empty>' in the command plan show values the script could not resolve yet."
  exit 1
}

value_or_placeholder() {
  local value="${1:-}"
  local placeholder="${2:-<empty>}"

  if [[ -z "$value" || "$value" == "null" ]]; then
    echo "$placeholder"
  else
    echo "$value"
  fi
}

target_db_subnet_group_vpc_id_or_empty() {
  local name="$1"
  [[ -n "$name" && "$name" != "null" && "$name" != "<empty>" && "$name" != "<error>" ]] || return 1

  aws_json rds describe-db-subnet-groups --db-subnet-group-name "$name" 2>/dev/null \
    | jq -r '.DBSubnetGroups[0].VpcId // empty'
}

require_target_db_subnet_group() {
  local name="$1"
  [[ -n "$name" && "$name" != "null" ]] || die "DB subnet group is required. Create a same-named DB subnet group in $(target_region_label), or pass --db-subnet-group <name>."

  aws_json rds describe-db-subnet-groups --db-subnet-group-name "$name" >/dev/null 2>&1 || \
    die "DB subnet group '$name' does not exist in $(target_region_label). Create it in the target region/VPC, or pass --db-subnet-group <name>."
}

require_target_db_parameter_group() {
  local name="$1"
  [[ -n "$name" && "$name" != "null" ]] || return 0

  aws_json rds describe-db-parameter-groups --db-parameter-group-name "$name" >/dev/null 2>&1 || \
    die "DB parameter group '$name' does not exist in $(target_region_label). Create a same-named parameter group in the target region, or pass --db-parameter-group <name>."
}

require_target_db_cluster_parameter_group() {
  local name="$1"
  [[ -n "$name" && "$name" != "null" ]] || return 0

  aws_json rds describe-db-cluster-parameter-groups --db-cluster-parameter-group-name "$name" >/dev/null 2>&1 || \
    die "DB cluster parameter group '$name' does not exist in $(target_region_label). Create a same-named cluster parameter group in the target region, or pass --db-cluster-parameter-group <name>."
}

require_target_option_group() {
  local name="$1"
  [[ -n "$name" && "$name" != "null" ]] || return 0

  aws_json rds describe-option-groups --option-group-name "$name" >/dev/null 2>&1 || \
    die "Option group '$name' does not exist in $(target_region_label). Create a same-named option group in the target region, or pass --option-group <name>."
}

db_subnet_group_vpc_id() {
  local name="$1"
  local vpc_id

  require_target_db_subnet_group "$name"
  vpc_id=$(target_db_subnet_group_vpc_id_or_empty "$name")
  [[ -n "$vpc_id" ]] || die "Could not determine VPC for DB subnet group '$name' in $(target_region_label)."
  echo "$vpc_id"
}

validate_target_db_subnet_group() {
  local name="$1"

  if [[ -z "$name" || "$name" == "null" || "$name" == "<empty>" ]]; then
    add_validation_error "DB subnet group is required. Create a same-named DB subnet group in $(target_region_label), or pass --db-subnet-group <name>."
    return 1
  fi

  aws_json rds describe-db-subnet-groups --db-subnet-group-name "$name" >/dev/null 2>&1 || {
    add_validation_error "DB subnet group '$name' does not exist in $(target_region_label). Create it in the target region/VPC, or pass --db-subnet-group <name>."
    return 1
  }
}

validate_target_db_parameter_group() {
  local name="$1"
  [[ -n "$name" && "$name" != "null" && "$name" != "<empty>" && "$name" != "<error>" ]] || return 0

  aws_json rds describe-db-parameter-groups --db-parameter-group-name "$name" >/dev/null 2>&1 || {
    add_validation_error "DB parameter group '$name' does not exist in $(target_region_label). Create a same-named parameter group in the target region, or pass --db-parameter-group <name>."
    return 1
  }
}

validate_target_db_cluster_parameter_group() {
  local name="$1"
  [[ -n "$name" && "$name" != "null" && "$name" != "<empty>" && "$name" != "<error>" ]] || return 0

  aws_json rds describe-db-cluster-parameter-groups --db-cluster-parameter-group-name "$name" >/dev/null 2>&1 || {
    add_validation_error "DB cluster parameter group '$name' does not exist in $(target_region_label). Create a same-named cluster parameter group in the target region, or pass --db-cluster-parameter-group <name>."
    return 1
  }
}

validate_target_option_group() {
  local name="$1"
  [[ -n "$name" && "$name" != "null" && "$name" != "<empty>" && "$name" != "<error>" ]] || return 0

  aws_json rds describe-option-groups --option-group-name "$name" >/dev/null 2>&1 || {
    add_validation_error "Option group '$name' does not exist in $(target_region_label). Create a same-named option group in the target region, or pass --option-group <name>."
    return 1
  }
}

source_sg_name_for_id() {
  local source_region="$1"
  local sg_id="$2"
  aws_json_in_region "$source_region" ec2 describe-security-groups --group-ids "$sg_id" | jq -r '.SecurityGroups[0].GroupName // empty'
}

target_sg_id_for_name_or_error() {
  local name="$1"
  local vpc_id="$2"
  local ids=()

  mapfile -t ids < <(aws_json ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=$name" 2>/dev/null \
    | jq -r '.SecurityGroups[].GroupId')

  if ((${#ids[@]} == 0)); then
    echo "<error>"
    return 0
  fi
  if ((${#ids[@]} > 1)); then
    echo "<error>"
    return 0
  fi

  echo "${ids[0]}"
}

target_sg_id_for_name() {
  local name="$1"
  local vpc_id="$2"
  local id

  id=$(target_sg_id_for_name_or_error "$name" "$vpc_id")
  [[ "$id" != "<error>" ]] || die "Could not resolve target security group named '$name' in target VPC '$vpc_id' ($(target_region_label))."
  echo "$id"
}

map_sg_ids_to_target_by_name() {
  local source_region="$1"
  local subnet_group="$2"
  shift 2

  local source_region_name
  source_region_name=$(region_label "$source_region")

  local vpc_id
  vpc_id=$(db_subnet_group_vpc_id "$subnet_group")

  local source_sg_id source_sg_name target_sg_id
  local out=()

  for source_sg_id in "$@"; do
    [[ -n "$source_sg_id" && "$source_sg_id" != "null" ]] || continue

    if ! source_sg_name=$(source_sg_name_for_id "$source_region" "$source_sg_id"); then
      die "Could not read source security group '$source_sg_id' in $source_region_name. Pass --vpc-sg-ids with target-region SG IDs."
    fi
    [[ -n "$source_sg_name" ]] || die "Could not resolve source security group '$source_sg_id' to a name in $source_region_name. Pass --vpc-sg-ids with target-region SG IDs."

    target_sg_id=$(target_sg_id_for_name "$source_sg_name" "$vpc_id")
    out+=("$target_sg_id")
  done

  printf '%s\n' "${out[@]}"
}

map_sg_ids_to_target_by_name_for_plan() {
  local source_region="$1"
  local subnet_group="$2"
  shift 2

  local source_region_name
  source_region_name=$(region_label "$source_region")

  local vpc_id
  if ! vpc_id=$(target_db_subnet_group_vpc_id_or_empty "$subnet_group") || [[ -z "$vpc_id" ]]; then
    if [[ -z "$subnet_group" || "$subnet_group" == "null" ]]; then
      add_validation_error "Cannot map security groups because DB subnet group is empty. Pass --db-subnet-group <name>."
    else
      add_validation_error "Cannot map security groups because DB subnet group '$subnet_group' does not exist in $(target_region_label). Create it first, or pass --db-subnet-group <name>."
    fi
    echo "<error>"
    return 0
  fi

  local source_sg_id source_sg_name target_sg_id
  local out=()

  for source_sg_id in "$@"; do
    [[ -n "$source_sg_id" && "$source_sg_id" != "null" ]] || continue

    if ! source_sg_name=$(source_sg_name_for_id "$source_region" "$source_sg_id" 2>/dev/null); then
      add_validation_error "Could not read source security group '$source_sg_id' in $source_region_name. Pass --vpc-sg-ids with target-region SG IDs."
      out+=("<error>")
      continue
    fi
    if [[ -z "$source_sg_name" ]]; then
      add_validation_error "Could not resolve source security group '$source_sg_id' to a name in $source_region_name. Pass --vpc-sg-ids with target-region SG IDs."
      out+=("<error>")
      continue
    fi

    target_sg_id=$(target_sg_id_for_name_or_error "$source_sg_name" "$vpc_id")
    out+=("$target_sg_id")
  done

  printf '%s\n' "${out[@]}"
}

validate_sg_ids_in_target_subnet_vpc() {
  local subnet_group="$1"
  shift
  ((${#@} == 0)) && return 0

  local vpc_id
  if ! vpc_id=$(target_db_subnet_group_vpc_id_or_empty "$subnet_group") || [[ -z "$vpc_id" ]]; then
    # The DB subnet group validation reports this already. Avoid duplicating it here.
    return 1
  fi

  local sg_id sg_vpc_id
  for sg_id in "$@"; do
    [[ -n "$sg_id" && "$sg_id" != "null" ]] || continue

    if [[ "$sg_id" == "<error>" || "$sg_id" == "<empty>" ]]; then
      add_validation_error "Security group IDs could not be resolved. Create same-named security groups in the target VPC, or pass --vpc-sg-ids with target-region SG IDs."
      continue
    fi

    if ! sg_vpc_id=$(aws_json ec2 describe-security-groups --group-ids "$sg_id" 2>/dev/null | jq -r '.SecurityGroups[0].VpcId // empty'); then
      add_validation_error "Security group '$sg_id' does not exist in $(target_region_label). Pass --vpc-sg-ids with target-region SG IDs."
      continue
    fi

    if [[ "$sg_vpc_id" != "$vpc_id" ]]; then
      add_validation_error "Security group '$sg_id' is in VPC '$sg_vpc_id', but DB subnet group '$subnet_group' is in VPC '$vpc_id'. Pass SG IDs from the target VPC."
    fi
  done
}

# -------------------- Source detection/listing --------------------
detect_source_type() {
  local source_id="$1"
  local matches=0
  local inst_backup="" cluster_backup="" inst_snap="" cluster_snap=""

  reset_source_metadata
  SOURCE_ARG="$source_id"

  if [[ "$source_id" == instance:* ]]; then
    SOURCE="${source_id#instance:}"
    SOURCE_KIND="instance"
    source_type="instance"
    return 0
  fi

  if [[ "$source_id" == cluster:* ]]; then
    SOURCE="${source_id#cluster:}"
    SOURCE_KIND="cluster"
    source_type="cluster"
    return 0
  fi

  if [[ "$source_id" == instance-backup:* ]]; then
    local key="${source_id#instance-backup:}"
    inst_backup=$(get_instance_automated_backup_full "$key" 2>/dev/null || true)
    [[ -n "$inst_backup" && "$inst_backup" != "null" ]] || die "Could not find instance automated backup: $key"
    set_instance_automated_backup_source "$inst_backup" "$source_id"
    source_type="instance"
    return 0
  fi

  if [[ "$source_id" == cluster-backup:* ]]; then
    local key="${source_id#cluster-backup:}"
    cluster_backup=$(get_cluster_automated_backup_full "$key" 1 2>/dev/null || true)
    [[ -n "$cluster_backup" && "$cluster_backup" != "null" ]] || die "Could not find cluster automated backup: $key"
    set_cluster_automated_backup_source "$cluster_backup" "$source_id"
    source_type="cluster"
    return 0
  fi

  if [[ "$source_id" == instance-snapshot:* ]]; then
    local key="${source_id#instance-snapshot:}"
    inst_snap=$(get_instance_snapshot_full "$key" 2>/dev/null || true)
    [[ -n "$inst_snap" && "$inst_snap" != "null" ]] || die "Could not find DB snapshot: $key"
    set_instance_snapshot_source "$inst_snap" "$source_id"
    source_type="instance"
    return 0
  fi

  if [[ "$source_id" == cluster-snapshot:* ]]; then
    local key="${source_id#cluster-snapshot:}"
    cluster_snap=$(get_cluster_snapshot_full "$key" 2>/dev/null || true)
    [[ -n "$cluster_snap" && "$cluster_snap" != "null" ]] || die "Could not find DB cluster snapshot: $key"
    set_cluster_snapshot_source "$cluster_snap" "$source_id"
    source_type="cluster"
    return 0
  fi

  if [[ "$source_id" == arn:*:auto-backup:* ]]; then
    inst_backup=$(get_instance_automated_backup_full "$source_id" 2>/dev/null || true)
    [[ -n "$inst_backup" && "$inst_backup" != "null" ]] || die "Could not find instance automated backup ARN: $source_id"
    set_instance_automated_backup_source "$inst_backup" "instance-backup:$source_id"
    source_type="instance"
    return 0
  fi

  if instance_exists "$source_id"; then
    SOURCE="$source_id"
    SOURCE_KIND="instance"
    source_type="instance"
    return 0
  fi

  if cluster_exists "$source_id"; then
    SOURCE="$source_id"
    SOURCE_KIND="cluster"
    source_type="cluster"
    return 0
  fi

  inst_backup=$(get_instance_automated_backup_full "$source_id" 2>/dev/null || true)
  [[ -n "$inst_backup" && "$inst_backup" != "null" ]] && matches=$((matches + 1))

  cluster_backup=$(get_cluster_automated_backup_full "$source_id" 2>/dev/null || true)
  [[ -n "$cluster_backup" && "$cluster_backup" != "null" ]] && matches=$((matches + 1))

  if [[ -z "$SNAPSHOT_ID" ]]; then
    inst_snap=$(get_instance_snapshot_full "$source_id" 2>/dev/null || true)
    [[ -n "$inst_snap" && "$inst_snap" != "null" ]] && matches=$((matches + 1))

    cluster_snap=$(get_cluster_snapshot_full "$source_id" 2>/dev/null || true)
    [[ -n "$cluster_snap" && "$cluster_snap" != "null" ]] && matches=$((matches + 1))
  fi

  if (( matches == 1 )); then
    if [[ -n "$inst_backup" && "$inst_backup" != "null" ]]; then
      set_instance_automated_backup_source "$inst_backup"
      source_type="instance"
    elif [[ -n "$cluster_backup" && "$cluster_backup" != "null" ]]; then
      set_cluster_automated_backup_source "$cluster_backup"
      source_type="cluster"
    elif [[ -n "$inst_snap" && "$inst_snap" != "null" ]]; then
      set_instance_snapshot_source "$inst_snap"
      source_type="instance"
    else
      set_cluster_snapshot_source "$cluster_snap"
      source_type="cluster"
    fi
    return 0
  fi

  if (( matches > 1 )); then
    die "Source '$source_id' matches multiple backup/snapshot sources. Use the interactive menu or pass an explicit selector such as instance-backup:<arn>, cluster-backup:<resource-id>, instance-snapshot:<id>, or cluster-snapshot:<id>."
  fi

  die "Could not find DB instance, DB cluster, automated backup, or snapshot named: $source_id"
}

list_sources() {
  local target_region
  target_region=$(effective_region)

  local inst live_instance_ids_json
  live_instance_ids_json="[]"
  inst=$(aws_json rds describe-db-instances 2>/dev/null || true)
  if [[ -n "$inst" ]]; then
    live_instance_ids_json=$(echo "$inst" | jq -c '[.DBInstances[].DBInstanceIdentifier]')
    echo "$inst" | jq -r '.DBInstances[] | select((.Engine // "") | startswith("aurora") | not) | ["instance:" + .DBInstanceIdentifier, "live instance", .DBInstanceIdentifier, .Engine, .DBInstanceStatus] | @tsv'
  fi

  local cl live_cluster_ids_json
  live_cluster_ids_json="[]"
  cl=$(aws_json rds describe-db-clusters 2>/dev/null || true)
  if [[ -n "$cl" ]]; then
    live_cluster_ids_json=$(echo "$cl" | jq -c '[.DBClusters[].DBClusterIdentifier]')
    echo "$cl" | jq -r '.DBClusters[] | ["cluster:" + .DBClusterIdentifier, "live cluster", .DBClusterIdentifier, .Engine, .Status] | @tsv'
  fi

  local inst_backups
  inst_backups=$(aws_json rds describe-db-instance-automated-backups 2>/dev/null || true)
  if [[ -n "$inst_backups" ]]; then
    echo "$inst_backups" | jq -r --arg region "$target_region" --argjson live_ids "$live_instance_ids_json" '.DBInstanceAutomatedBackups[]
      | select((.DBInstanceAutomatedBackupsArn // "") != "")
      | select($region == "" or ((.DBInstanceAutomatedBackupsArn | split(":")[3]) == $region))
      | select((.DBInstanceIdentifier // "") as $id | ($live_ids | index($id) | not))
      | ["instance-backup:" + .DBInstanceAutomatedBackupsArn, "instance backup", .DBInstanceIdentifier, .Engine, ((.RestoreWindow.LatestTime // "no latest") + " " + (.Status // ""))] | @tsv'
  fi

  local cluster_backups
  cluster_backups=$(aws_json rds describe-db-cluster-automated-backups 2>/dev/null || true)
  if [[ -n "$cluster_backups" ]]; then
    echo "$cluster_backups" | jq -r --argjson live_ids "$live_cluster_ids_json" '.DBClusterAutomatedBackups[]
      | select((.DbClusterResourceId // "") != "")
      | select((.DBClusterIdentifier // "") as $id | ($live_ids | index($id) | not))
      | ["cluster-backup:" + .DbClusterResourceId, "cluster backup", .DBClusterIdentifier, .Engine, ((.RestoreWindow.LatestTime // "no latest") + " " + (.Status // ""))] | @tsv'
  fi

  local inst_snaps
  inst_snaps=$(aws_json rds describe-db-snapshots --snapshot-type manual 2>/dev/null || true)
  if [[ -n "$inst_snaps" ]]; then
    echo "$inst_snaps" | jq -r '.DBSnapshots
      | sort_by(.SnapshotCreateTime // "") | reverse
      | .[]
      | ["instance-snapshot:" + .DBSnapshotIdentifier, "instance snapshot", (.DBInstanceIdentifier // "unknown"), .Engine, ((.SnapshotCreateTime // "no time") + " " + (.Status // ""))] | @tsv'
  fi

  local cluster_snaps
  cluster_snaps=$(aws_json rds describe-db-cluster-snapshots --snapshot-type manual 2>/dev/null || true)
  if [[ -n "$cluster_snaps" ]]; then
    echo "$cluster_snaps" | jq -r '.DBClusterSnapshots
      | sort_by(.SnapshotCreateTime // "") | reverse
      | .[]
      | ["cluster-snapshot:" + .DBClusterSnapshotIdentifier, "cluster snapshot", (.DBClusterIdentifier // "unknown"), .Engine, ((.SnapshotCreateTime // "no time") + " " + (.Status // ""))] | @tsv'
  fi
}

ensure_target_available_or_prompt() {
  local t="$1"
  local varname="$2"
  local cur="${!varname}"

  while :; do
    if [[ "$t" == "instance" ]]; then
      if instance_exists "$cur"; then
        if [[ "$INTERACTIVE" == "1" ]]; then
          echo "Target DB instance identifier already exists: $cur"
          if ! cur=$(choose_text_keep_default_if_empty "Target identifier" "Enter a NEW target instance identifier:" "${cur}-new"); then
            cancelled
          fi
          continue
        else
          die "Target DB instance identifier already exists: $cur"
        fi
      fi
    else
      if cluster_exists "$cur"; then
        if [[ "$INTERACTIVE" == "1" ]]; then
          echo "Target DB cluster identifier already exists: $cur"
          if ! cur=$(choose_text_keep_default_if_empty "Target identifier" "Enter a NEW target cluster identifier:" "${cur}-new"); then
            cancelled
          fi
          continue
        else
          die "Target DB cluster identifier already exists: $cur"
        fi
      fi
    fi
    break
  done

  # shellcheck disable=SC2163
  eval "$varname=\"\$cur\""
}

# -------------------- Snapshots listing/choosing --------------------
list_instance_snapshot_items() {
  local id="$1"
  aws_json rds describe-db-snapshots --db-instance-identifier "$id" \
    | jq -r '.DBSnapshots | sort_by(.SnapshotCreateTime) | reverse | map("\(.DBSnapshotIdentifier)\t\(.SnapshotCreateTime)\t\(.SnapshotType)") | .[]'
}

list_cluster_snapshot_items() {
  local id="$1"
  aws_json rds describe-db-cluster-snapshots --db-cluster-identifier "$id" \
    | jq -r '.DBClusterSnapshots | sort_by(.SnapshotCreateTime) | reverse | map("\(.DBClusterSnapshotIdentifier)\t\(.SnapshotCreateTime)\t\(.SnapshotType)") | .[]'
}

choose_snapshot_id() {
  local stype="$1"
  local sid="$2"
  local rows=()

  if [[ "$stype" == "instance" ]]; then
    mapfile -t rows < <(list_instance_snapshot_items "$sid")
  else
    mapfile -t rows < <(list_cluster_snapshot_items "$sid")
  fi

  ((${#rows[@]})) || die "No snapshots found for $sid"

  local items=()
  local snap_id snap_time snap_type
  for r in "${rows[@]}"; do
    IFS=$'\t' read -r snap_id snap_time snap_type <<<"$r"
    items+=("$snap_id" "$snap_time $snap_type")
  done

  local out
  if ! out=$(choose_one "Snapshots" "Choose a snapshot:" "${items[@]}"); then
    cancelled
  fi

  SNAPSHOT_ID="$out"
  echo "$SNAPSHOT_ID"
}

# -------------------- Defaults from source --------------------
instance_defaults_json() {
  local source_id="$1"
  local region="${2:-$REGION}"
  get_instance_full "$source_id" "$region" | jq -r '{
    Engine, EngineVersion,
    DBInstanceClass,
    DBSubnetGroupName: .DBSubnetGroup.DBSubnetGroupName,
    VpcSecurityGroupIds: (.VpcSecurityGroups | map(.VpcSecurityGroupId)),
    PubliclyAccessible,
    MultiAZ,
    DBParameterGroupName: (.DBParameterGroups[0].DBParameterGroupName // ""),
    OptionGroupName: (.OptionGroupMemberships[0].OptionGroupName // ""),
    EarliestRestorableTime: (.EarliestRestorableTime // null),
    LatestRestorableTime: (.LatestRestorableTime // null),
    BackupRetentionPeriod: (.BackupRetentionPeriod // null)
  }'
}

cluster_defaults_json() {
  local source_id="$1"
  local region="${2:-$REGION}"
  get_cluster_full "$source_id" "$region" | jq -r '{
    Engine, EngineVersion,
    DBSubnetGroupName: (.DBSubnetGroup // ""),
    VpcSecurityGroupIds: (.VpcSecurityGroups | map(.VpcSecurityGroupId)),
    DBClusterParameterGroupName: (.DBClusterParameterGroup // ""),
    OptionGroupName: (.OptionGroupMemberships[0].OptionGroupName // ""),
    EarliestRestorableTime: (.EarliestRestorableTime // null),
    LatestRestorableTime: (.LatestRestorableTime // null),
    BackupRetentionPeriod: (.BackupRetentionPeriod // null)
  }'
}

# -------------------- Pretty-print commands --------------------
shell_quote() {
  local s="$1"

  if [[ -z "$s" ]]; then
    printf "''"
  elif [[ "$s" =~ ^[A-Za-z0-9_./:=@%+,~-]+$ ]]; then
    printf '%s' "$s"
  else
    s=${s//\'/\'\\\'\'}
    printf "'%s'" "$s"
  fi
}

print_shell_cmd() {
  local q
  local first=1

  for q in "$@"; do
    if [[ "$first" == "1" ]]; then
      first=0
    else
      printf ' '
    fi
    shell_quote "$q"
  done
  echo
}

print_cmd_line() {
  local -a args=("$@")
  local i

  for ((i=0; i<${#args[@]}; i++)); do
    (( i > 0 )) && printf ' '
    shell_quote "${args[$i]}"
  done
}

print_cmd() {
  local prefix="$1"
  shift

  local -a parts=("$@")
  ((${#parts[@]})) || return 0

  local first_indent continuation_indent
  if [[ -n "$prefix" ]]; then
    first_indent="$prefix "
    continuation_indent=$(printf '%*s' "${#first_indent}" '')
  else
    first_indent=""
    continuation_indent="  "
  fi

  local base_end=0
  while (( base_end < ${#parts[@]} )) && [[ "${parts[$base_end]}" != --* ]]; do
    base_end=$((base_end + 1))
  done
  (( base_end == 0 )) && base_end=1

  printf '%s' "$first_indent"
  print_cmd_line "${parts[@]:0:base_end}"

  if (( base_end < ${#parts[@]} )); then
    printf ' \\\n'
  else
    printf '\n'
    return 0
  fi

  local i=$base_end
  local -a group=()

  while (( i < ${#parts[@]} )); do
    group=("${parts[$i]}")
    i=$((i + 1))

    while (( i < ${#parts[@]} )) && [[ "${parts[$i]}" != --* ]]; do
      group+=("${parts[$i]}")
      i=$((i + 1))
    done

    printf '%s' "$continuation_indent"
    print_cmd_line "${group[@]}"

    if (( i < ${#parts[@]} )); then
      printf ' \\\n'
    else
      printf '\n'
    fi
  done
}

build_rerun_cmd() {
  local mode="${1:-minimal}"
  local -a rerun=(./rds-restore.sh --yes)

  [[ -n "$REGION" ]] && rerun+=(--region "$REGION")
  [[ "$NO_WAIT" == "1" ]] && rerun+=(--no-wait)
  rerun+=(--source "${SOURCE_ARG:-$SOURCE}" --target "$TARGET")

  if [[ -n "$SNAPSHOT_ID" ]]; then
    if [[ "$SOURCE_KIND" == "instance-snapshot" || "$SOURCE_KIND" == "cluster-snapshot" ]]; then
      :
    else
      rerun+=(--snapshot-id "$SNAPSHOT_ID")
    fi
  elif [[ -n "$RESTORE_TIME_SPEC" ]]; then
    rerun+=(--restore-time "$RESTORE_TIME_SPEC")
  else
    rerun+=(--latest)
  fi

  if [[ "$source_type" == "cluster" ]]; then
    [[ -n "$AURORA_WRITER_INSTANCE" ]] && rerun+=(--aurora-writer-instance "$AURORA_WRITER_INSTANCE")
  fi

  if [[ "$mode" == "full" ]]; then
    if [[ "$source_type" == "instance" ]]; then
      [[ -n "${cls:-}" ]] && rerun+=(--db-instance-class "$cls")
      [[ -n "${subnet:-}" ]] && rerun+=(--db-subnet-group "$subnet")
      if ((${#sgs[@]})); then
        local sgs_csv
        sgs_csv=$(IFS=','; echo "${sgs[*]}")
        rerun+=(--vpc-sg-ids "$sgs_csv")
      fi
      [[ -n "${pub:-}" ]] && rerun+=(--publicly-accessible "$pub")
      [[ -n "${multi:-}" ]] && rerun+=(--multi-az "$multi")
      [[ -n "${pgroup:-}" && "${pgroup:-}" != "null" ]] && rerun+=(--db-parameter-group "$pgroup")
      [[ -n "${ogroup:-}" && "${ogroup:-}" != "null" ]] && rerun+=(--option-group "$ogroup")
    else
      [[ -n "${inst_class:-}" ]] && rerun+=(--db-instance-class "$inst_class")
      [[ -n "${subnet:-}" ]] && rerun+=(--db-subnet-group "$subnet")
      if ((${#sgs[@]})); then
        local sgs_csv
        sgs_csv=$(IFS=','; echo "${sgs[*]}")
        rerun+=(--vpc-sg-ids "$sgs_csv")
      fi
      [[ -n "${cpg:-}" && "${cpg:-}" != "null" ]] && rerun+=(--db-cluster-parameter-group "$cpg")
      [[ -n "${ogroup:-}" && "${ogroup:-}" != "null" ]] && rerun+=(--option-group "$ogroup")
    fi
  fi

  printf '%s\n' "${rerun[@]}"
}

# -------------------- Arg parsing --------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --interactive)
      INTERACTIVE=1
      ;;
    --yes|-y)
      YES=1
      INTERACTIVE=0
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --no-wait)
      NO_WAIT=1
      ;;
    --region)
      [[ $# -ge 2 ]] || die "--region requires a value"
      REGION="$2"
      shift
      ;;
    --region=*)
      REGION="${1#*=}"
      ;;
    --source)
      [[ $# -ge 2 ]] || die "--source requires a value"
      SOURCE_ARG="$2"
      SOURCE="$2"
      shift
      ;;
    --source=*)
      SOURCE_ARG="${1#*=}"
      SOURCE="$SOURCE_ARG"
      ;;
    --target)
      [[ $# -ge 2 ]] || die "--target requires a value"
      TARGET="$2"
      shift
      ;;
    --target=*)
      TARGET="${1#*=}"
      ;;
    --latest)
      LATEST=1
      RESTORE_TIME_SPEC=""
      RESTORE_TIME_ISO=""
      SNAPSHOT_ID=""
      ;;
    --restore-time)
      [[ $# -ge 2 ]] || die "--restore-time requires a value"
      LATEST=0
      RESTORE_TIME_SPEC="$2"
      RESTORE_TIME_ISO=""
      SNAPSHOT_ID=""
      shift
      ;;
    --restore-time=*)
      LATEST=0
      RESTORE_TIME_SPEC="${1#*=}"
      RESTORE_TIME_ISO=""
      SNAPSHOT_ID=""
      ;;
    --snapshot-id)
      [[ $# -ge 2 ]] || die "--snapshot-id requires a value"
      LATEST=0
      SNAPSHOT_ID="$2"
      RESTORE_TIME_SPEC=""
      RESTORE_TIME_ISO=""
      shift
      ;;
    --snapshot-id=*)
      LATEST=0
      SNAPSHOT_ID="${1#*=}"
      RESTORE_TIME_SPEC=""
      RESTORE_TIME_ISO=""
      ;;
    --aurora-writer-instance)
      [[ $# -ge 2 ]] || die "--aurora-writer-instance requires a value"
      AURORA_WRITER_INSTANCE="$2"
      shift
      ;;
    --aurora-writer-instance=*)
      AURORA_WRITER_INSTANCE="${1#*=}"
      ;;
    --db-instance-class)
      [[ $# -ge 2 ]] || die "--db-instance-class requires a value"
      DB_INSTANCE_CLASS="$2"
      shift
      ;;
    --db-instance-class=*)
      DB_INSTANCE_CLASS="${1#*=}"
      ;;
    --db-subnet-group|--db-subnet-group-name)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      DB_SUBNET_GROUP="$2"
      shift
      ;;
    --db-subnet-group=*|--db-subnet-group-name=*)
      DB_SUBNET_GROUP="${1#*=}"
      ;;
    --vpc-sg-ids|--vpc-security-group-ids)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      VPC_SG_IDS="$2"
      shift
      ;;
    --vpc-sg-ids=*|--vpc-security-group-ids=*)
      VPC_SG_IDS="${1#*=}"
      ;;
    --publicly-accessible)
      [[ $# -ge 2 ]] || die "--publicly-accessible requires true|false"
      PUBLICLY_ACCESSIBLE="$2"
      shift
      ;;
    --publicly-accessible=*)
      PUBLICLY_ACCESSIBLE="${1#*=}"
      ;;
    --multi-az)
      [[ $# -ge 2 ]] || die "--multi-az requires true|false"
      MULTI_AZ="$2"
      shift
      ;;
    --multi-az=*)
      MULTI_AZ="${1#*=}"
      ;;
    --db-parameter-group|--db-parameter-group-name)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      DB_PARAMETER_GROUP="$2"
      shift
      ;;
    --db-parameter-group=*|--db-parameter-group-name=*)
      DB_PARAMETER_GROUP="${1#*=}"
      ;;
    --db-cluster-parameter-group|--db-cluster-parameter-group-name)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      DB_CLUSTER_PARAMETER_GROUP="$2"
      shift
      ;;
    --db-cluster-parameter-group=*|--db-cluster-parameter-group-name=*)
      DB_CLUSTER_PARAMETER_GROUP="${1#*=}"
      ;;
    --option-group|--option-group-name)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      OPTION_GROUP="$2"
      shift
      ;;
    --option-group=*|--option-group-name=*)
      OPTION_GROUP="${1#*=}"
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

# Basic flag validation
if [[ -n "$PUBLICLY_ACCESSIBLE" && "$PUBLICLY_ACCESSIBLE" != "true" && "$PUBLICLY_ACCESSIBLE" != "false" ]]; then
  die "--publicly-accessible must be true or false"
fi
if [[ -n "$MULTI_AZ" && "$MULTI_AZ" != "true" && "$MULTI_AZ" != "false" ]]; then
  die "--multi-az must be true or false"
fi

# Interactive: choose source if not provided
if [[ -z "$SOURCE_ARG" ]]; then
  [[ "$INTERACTIVE" == "1" ]] || die "--source is required in non-interactive mode."

  mapfile -t rows < <(list_sources)
  ((${#rows[@]})) || die "No RDS instances, clusters, automated backups, or manual snapshots found in $(target_region_label)."

  items=()
  declare -A source_key_map=()
  for r in "${rows[@]}"; do
    IFS=$'\t' read -r key t id engine status <<<"$r"

    display_key="$key"
    case "$key" in
      instance-backup:*) display_key="instance-backup:$id" ;;
      cluster-backup:*) display_key="cluster-backup:$id" ;;
    esac

    if [[ -n "${source_key_map[$display_key]+x}" ]]; then
      n=2
      base_display_key="$display_key"
      while [[ -n "${source_key_map[$display_key]+x}" ]]; do
        display_key="${base_display_key}:$n"
        n=$((n + 1))
      done
    fi

    source_key_map["$display_key"]="$key"
    items+=("$display_key" "$id - $t $engine $status")
  done

  if ! SOURCE_ARG=$(choose_one "Sources" "Choose a restore source in $(target_region_label):" "${items[@]}"); then
    cancelled
  fi

  SOURCE_ARG="${source_key_map[$SOURCE_ARG]}"
fi

detect_source_type "$SOURCE_ARG"

# Load bounds early (display normalization once)
if [[ -n "$SOURCE_BACKUP_EARLIEST$SOURCE_BACKUP_LATEST$SOURCE_BACKUP_RETENTION" ]]; then
  d_bounds=$(jq -n \
    --arg earliest "$SOURCE_BACKUP_EARLIEST" \
    --arg latest "$SOURCE_BACKUP_LATEST" \
    --arg retention "$SOURCE_BACKUP_RETENTION" \
    '{EarliestRestorableTime: (if $earliest == "" then null else $earliest end), LatestRestorableTime: (if $latest == "" then null else $latest end), BackupRetentionPeriod: (if $retention == "" then null else ($retention | tonumber?) end)}')
elif [[ -n "$SOURCE_SNAPSHOT_TIME" ]]; then
  d_bounds=$(jq -n --arg snap "$SOURCE_SNAPSHOT_TIME" '{EarliestRestorableTime: null, LatestRestorableTime: $snap, BackupRetentionPeriod: null}')
elif [[ "$source_type" == "instance" ]]; then
  d_bounds=$(instance_defaults_json "$SOURCE" "$(source_metadata_region)")
else
  d_bounds=$(cluster_defaults_json "$SOURCE" "$(source_metadata_region)")
fi

EARLIEST_RESTORABLE=$(echo "$d_bounds" | jq -r '.EarliestRestorableTime // empty')
LATEST_RESTORABLE=$(echo "$d_bounds" | jq -r '.LatestRestorableTime // empty')
RETENTION_DAYS=$(echo "$d_bounds" | jq -r '.BackupRetentionPeriod // empty')
EARLIEST_DISPLAY=$(time_display "$EARLIEST_RESTORABLE")
LATEST_DISPLAY=$(time_display "$LATEST_RESTORABLE")

# Interactive: choose restore intent BEFORE target naming; choose snapshot/time immediately.
# If a snapshot source was selected, the intent is already fixed to that snapshot.
if [[ "$INTERACTIVE" == "1" && -z "$SNAPSHOT_ID" && -z "$RESTORE_TIME_SPEC" ]]; then
  restore_items=(
    latest "Latest available state (default)"
    time "Specific point in time"
  )

  if [[ -z "$SOURCE_AUTOMATED_BACKUP_ARN$SOURCE_CLUSTER_RESOURCE_ID" ]]; then
    restore_items+=(snapshot "Specific snapshot")
  fi

  if ! choice=$(choose_one "Restore target" "Restore to:" "${restore_items[@]}"); then
    cancelled
  fi

  case "$choice" in
    latest)
      LATEST=1
      RESTORE_TIME_SPEC=""
      RESTORE_TIME_ISO=""
      ;;
    snapshot)
      LATEST=0
      SNAPSHOT_ID=$(choose_snapshot_id "$source_type" "$SOURCE")
      ;;
    time)
      LATEST=0
      prompt="Enter restore time (ISO8601 like 2026-01-20T10:30:00Z OR relative -<N>[s|m|h|d] like -5h). Earliest: ${EARLIEST_DISPLAY}. Latest: ${LATEST_DISPLAY}."
      if ! RESTORE_TIME_SPEC=$(choose_text "Restore time" "$prompt" ""); then
        cancelled
      fi
      [[ -n "$RESTORE_TIME_SPEC" ]] || die "Restore time required."
      RESTORE_TIME_ISO=$(resolve_restore_time_spec_to_iso "$RESTORE_TIME_SPEC")
      ;;
    *)
      die "Unexpected selection."
      ;;
  esac
fi

# Non-interactive: resolve relative restore time if provided
if [[ -n "$RESTORE_TIME_SPEC" && -z "$RESTORE_TIME_ISO" ]]; then
  RESTORE_TIME_ISO=$(resolve_restore_time_spec_to_iso "$RESTORE_TIME_SPEC")
fi

# Target naming
if [[ -z "$TARGET" ]]; then
  default_target="${SOURCE}-restore-$(date -u +%Y%m%d%H%M%S)"
  if [[ "$INTERACTIVE" == "1" ]]; then
    if ! TARGET=$(choose_text_keep_default_if_empty "Target identifier" "Target identifier:" "$default_target"); then
      cancelled
    fi
  else
    TARGET="$default_target"
  fi
fi

if [[ "$source_type" == "instance" ]]; then
  ensure_target_available_or_prompt "instance" TARGET
else
  ensure_target_available_or_prompt "cluster" TARGET
  if [[ -z "$AURORA_WRITER_INSTANCE" ]]; then
    default_writer="${TARGET}-writer"
    if [[ "$INTERACTIVE" == "1" ]]; then
      if ! AURORA_WRITER_INSTANCE=$(choose_text_keep_default_if_empty "Writer instance" "Writer DB instance identifier:" "$default_writer"); then
        cancelled
      fi
    else
      AURORA_WRITER_INSTANCE="$default_writer"
    fi
  fi
  ensure_target_available_or_prompt "instance" AURORA_WRITER_INSTANCE
fi

# Build aws prefix
aws_prefix=(aws)
[[ -n "$REGION" ]] && aws_prefix+=(--region "$REGION")

# Build restore command (+ prompt config in interactive mode)
if [[ "$source_type" == "instance" ]]; then
  source_region=$(source_metadata_region)

  if ! d=$(instance_defaults_json "$SOURCE" "$source_region" 2>/dev/null); then
    die "Could not load source DB instance '$SOURCE' in $(region_label "$source_region") to derive restore defaults. Automated backups and copied snapshots do not expose DB subnet group, parameter group, or security group names. Ensure the source DB exists in its original region, or add that metadata to the script before restoring."
  fi

  cls=$(echo "$d" | jq -r '.DBInstanceClass')
  subnet=$(echo "$d" | jq -r '.DBSubnetGroupName')
  pub=$(echo "$d" | jq -r '.PubliclyAccessible')
  multi=$(echo "$d" | jq -r '.MultiAZ')
  pgroup=$(echo "$d" | jq -r '.DBParameterGroupName')
  ogroup=$(echo "$d" | jq -r '.OptionGroupName')
  mapfile -t source_sgs < <(echo "$d" | jq -r '.VpcSecurityGroupIds[]')

  # Apply CLI overrides first.
  [[ -n "$DB_INSTANCE_CLASS" ]] && cls="$DB_INSTANCE_CLASS"
  [[ -n "$DB_SUBNET_GROUP" ]] && subnet="$DB_SUBNET_GROUP"
  [[ -n "$PUBLICLY_ACCESSIBLE" ]] && pub="$PUBLICLY_ACCESSIBLE"
  [[ -n "$MULTI_AZ" ]] && multi="$MULTI_AZ"
  [[ -n "$DB_PARAMETER_GROUP" ]] && pgroup="$DB_PARAMETER_GROUP"
  [[ -n "$OPTION_GROUP" ]] && ogroup="$OPTION_GROUP"

  # Prompt for logical config before validating same-name existence in the target region.
  if [[ "$INTERACTIVE" == "1" ]]; then
    if ! cls=$(choose_text_keep_default_if_empty "DB instance class" "DB instance class:" "$cls"); then cancelled; fi
    if ! subnet=$(choose_text_keep_default_if_empty "DB subnet group" "DB subnet group:" "$subnet"); then cancelled; fi
    if ! pub=$(choose_text_keep_default_if_empty "Public access" "Publicly accessible (true/false):" "$pub"); then cancelled; fi
    if ! multi=$(choose_text_keep_default_if_empty "Multi-AZ" "Multi-AZ (true/false):" "$multi"); then cancelled; fi
    if [[ -n "$pgroup" && "$pgroup" != "null" ]]; then
      if ! pgroup=$(choose_text_keep_default_if_empty "Parameter group" "DB parameter group:" "$pgroup"); then cancelled; fi
    fi
    if [[ -n "$ogroup" && "$ogroup" != "null" ]]; then
      if ! ogroup=$(choose_text_keep_default_if_empty "Option group" "Option group:" "$ogroup"); then cancelled; fi
    fi
  fi

  sgs=()
  if [[ -n "$VPC_SG_IDS" ]]; then
    split_to_array "$VPC_SG_IDS" sgs
  elif ((${#source_sgs[@]})); then
    mapfile -t sgs < <(map_sg_ids_to_target_by_name_for_plan "$source_region" "$subnet" "${source_sgs[@]}")
  fi

  if [[ "$INTERACTIVE" == "1" ]]; then
    sgs_def_csv=$(IFS=','; echo "${sgs[*]}")
    if ! sgs_in=$(choose_text_keep_default_if_empty "Security groups" "VPC security groups (comma-separated target-region SG IDs):" "$sgs_def_csv"); then cancelled; fi
    split_to_array "$sgs_in" sgs
  fi

  cmd_cls=$(value_or_placeholder "$cls")
  cmd_subnet=$(value_or_placeholder "$subnet")

  if [[ -n "$SNAPSHOT_ID" ]]; then
    cmd_restore=( "${aws_prefix[@]}" rds restore-db-instance-from-db-snapshot
      --db-instance-identifier "$TARGET"
      --db-snapshot-identifier "$SNAPSHOT_ID"
      --db-instance-class "$cmd_cls"
      --db-subnet-group-name "$cmd_subnet"
    )
  else
    cmd_restore=( "${aws_prefix[@]}" rds restore-db-instance-to-point-in-time )
    if [[ -n "$SOURCE_AUTOMATED_BACKUP_ARN" ]]; then
      cmd_restore+=(--source-db-instance-automated-backups-arn "$SOURCE_AUTOMATED_BACKUP_ARN")
    else
      cmd_restore+=(--source-db-instance-identifier "$SOURCE")
    fi
    cmd_restore+=(--target-db-instance-identifier "$TARGET" --db-instance-class "$cmd_cls" --db-subnet-group-name "$cmd_subnet")

    if [[ -n "$RESTORE_TIME_SPEC" ]]; then
      cmd_restore+=(--restore-time "${RESTORE_TIME_ISO:-$RESTORE_TIME_SPEC}")
    else
      cmd_restore+=(--use-latest-restorable-time)
    fi
  fi

  ((${#sgs[@]})) && cmd_restore+=(--vpc-security-group-ids "${sgs[@]}")
  [[ -n "$pgroup" && "$pgroup" != "null" ]] && cmd_restore+=(--db-parameter-group-name "$pgroup")
  [[ -n "$ogroup" && "$ogroup" != "null" ]] && cmd_restore+=(--option-group-name "$ogroup")
  [[ "$pub" == "true" ]] && cmd_restore+=(--publicly-accessible) || cmd_restore+=(--no-publicly-accessible)
  [[ "$multi" == "true" ]] && cmd_restore+=(--multi-az) || cmd_restore+=(--no-multi-az)

  cmd_wait=( "${aws_prefix[@]}" rds wait db-instance-available --db-instance-identifier "$TARGET" )
else
  source_region=$(source_metadata_region)

  if ! d=$(cluster_defaults_json "$SOURCE" "$source_region" 2>/dev/null); then
    die "Could not load source DB cluster '$SOURCE' in $(region_label "$source_region") to derive restore defaults. Automated backups and copied snapshots do not expose DB subnet group, cluster parameter group, or security group names. Ensure the source cluster exists in its original region, or add that metadata to the script before restoring."
  fi

  engine=$(echo "$d" | jq -r '.Engine')
  subnet=$(echo "$d" | jq -r '.DBSubnetGroupName')
  cpg=$(echo "$d" | jq -r '.DBClusterParameterGroupName')
  ogroup=$(echo "$d" | jq -r '.OptionGroupName')
  mapfile -t source_sgs < <(echo "$d" | jq -r '.VpcSecurityGroupIds[]')

  [[ -n "$DB_SUBNET_GROUP" ]] && subnet="$DB_SUBNET_GROUP"
  [[ -n "$DB_CLUSTER_PARAMETER_GROUP" ]] && cpg="$DB_CLUSTER_PARAMETER_GROUP"
  [[ -n "$OPTION_GROUP" ]] && ogroup="$OPTION_GROUP"

  inst_class="${DB_INSTANCE_CLASS:-db.r6g.large}"

  if [[ "$INTERACTIVE" == "1" ]]; then
    if ! subnet=$(choose_text_keep_default_if_empty "DB subnet group" "DB subnet group:" "$subnet"); then cancelled; fi
    if [[ -n "$cpg" && "$cpg" != "null" ]]; then
      if ! cpg=$(choose_text_keep_default_if_empty "Cluster parameter group" "DB cluster parameter group:" "$cpg"); then cancelled; fi
    fi
    if [[ -n "$ogroup" && "$ogroup" != "null" ]]; then
      if ! ogroup=$(choose_text_keep_default_if_empty "Option group" "Option group:" "$ogroup"); then cancelled; fi
    fi
    if ! inst_class=$(choose_text_keep_default_if_empty "Writer class" "Writer instance class:" "$inst_class"); then cancelled; fi
  fi

  sgs=()
  if [[ -n "$VPC_SG_IDS" ]]; then
    split_to_array "$VPC_SG_IDS" sgs
  elif ((${#source_sgs[@]})); then
    mapfile -t sgs < <(map_sg_ids_to_target_by_name_for_plan "$source_region" "$subnet" "${source_sgs[@]}")
  fi

  if [[ "$INTERACTIVE" == "1" ]]; then
    sgs_def_csv=$(IFS=','; echo "${sgs[*]}")
    if ! sgs_in=$(choose_text_keep_default_if_empty "Security groups" "VPC security groups (comma-separated target-region SG IDs):" "$sgs_def_csv"); then cancelled; fi
    split_to_array "$sgs_in" sgs
  fi

  cmd_subnet=$(value_or_placeholder "$subnet")
  cmd_engine=$(value_or_placeholder "$engine")
  cmd_inst_class=$(value_or_placeholder "$inst_class")

  if [[ -n "$SNAPSHOT_ID" ]]; then
    cmd_restore=( "${aws_prefix[@]}" rds restore-db-cluster-from-snapshot
      --db-cluster-identifier "$TARGET"
      --snapshot-identifier "$SNAPSHOT_ID"
      --engine "$cmd_engine"
    )
  else
    cmd_restore=( "${aws_prefix[@]}" rds restore-db-cluster-to-point-in-time )
    if [[ -n "$SOURCE_CLUSTER_RESOURCE_ID" ]]; then
      cmd_restore+=(--source-db-cluster-resource-id "$SOURCE_CLUSTER_RESOURCE_ID")
    else
      cmd_restore+=(--source-db-cluster-identifier "$SOURCE")
    fi
    cmd_restore+=(--db-cluster-identifier "$TARGET")

    if [[ -n "$RESTORE_TIME_SPEC" ]]; then
      cmd_restore+=(--restore-to-time "${RESTORE_TIME_ISO:-$RESTORE_TIME_SPEC}")
    else
      cmd_restore+=(--use-latest-restorable-time)
    fi
  fi

  cmd_restore+=(--db-subnet-group-name "$cmd_subnet")
  ((${#sgs[@]})) && cmd_restore+=(--vpc-security-group-ids "${sgs[@]}")
  [[ -n "$cpg" && "$cpg" != "null" ]] && cmd_restore+=(--db-cluster-parameter-group-name "$cpg")
  [[ -n "$ogroup" && "$ogroup" != "null" ]] && cmd_restore+=(--option-group-name "$ogroup")

  cmd_wait_cluster=( "${aws_prefix[@]}" rds wait db-cluster-available --db-cluster-identifier "$TARGET" )
  cmd_create_writer=( "${aws_prefix[@]}" rds create-db-instance
    --db-instance-identifier "$AURORA_WRITER_INSTANCE"
    --db-instance-class "$cmd_inst_class"
    --engine "$cmd_engine"
    --db-cluster-identifier "$TARGET"
  )
  cmd_wait_writer=( "${aws_prefix[@]}" rds wait db-instance-available --db-instance-identifier "$AURORA_WRITER_INSTANCE" )
fi

# Final plan + commands
echo
echo "================ EXECUTION PLAN ======================"
echo "Target region: $(target_region_label)"
echo "Source: $SOURCE"
[[ -n "$SOURCE_ARG" && "$SOURCE_ARG" != "$SOURCE" ]] && echo "Source selector: $SOURCE_ARG"
[[ -n "$SOURCE_KIND" ]] && echo "Source kind: $SOURCE_KIND"
echo "Source metadata region: $(region_label "$(source_metadata_region)")"
echo "Type: $source_type"
echo "Target: $TARGET"
[[ "$source_type" == "cluster" ]] && echo "Writer: $AURORA_WRITER_INSTANCE"
echo "Earliest: $EARLIEST_DISPLAY"
echo "Latest: $LATEST_DISPLAY"

if [[ -n "$SNAPSHOT_ID" ]]; then
  echo "Restore: snapshot -> $SNAPSHOT_ID"
elif [[ -n "$RESTORE_TIME_SPEC" ]]; then
  echo "Restore: time -> $RESTORE_TIME_SPEC (resolved: ${RESTORE_TIME_ISO:-same})"
else
  echo "Restore: latest available state"
fi

echo "------------------------------------------------------"
echo "Commands that will be executed:"
echo
print_cmd "1)" "${cmd_restore[@]}"
echo

if [[ "$NO_WAIT" == "1" ]]; then
  echo "2) (not executed due to --no-wait) wait commands"
  echo
else
  if [[ "$source_type" == "instance" ]]; then
    print_cmd "2)" "${cmd_wait[@]}"
    echo
  else
    print_cmd "2)" "${cmd_wait_cluster[@]}"
    echo
    print_cmd "3)" "${cmd_create_writer[@]}"
    echo
    print_cmd "4)" "${cmd_wait_writer[@]}"
    echo
  fi
fi

echo "======================================================"
echo
mapfile -t rerun_minimal < <(build_rerun_cmd minimal)
mapfile -t rerun_full < <(build_rerun_cmd full)

echo "# Re-run this exact restore non-interactively (with defaults):"
print_cmd "" "${rerun_minimal[@]}"
echo
echo "# Re-run this exact restore non-interactively (hardcoded arguments):"
print_cmd "" "${rerun_full[@]}"
echo
echo "# Single-line (copy/paste):"
print_shell_cmd "${rerun_minimal[@]}"
echo
echo "======================================================"
echo

VALIDATION_ERRORS=()
if [[ "$source_type" == "instance" ]]; then
  validate_target_db_subnet_group "$subnet" || true
  validate_target_db_parameter_group "$pgroup" || true
  validate_target_option_group "$ogroup" || true
  validate_sg_ids_in_target_subnet_vpc "$subnet" "${sgs[@]}" || true
else
  validate_target_db_subnet_group "$subnet" || true
  validate_target_db_cluster_parameter_group "$cpg" || true
  validate_target_option_group "$ogroup" || true
  validate_sg_ids_in_target_subnet_vpc "$subnet" "${sgs[@]}" || true
fi
print_validation_errors_and_exit_if_any

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry-run: no commands executed."
  exit 0
fi

confirm "Proceed and run the commands above?" "$YES" || die "Cancelled."
echo

# Execute
if [[ "$source_type" == "instance" ]]; then
  "${cmd_restore[@]}" >/dev/null
  echo "Restore started."

  if [[ "$NO_WAIT" == "1" ]]; then
    echo "Exiting due to --no-wait."
    exit 0
  fi

  echo "Waiting until available..."
  "${cmd_wait[@]}"

  aws_json rds describe-db-instances --db-instance-identifier "$TARGET" \
    | jq -r '.DBInstances[0] | "Endpoint: \(.Endpoint.Address):\(.Endpoint.Port)\nStatus: \(.DBInstanceStatus)\nEngine: \(.Engine) \(.EngineVersion)"'
else
  "${cmd_restore[@]}" >/dev/null
  echo "Cluster restore started."

  if [[ "$NO_WAIT" == "1" ]]; then
    echo "Exiting due to --no-wait."
    echo "When ready, run (in order):"
    echo "  ${cmd_wait_cluster[*]}"
    echo "  ${cmd_create_writer[*]}"
    echo "  ${cmd_wait_writer[*]}"
    exit 0
  fi

  echo "Waiting until cluster available..."
  "${cmd_wait_cluster[@]}"

  echo "Creating writer instance..."
  "${cmd_create_writer[@]}" >/dev/null

  echo "Waiting until writer instance available..."
  "${cmd_wait_writer[@]}"

  aws_json rds describe-db-clusters --db-cluster-identifier "$TARGET" \
    | jq -r '.DBClusters[0] | "Cluster endpoint: \(.Endpoint)\nReader endpoint: \(.ReaderEndpoint)\nStatus: \(.Status)\nEngine: \(.Engine) \(.EngineVersion)"'
fi
