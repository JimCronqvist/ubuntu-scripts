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
REGION=""               # from --region; if empty, aws cli uses env/config

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
RESTORE_TIME_SPEC=""    # user-supplied: ISO8601 or relative like -5m/-2h
RESTORE_TIME_ISO=""     # computed ISO8601 for AWS (empty => latest)
SNAPSHOT_ID=""

# Source/target
SOURCE=""
TARGET=""
AURORA_WRITER_INSTANCE=""
source_type=""

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
PUBLICLY_ACCESSIBLE=""  # true|false (instance only)
MULTI_AZ=""             # true|false (instance only)
DB_PARAMETER_GROUP=""
DB_CLUSTER_PARAMETER_GROUP=""
OPTION_GROUP=""

usage() {
  cat <<'EOF'
Usage:
  rds-restore.sh [--help] [--interactive] [--yes] [--dry-run] [--no-wait] [--region <region>]
                 [--source <id>] [--target <new-id>]
                 [--latest | --restore-time <ISO8601|relative> | --snapshot-id <snapshot-id>]
                 [--aurora-writer-instance <id>]
                 [--db-instance-class <class>]
                 [--db-subnet-group <name>]
                 [--vpc-sg-ids <sg-1,sg-2,...>]
                 [--publicly-accessible true|false]   (RDS instance only)
                 [--multi-az true|false]               (RDS instance only)
                 [--db-parameter-group <name>]         (RDS instance only)
                 [--db-cluster-parameter-group <name>] (Aurora cluster only)
                 [--option-group <name>]

Defaults:
  - Interactive when /dev/tty is present
  - Non-interactive when /dev/tty is not present
  - Providing --yes forces non-interactive (no prompts)

Restore target options:
  --latest
      Restore to latest available state (PITR latest).
  --restore-time <value>
      Restore to a specific time.
      Accepts ISO8601 UTC (e.g. 2026-01-20T10:30:00Z)
      or relative time: -<N>[s|m|h|d] (e.g. -5m, -2h, -1d)
  --snapshot-id <id>
      Restore from a specific snapshot identifier.

--no-wait behavior:
  - RDS instance: runs ONLY the restore call, then exits.
  - Aurora cluster: runs ONLY the cluster restore call, then exits (does NOT create writer yet).

Examples:
  Interactive guided restore:
    ./rds-restore.sh

  Dry-run (print plan + commands):
    ./rds-restore.sh --dry-run

  Non-interactive restore to latest:
    ./rds-restore.sh --yes --source db01 --target db01-restore --latest

  Non-interactive restore to 2 hours ago:
    ./rds-restore.sh --yes --source db01 --target db01-restore --restore-time -2h

  Non-interactive restore from snapshot:
    ./rds-restore.sh --yes --source db01 --target db01-restore --snapshot-id rds:db01-2026-01-20-03-15
EOF
}

# -------------------- UI helpers --------------------
confirm() {
  local msg="$1"
  local yes_flag="${2:-0}"
  if [[ "$yes_flag" == "1" ]]; then return 0; fi
  has_tty || die "No /dev/tty available. Use --yes for non-interactive mode."
  local ans
  read -r -p "$msg [y/N] " ans </dev/tty
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# choose_one TITLE PROMPT tag1 desc1 tag2 desc2 ...
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

  [[ -n "$choice" ]] || return 1
  printf "%s\n" "$choice"
  return 0
}

# choose_text TITLE PROMPT DEFAULT
# Returns typed text on stdout. Returns 1 on Cancel.
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

  printf "%s\n" "$text"
  return 0
}

# Like choose_text, but if user submits empty string, returns the provided default.
# Returns 1 on Cancel.
choose_text_keep_default_if_empty() {
  local title="$1"
  local prompt="$2"
  local def="${3:-}"

  local v
  if ! v=$(choose_text "$title" "$prompt" "$def"); then
    return 1
  fi

  if [[ -z "${v:-}" ]]; then
    printf "%s\n" "$def"
  else
    printf "%s\n" "$v"
  fi
  return 0
}

# -------------------- Time utilities --------------------
epoch_now() { date -u +%s; }

