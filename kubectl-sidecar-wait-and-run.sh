#!/bin/sh

set -e

NAMESPACE=${NAMESPACE:-$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)}
CHECK_INTERVAL=${CHECK_INTERVAL:-5}
TIMEOUT=${TIMEOUT:-3600}
OWN_CONTAINER_NAME=${OWN_CONTAINER_NAME:-$(hostname)}

if [ "$#" -eq 0 ]; then
  echo "[ERROR] No command specified. Please provide the command to execute as arguments."
  exit 1
fi

echo "[INFO] Auto-detecting main container in pod [$NAMESPACE/$HOSTNAME] excluding [$OWN_CONTAINER_NAME]..."

# Get ordered container names from manifest, excluding itself
containers=$(kubectl get pod "$HOSTNAME" -n "$NAMESPACE" \
  -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' | grep -v "^$OWN_CONTAINER_NAME$")

main_container=$(echo "$containers" | head -n 1)
other_containers=$(echo "$containers" | tail -n +2)

if [ -n "$other_containers" ]; then
  echo "[WARN] Multiple containers detected: [$containers]"
  echo "[WARN] Assuming first container [$main_container] is main."
else
  echo "[INFO] Identified main container as [$main_container]."
fi

elapsed=0

while [ $elapsed -lt $TIMEOUT ]; do
    status=$(kubectl get pod "$HOSTNAME" -n "$NAMESPACE" \
      -o jsonpath="{.status.containerStatuses[?(@.name==\"$main_container\")].state.terminated.reason}")

    if [ "$status" = "Completed" ]; then
        echo "[INFO] Container [$main_container] completed successfully. Executing command."
        exec "$@"
    elif [ "$status" = "Error" ] || [ "$status" = "OOMKilled" ]; then
        echo "[ERROR] Container [$main_container] failed with status [$status]. Exiting."
        exit 1
    else
        echo "[INFO] Container [$main_container] still running [$status]. Checking again in $CHECK_INTERVAL seconds..."
        sleep "$CHECK_INTERVAL"
        elapsed=$((elapsed + CHECK_INTERVAL))
    fi
done

echo "[ERROR] Timed out after $TIMEOUT seconds waiting for [$main_container]."
exit 1
