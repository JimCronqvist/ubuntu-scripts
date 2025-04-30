#!/bin/bash

ACTION=$1

usage() {
  echo "Usage: $0 [get|delete|restart]"
  echo "  get     - List pods in ImagePullBackOff state"
  echo "  delete  - Delete pods in ImagePullBackOff state"
  echo "  restart - Restart controllers associated with pods in ImagePullBackOff state"
}

if [ -z "$ACTION" ]; then
  usage
  exit 1
fi

RESULT=$(kubectl get pods --all-namespaces -o json | jq -r '
.items[] |
select(any(.status.containerStatuses[]?; .state.waiting.reason=="ImagePullBackOff")) |
"\(.metadata.namespace) \(.metadata.name)"' | while read namespace pod; do
  owner_kind=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.metadata.ownerReferences[0].kind}')
  owner_name=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.metadata.ownerReferences[0].name}')

  if [ "$owner_kind" = "ReplicaSet" ]; then
    deploy_name=$(kubectl get replicaset "$owner_name" -n "$namespace" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null)
    if [ -n "$deploy_name" ]; then
      echo -e "$namespace\tDeployment\t$deploy_name\t$pod"
    else
      echo -e "$namespace\tReplicaSet\t$owner_name\t$pod"
    fi
  elif [ "$owner_kind" = "StatefulSet" ] || [ "$owner_kind" = "DaemonSet" ]; then
    echo -e "$namespace\t$owner_kind\t$owner_name\t$pod"
  else
    echo -e "$namespace\tPod\t$pod\t$pod"
  fi
done | sort -u)

echo -e "$RESULT"

case "$ACTION" in
  get|list)
    exit 0
    ;;

  delete)
    echo "---- Deleting Pods ----"
    echo -e "$RESULT" | awk '{print $1, $4}' | while read ns pod; do
      echo "Deleting pod $pod in namespace $ns"
      kubectl delete pod "$pod" -n "$ns"
    done
    ;;

  restart)
    echo "---- Restarting Controllers ----"
    echo -e "$RESULT" | awk '{print $1, tolower($2), $3}' | sort -u | while read ns kind owner; do
      if [ "$kind" = "deployment" ] || [ "$kind" = "statefulset" ] || [ "$kind" = "daemonset" ]; then
        echo "Restarting $kind/$owner in namespace $ns"
        kubectl rollout restart "$kind/$owner" -n "$ns"
      else
        echo "Skipping restart for kind: $kind ($owner) in namespace $ns"
      fi
    done
    ;;

  *)
    usage
    exit 1
    ;;
esac