epoch_to_iso() {
  local e="$1"
  date -u -d "@$e" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true
}

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
    local now; now=$(epoch_now)
    local sec=$(( n * mult ))
    local tgt=$(( now - sec ))
    epoch_to_iso "$tgt"
    return 0
  fi

  echo "$spec"
}

# -------------------- AWS helpers --------------------
aws_json() {
  local cmd=(aws)
  [[ -n "$REGION" ]] && cmd+=(--region "$REGION")
  cmd+=("$@")
  "${cmd[@]}"
}

instance_exists() {
  local id="$1"
  aws_json rds describe-db-instances --db-instance-identifier "$id" >/dev/null 2>&1
}

cluster_exists() {
  local id="$1"
  aws_json rds describe-db-clusters --db-cluster-identifier "$id" >/dev/null 2>&1
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

detect_source_type() {
  local source_id="$1"
  if instance_exists "$source_id"; then echo "instance"; return 0; fi
  if cluster_exists "$source_id"; then echo "cluster"; return 0; fi
  die "Could not find DB instance or DB cluster named: $source_id"
}

list_sources() {
  local inst; inst=$(aws_json rds describe-db-instances)
  echo "$inst" | jq -r '.DBInstances[] | ["instance", .DBInstanceIdentifier, .Engine, .DBInstanceStatus] | @tsv'
  local cl; cl=$(aws_json rds describe-db-clusters)
  echo "$cl" | jq -r '.DBClusters[] | ["cluster", .DBClusterIdentifier, .Engine, .Status] | @tsv'
}

get_instance_full() {
  local id="$1"
  aws_json rds describe-db-instances --db-instance-identifier "$id" | jq -r '.DBInstances[0]'
}

get_cluster_full() {
  local id="$1"
  aws_json rds describe-db-clusters --db-cluster-identifier "$id" | jq -r '.DBClusters[0]'
}

split_to_array() {
  local csv="$1"
  local -n out_arr="$2"
  out_arr=()
  IFS=',' read -r -a out_arr <<<"$csv"
  for i in "${!out_arr[@]}"; do
    out_arr[$i]="${out_arr[$i]#"${out_arr[$i]%%[![:space:]]*}"}"
    out_arr[$i]="${out_arr[$i]%"${out_arr[$i]##*[![:space:]]}"}"
  done
}

# -------------------- Snapshots listing/choosing --------------------
list_instance_snapshot_items() {
  local id="$1"
  aws_json rds describe-db-snapshots --db-instance-identifier "$id" \
    | jq -r '.DBSnapshots | sort_by(.SnapshotCreateTime) | reverse
      | map("\(.DBSnapshotIdentifier)\t\(.SnapshotCreateTime)\t\(.SnapshotType)") | .[]'
}

list_cluster_snapshot_items() {
  local id="$1"
  aws_json rds describe-db-cluster-snapshots --db-cluster-identifier "$id" \
    | jq -r '.DBClusterSnapshots | sort_by(.SnapshotCreateTime) | reverse
      | map("\(.DBClusterSnapshotIdentifier)\t\(.SnapshotCreateTime)\t\(.SnapshotType)") | .[]'
}

choose_snapshot_id() {
  local stype="$1" sid="$2"

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
  get_instance_full "$source_id" | jq -r '{
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
  get_cluster_full "$source_id" | jq -r '{
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
print_cmd() {
  local prefix="$1"; shift
  local -a parts=("$@")
  ((${#parts[@]})) || return 0

  # Find "rds" and include "rds <subcommand>" + any positionals until first -- on the first line
  local rds_i=-1
  for ((i=0; i<${#parts[@]}; i++)); do
    if [[ "${parts[$i]}" == "rds" ]]; then
      rds_i=$i
      break
    fi
  done

  local base_end=0
  if (( rds_i >= 0 )); then
    base_end=$(( rds_i + 2 ))
    (( base_end > ${#parts[@]} )) && base_end=${#parts[@]}
    while (( base_end < ${#parts[@]} )) && [[ "${parts[$base_end]}" != --* ]]; do
      base_end=$((base_end + 1))
    done
  else
    for ((i=0; i<${#parts[@]}; i++)); do
      [[ "${parts[$i]}" == --* ]] && break
      base_end=$((i+1))
    done
  fi

  local -a lines=()

  local line="$prefix"
  for ((i=0; i<base_end; i++)); do
    line+=" ${parts[$i]}"
  done
  lines+=("$line")

  local i=$base_end
  while (( i < ${#parts[@]} )); do
    local tok="${parts[$i]}"
    if [[ "$tok" == --* ]]; then
      line="  $tok"
      ((i++))
      while (( i < ${#parts[@]} )) && [[ "${parts[$i]}" != --* ]]; do
        line+=" ${parts[$i]}"
        ((i++))
      done
      lines+=("$line")
    else
      lines+=("  ${parts[$i]}")
      ((i++))
    fi
  done

  local last=$(( ${#lines[@]} - 1 ))
  for ((j=0; j<${#lines[@]}; j++)); do
    if (( j < last )); then
      printf '%s \\\n' "${lines[$j]}"
    else
      printf '%s\n' "${lines[$j]}"
    fi
  done
  printf '\n'
  return 0
}

# string differs and value is meaningful
diff_str() {
  local a="$1" b="$2"
  [[ "$a" != "$b" && -n "$b" && "$b" != "null" ]]
}

# boolean differs (true/false)
diff_bool() {
  [[ "$1" != "$2" ]]
}

# array differs (order-sensitive, which is fine for SGs)
diff_array() {
  local -n a="$1" b="$2"
  [[ "${a[*]}" != "${b[*]}" ]]
}

# Shell-escape a command line so it can be copied/pasted safely
print_shell_cmd() {
  local -a cmd=("$@")
  local out=""
  for a in "${cmd[@]}"; do
    out+=" $(printf "%q" "$a")"
  done
  echo "${out:1}"
}

print_rerun_cmd_multiline() {
  local label="$1"; shift
  echo "$label"
  print_cmd "" "$@"
}

# Build and print a non-interactive re-run command that reproduces the current plan
build_rerun_cmd() {
  # Usage:
  #   print_rerun_cmd minimal   # only non-default args
  #   print_rerun_cmd full      # always include all args
  local mode="${1:-minimal}"

  local script="${0:-rds-restore.sh}"
  local -a rerun=("./$script" "--yes")

  [[ -n "$REGION" ]] && rerun+=(--region "$REGION")
  [[ "$NO_WAIT" == "1" ]] && rerun+=(--no-wait)

  rerun+=(--source "$SOURCE" --target "$TARGET")

  if [[ "$source_type" == "cluster" ]]; then
    rerun+=(--aurora-writer-instance "$AURORA_WRITER_INSTANCE")
  fi

  # Restore target
  if [[ -n "$SNAPSHOT_ID" ]]; then
    rerun+=(--snapshot-id "$SNAPSHOT_ID")
  elif [[ -n "$RESTORE_TIME_SPEC" ]]; then
    rerun+=(--restore-time "$RESTORE_TIME_SPEC")
  else
    rerun+=(--latest)
  fi

  # Helper: include arg based on mode
  include_str() {
    local def="$1" cur="$2"
    [[ "$mode" == "full" ]] || diff_str "$def" "$cur"
  }
  include_bool() {
    local def="$1" cur="$2"
    [[ "$mode" == "full" ]] || diff_bool "$def" "$cur"
  }
  include_array() {
    local -n def_arr="$1" cur_arr="$2"
    [[ "$mode" == "full" ]] || diff_array def_arr cur_arr
  }

  # Effective config
  if [[ "$source_type" == "instance" ]]; then
    include_str  "$cls_def"    "$cls"    && rerun+=(--db-instance-class "$cls")
    include_str  "$subnet_def" "$subnet" && rerun+=(--db-subnet-group "$subnet")
    include_bool "$pub_def"    "$pub"    && rerun+=(--publicly-accessible "$pub")
    include_bool "$multi_def"  "$multi"  && rerun+=(--multi-az "$multi")
    include_str  "$pgroup_def" "$pgroup" && rerun+=(--db-parameter-group "$pgroup")
    include_str  "$ogroup_def" "$ogroup" && rerun+=(--option-group "$ogroup")

    if include_array sgs_def sgs; then
     rerun+=(--vpc-sg-ids "$(IFS=','; echo "${sgs[*]}")")
    fi
  else
    include_str "$subnet_def" "$subnet" && rerun+=(--db-subnet-group "$subnet")
    include_str "$cpg_def"    "$cpg"    && rerun+=(--db-cluster-parameter-group "$cpg")
    include_str "$ogroup_def" "$ogroup" && rerun+=(--option-group "$ogroup")
    include_str "$inst_class_def" "$inst_class" && rerun+=(--db-instance-class "$inst_class")

    if include_array sgs_def sgs; then
      rerun+=(--vpc-sg-ids "$(IFS=','; echo "${sgs[*]}")")
    fi
  fi

  # print argv, one per line, for capture
  printf '%s\n' "${rerun[@]}"
}

# -------------------- CLI --------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --interactive)
      has_tty || die "--interactive requires /dev/tty"
      INTERACTIVE=1
      shift
      ;;
    --yes|-y)
      YES=1
      INTERACTIVE=0
      shift
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-wait) NO_WAIT=1; shift ;;
    --region) REGION="${2:-}"; shift 2 ;;

    --source) SOURCE="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;

    --latest) LATEST=1; RESTORE_TIME_SPEC=""; RESTORE_TIME_ISO=""; SNAPSHOT_ID=""; shift ;;
    --restore-time) LATEST=0; RESTORE_TIME_SPEC="${2:-}"; SNAPSHOT_ID=""; shift 2 ;;
    --snapshot-id) LATEST=0; RESTORE_TIME_SPEC=""; RESTORE_TIME_ISO=""; SNAPSHOT_ID="${2:-}"; shift 2 ;;

    --aurora-writer-instance) AURORA_WRITER_INSTANCE="${2:-}"; shift 2 ;;

    --db-instance-class) DB_INSTANCE_CLASS="${2:-}"; shift 2 ;;
    --db-subnet-group) DB_SUBNET_GROUP="${2:-}"; shift 2 ;;
    --vpc-sg-ids) VPC_SG_IDS="${2:-}"; shift 2 ;;
    --publicly-accessible) PUBLICLY_ACCESSIBLE="${2:-}"; shift 2 ;;
    --multi-az) MULTI_AZ="${2:-}"; shift 2 ;;
    --db-parameter-group) DB_PARAMETER_GROUP="${2:-}"; shift 2 ;;
    --db-cluster-parameter-group) DB_CLUSTER_PARAMETER_GROUP="${2:-}"; shift 2 ;;
    --option-group) OPTION_GROUP="${2:-}"; shift 2 ;;

    *)
      die "Unknown argument: $1"
      ;;
  esac
done

# If non-interactive, require source/target
if [[ "$INTERACTIVE" == "0" ]]; then
  [[ -n "$SOURCE" ]] || die "--source is required in non-interactive mode"
  [[ -n "$TARGET" ]] || die "--target is required in non-interactive mode"
fi

# Interactive: choose source if not provided
if [[ -z "$SOURCE" ]]; then
  mapfile -t rows < <(list_sources)
  ((${#rows[@]})) || die "No RDS instances or clusters found."

  items=()
  for r in "${rows[@]}"; do
    IFS=$'\t' read -r t id engine status <<<"$r"
    items+=("$id" "$t $engine $status")
  done

  if ! SOURCE=$(choose_one "Sources" "Choose a DB instance or cluster:" "${items[@]}"); then
    cancelled
  fi
fi

source_type=$(detect_source_type "$SOURCE")

# Load bounds early (display normalization once)
if [[ "$source_type" == "instance" ]]; then
  d_bounds=$(instance_defaults_json "$SOURCE")
else
  d_bounds=$(cluster_defaults_json "$SOURCE")
fi

EARLIEST_RESTORABLE=$(echo "$d_bounds" | jq -r '.EarliestRestorableTime // empty')
LATEST_RESTORABLE=$(echo "$d_bounds" | jq -r '.LatestRestorableTime // empty')
RETENTION_DAYS=$(echo "$d_bounds" | jq -r '.BackupRetentionPeriod // empty')

if [[ -n "$EARLIEST_RESTORABLE" ]]; then
  EARLIEST_DISPLAY="$EARLIEST_RESTORABLE"
elif [[ -n "$RETENTION_DAYS" ]]; then
  EARLIEST_DISPLAY="not reported by AWS (retention: ${RETENTION_DAYS} days)"
else
  EARLIEST_DISPLAY="not reported by AWS"
fi

if [[ -n "$LATEST_RESTORABLE" ]]; then
  LATEST_DISPLAY="$LATEST_RESTORABLE"
else
  LATEST_DISPLAY="not reported by AWS"
fi

# Interactive: choose restore intent BEFORE target naming; choose snapshot/time immediately
if [[ "$INTERACTIVE" == "1" && -z "$SNAPSHOT_ID" && -z "$RESTORE_TIME_SPEC" ]]; then
  if ! choice=$(choose_one "Restore target" "Restore to:" \
    latest   "Latest available state (default)" \
    time     "Specific point in time" \
    snapshot "Specific snapshot"); then
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
if [[ "$INTERACTIVE" == "0" && -n "$RESTORE_TIME_SPEC" ]]; then
  RESTORE_TIME_ISO=$(resolve_restore_time_spec_to_iso "$RESTORE_TIME_SPEC")
fi

# Propose default target naming if not provided (whiptail inputbox in interactive)
if [[ -z "$TARGET" ]]; then
  ts=$(date +%Y%m%d-%H%M%S)
  default_target="${SOURCE}-restore-${ts}"
  if [[ "$INTERACTIVE" == "1" ]]; then
    if ! TARGET=$(choose_text_keep_default_if_empty "Target identifier" "Enter target identifier:" "$default_target"); then
      cancelled
    fi
  else
    TARGET="$default_target"
  fi
fi

ensure_target_available_or_prompt "$source_type" TARGET

# Aurora writer id required for clusters
if [[ "$source_type" == "cluster" && -z "$AURORA_WRITER_INSTANCE" ]]; then
  if [[ "$INTERACTIVE" == "1" ]]; then
    if ! AURORA_WRITER_INSTANCE=$(choose_text_keep_default_if_empty "Writer instance" "Enter Aurora writer instance identifier:" "${TARGET}-writer"); then
      cancelled
    fi
  else
    die "Aurora restore requires --aurora-writer-instance <id>"
  fi
fi
if [[ "$source_type" == "cluster" ]]; then
  ensure_target_available_or_prompt "instance" AURORA_WRITER_INSTANCE
fi

# Build aws prefix
aws_prefix=(aws)
[[ -n "$REGION" ]] && aws_prefix+=(--region "$REGION")

# Build restore command (+ always prompt config in interactive mode)
if [[ "$source_type" == "instance" ]]; then
  d=$(instance_defaults_json "$SOURCE")
  cls=$(echo "$d" | jq -r '.DBInstanceClass')
  subnet=$(echo "$d" | jq -r '.DBSubnetGroupName')
  pub=$(echo "$d" | jq -r '.PubliclyAccessible')
  multi=$(echo "$d" | jq -r '.MultiAZ')
  pgroup=$(echo "$d" | jq -r '.DBParameterGroupName')
  ogroup=$(echo "$d" | jq -r '.OptionGroupName')
  mapfile -t sgs < <(echo "$d" | jq -r '.VpcSecurityGroupIds[]')

  # Store the defaults
  cls_def="$cls"
  subnet_def="$subnet"
  pub_def="$pub"
  multi_def="$multi"
  pgroup_def="$pgroup"
  ogroup_def="$ogroup"
  sgs_def=("${sgs[@]}")

  # Apply CLI overrides first
  [[ -n "$DB_INSTANCE_CLASS" ]] && cls="$DB_INSTANCE_CLASS"
  [[ -n "$DB_SUBNET_GROUP" ]] && subnet="$DB_SUBNET_GROUP"
  [[ -n "$PUBLICLY_ACCESSIBLE" ]] && pub="$PUBLICLY_ACCESSIBLE"
  [[ -n "$MULTI_AZ" ]] && multi="$MULTI_AZ"
  [[ -n "$DB_PARAMETER_GROUP" ]] && pgroup="$DB_PARAMETER_GROUP"
  [[ -n "$OPTION_GROUP" ]] && ogroup="$OPTION_GROUP"
  if [[ -n "$VPC_SG_IDS" ]]; then split_to_array "$VPC_SG_IDS" sgs; fi

  # Always prompt (fast: defaults prefilled)
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

    sgs_def_csv=$(IFS=','; echo "${sgs[*]}")
    if ! sgs_in=$(choose_text_keep_default_if_empty "Security groups" "VPC security groups (comma-separated):" "$sgs_def_csv"); then cancelled; fi
    split_to_array "$sgs_in" sgs
  fi

  if [[ -n "$SNAPSHOT_ID" ]]; then
    cmd_restore=( "${aws_prefix[@]}" rds restore-db-instance-from-db-snapshot
      --db-instance-identifier "$TARGET"
      --db-snapshot-identifier "$SNAPSHOT_ID"
      --db-instance-class "$cls"
      --db-subnet-group-name "$subnet"
    )
  else
    cmd_restore=( "${aws_prefix[@]}" rds restore-db-instance-to-point-in-time
      --source-db-instance-identifier "$SOURCE"
      --target-db-instance-identifier "$TARGET"
      --db-instance-class "$cls"
      --db-subnet-group-name "$subnet"
    )
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
  d=$(cluster_defaults_json "$SOURCE")
  engine=$(echo "$d" | jq -r '.Engine')
  subnet=$(echo "$d" | jq -r '.DBSubnetGroupName')
  cpg=$(echo "$d" | jq -r '.DBClusterParameterGroupName')
  ogroup=$(echo "$d" | jq -r '.OptionGroupName')
  mapfile -t sgs < <(echo "$d" | jq -r '.VpcSecurityGroupIds[]')

  subnet_def="$subnet"
  cpg_def="$cpg"
  ogroup_def="$ogroup"
  sgs_def=("${sgs[@]}")

  [[ -n "$DB_SUBNET_GROUP" ]] && subnet="$DB_SUBNET_GROUP"
  [[ -n "$DB_CLUSTER_PARAMETER_GROUP" ]] && cpg="$DB_CLUSTER_PARAMETER_GROUP"
  [[ -n "$OPTION_GROUP" ]] && ogroup="$OPTION_GROUP"
  if [[ -n "$VPC_SG_IDS" ]]; then split_to_array "$VPC_SG_IDS" sgs; fi

  inst_class="${DB_INSTANCE_CLASS:-db.r6g.large}"

  # Always prompt (fast: defaults prefilled)
  if [[ "$INTERACTIVE" == "1" ]]; then
    if ! subnet=$(choose_text_keep_default_if_empty "DB subnet group" "DB subnet group:" "$subnet"); then cancelled; fi
    if [[ -n "$cpg" && "$cpg" != "null" ]]; then
      if ! cpg=$(choose_text_keep_default_if_empty "Cluster parameter group" "DB cluster parameter group:" "$cpg"); then cancelled; fi
    fi
    if [[ -n "$ogroup" && "$ogroup" != "null" ]]; then
      if ! ogroup=$(choose_text_keep_default_if_empty "Option group" "Option group:" "$ogroup"); then cancelled; fi
    fi
    if ! inst_class=$(choose_text_keep_default_if_empty "Writer class" "Writer instance class:" "$inst_class"); then cancelled; fi
    sgs_def_csv=$(IFS=','; echo "${sgs[*]}")
    if ! sgs_in=$(choose_text_keep_default_if_empty "Security groups" "VPC security groups (comma-separated):" "$sgs_def_csv"); then cancelled; fi
    split_to_array "$sgs_in" sgs
  fi

  if [[ -n "$SNAPSHOT_ID" ]]; then
    cmd_restore=( "${aws_prefix[@]}" rds restore-db-cluster-from-snapshot
      --db-cluster-identifier "$TARGET"
      --snapshot-identifier "$SNAPSHOT_ID"
      --engine "$engine"
    )
  else
    cmd_restore=( "${aws_prefix[@]}" rds restore-db-cluster-to-point-in-time
      --source-db-cluster-identifier "$SOURCE"
      --db-cluster-identifier "$TARGET"
    )
    if [[ -n "$RESTORE_TIME_SPEC" ]]; then
      cmd_restore+=(--restore-to-time "${RESTORE_TIME_ISO:-$RESTORE_TIME_SPEC}")
    else
      cmd_restore+=(--use-latest-restorable-time)
    fi
  fi

  [[ -n "$subnet" && "$subnet" != "null" ]] && cmd_restore+=(--db-subnet-group-name "$subnet")
  ((${#sgs[@]})) && cmd_restore+=(--vpc-security-group-ids "${sgs[@]}")
  [[ -n "$cpg" && "$cpg" != "null" ]] && cmd_restore+=(--db-cluster-parameter-group-name "$cpg")
  [[ -n "$ogroup" && "$ogroup" != "null" ]] && cmd_restore+=(--option-group-name "$ogroup")

  cmd_wait_cluster=( "${aws_prefix[@]}" rds wait db-cluster-available --db-cluster-identifier "$TARGET" )
  cmd_create_writer=( "${aws_prefix[@]}" rds create-db-instance
    --db-instance-identifier "$AURORA_WRITER_INSTANCE"
    --db-instance-class "$inst_class"
    --engine "$engine"
    --db-cluster-identifier "$TARGET"
  )
  cmd_wait_writer=( "${aws_prefix[@]}" rds wait db-instance-available --db-instance-identifier "$AURORA_WRITER_INSTANCE" )
fi

# Final plan + commands
echo
echo "================ EXECUTION PLAN ======================"
echo "Source:   $SOURCE"
echo "Type:     $source_type"
echo "Target:   $TARGET"
[[ "$source_type" == "cluster" ]] && echo "Writer:   $AURORA_WRITER_INSTANCE"
echo "Earliest: $EARLIEST_DISPLAY"
echo "Latest:   $LATEST_DISPLAY"
if [[ -n "$SNAPSHOT_ID" ]]; then
  echo "Restore:  snapshot -> $SNAPSHOT_ID"
elif [[ -n "$RESTORE_TIME_SPEC" ]]; then
  echo "Restore:  time -> $RESTORE_TIME_SPEC (resolved: ${RESTORE_TIME_ISO:-same})"
else
  echo "Restore:  latest available state"
fi
echo "------------------------------------------------------"
echo "Commands that will be executed:"
echo
print_cmd "1)" "${cmd_restore[@]}"

if [[ "$NO_WAIT" == "1" ]]; then
  echo "2) (not executed due to --no-wait) wait commands"
  echo
else
  if [[ "$source_type" == "instance" ]]; then
    print_cmd "2)" "${cmd_wait[@]}"
  else
    print_cmd "2)" "${cmd_wait_cluster[@]}"
    print_cmd "3)" "${cmd_create_writer[@]}"
    print_cmd "4)" "${cmd_wait_writer[@]}"
  fi
fi

echo "======================================================"
mapfile -t rerun_minimal < <(build_rerun_cmd minimal)
mapfile -t rerun_full    < <(build_rerun_cmd full)
echo "Re-run this exact restore non-interactively (with defaults):"
print_cmd "" "${rerun_minimal[@]}"
echo "Re-run this exact restore non-interactively (hardcoded arguments):"
print_cmd "" "${rerun_full[@]}"
echo "Single-line (copy/paste):"
echo -n " "; print_shell_cmd "${rerun_minimal[@]}"
echo
echo "======================================================"
echo

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
    | jq -r '.DBClusters[0] | "Cluster endpoint: \(.Endpoint)\nReader endpoint:  \(.ReaderEndpoint)\nStatus: \(.Status)\nEngine: \(.Engine) \(.EngineVersion)"'
fi
