#!/usr/bin/env bash
set -euo pipefail

# Display usage instructions
usage() {
  echo "Usage: $0 <namespace|-> <kind> <name-pattern> [--dry-run] [--finalizers] [--force] [--one]"
  echo
  echo "Examples:"
  echo "  $0 default Pod my-pod"                   # Delete one pod
  echo "  $0 default Pod argo*"                    # Delete pods starting with 'argo'
  echo "  $0 default Pod * --dry-run"              # Show all delete commands
  echo "  $0 default Pod * --finalizers"           # Remove finalizers instead of deleting
  echo "  $0 - PersistentVolume pv-* --finalizers" # Cluster-scoped example
  echo "  $0 default Pod my-pod --force"           # Force delete resources
  echo "  $0 default Pod * --one"                  # Only run first matching command
  echo
  echo "Notes:"
  echo "  - Use '-' for cluster-scoped resources (e.g. PersistentVolume)."
  echo "  - Use '*' to match all or 'prefix*' for prefix-based matches."
  echo "  - '--finalizers' removes finalizers instead of deleting the resource."
  echo "  - '--force' adds --force and --grace-period=0 to kubectl commands."
  echo "  - '--one' runs only the first matching command."
  echo "  - '--dry-run' prints all commands, asks for confirmation, and exits."
  exit 1
}

# Require at least 3 args
if [[ $# -lt 3 ]]; then
  usage
fi

dry_run=false
remove_finalizers=false
force_delete=false
run_one=false

# Parse flags (allow either order)
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      dry_run=true
      ;;
    --finalizers)
      remove_finalizers=true
      ;;
    --force)
      force_delete=true
      ;;
    --one)
      run_one=true
      ;;
  esac
done

# Strip optional flags for positional args
args=()
for arg in "$@"; do
  if [[ "$arg" != "--dry-run" && "$arg" != "--finalizers" && "$arg" != "--force" && "$arg" != "--one" ]]; then
    args+=("$arg")
  fi
done

namespace="${args[0]}"
kind="${args[1]}"
name_pattern="${args[2]}"

# Print current Kubernetes cluster context for safety
current_context=$(kubectl config current-context 2>/dev/null || echo "unknown")
echo "⚙️  Current cluster context: $current_context"
echo

# Handle namespace vs cluster-scoped
if [[ "$namespace" == "-" ]]; then
  ns_flag=()
  ns_text="(cluster-scoped)"
else
  ns_flag=(-n "$namespace")
  ns_text="in namespace '$namespace'"
fi

echo "Fetching $kind resources $ns_text ..."
mapfile -t all_names < <(kubectl get "$kind" "${ns_flag[@]}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [[ ${#all_names[@]} -eq 0 ]]; then
  echo "No ${kind} resources found $ns_text."
  exit 0
fi

# Match name pattern (supports * or prefix*)
matching_names=()
if [[ "$name_pattern" == "*" ]]; then
  matching_names=("${all_names[@]}")
else
  prefix="${name_pattern%\*}"
  for n in "${all_names[@]}"; do
    if [[ "$n" == "$name_pattern" || "$n" == "$prefix"* ]]; then
      matching_names+=("$n")
    fi
  done
fi

if [[ ${#matching_names[@]} -eq 0 ]]; then
  echo "No ${kind} resources matched '$name_pattern' $ns_text."
  exit 0
fi

echo "Found ${#matching_names[@]} matching ${kind}(s) $ns_text:"
printf '  %s\n' "${matching_names[@]}"
echo

# Build kubectl commands based on mode
commands=()
for name in "${matching_names[@]}"; do
  grace_force_flags=""
  if $force_delete; then
    grace_force_flags="--grace-period=0 --force=true"
  fi

  if $remove_finalizers; then
    cmd="kubectl ${ns_flag[*]} patch $kind $name --type=merge -p '{\"metadata\":{\"finalizers\":[]}}' $grace_force_flags"
  else
    cmd="kubectl ${ns_flag[*]} delete $kind $name $grace_force_flags"
  fi
  commands+=("$cmd")
done

# If --one, limit to the first command
if $run_one && [[ ${#commands[@]} -gt 0 ]]; then
  commands=("${commands[0]}")
  echo "⚠️  --one specified: only the first command will be executed."
  echo
fi

# Display commands
if $remove_finalizers; then
  action_desc="remove finalizers from"
else
  action_desc="delete"
fi

echo "The following commands will be used to $action_desc ${#commands[@]} ${kind}(s) $ns_text:"
echo
printf '%s\n' "${commands[@]}"
echo

# Handle dry-run before execution prompt
if $dry_run; then
  echo "✅ Dry run complete — no commands executed."
  exit 0
fi

# Prompt user before executing
read -rp "Press ENTER to continue (or Ctrl+C to abort)..."
echo

# Execute commands for real
for cmd in "${commands[@]}"; do
  echo "→ Executing: $cmd"
  eval "$cmd" >/dev/null || echo "⚠️  Failed: $cmd"
done
