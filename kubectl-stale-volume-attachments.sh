#!/bin/bash

# Array for errors
errors=()

# Header for the table
header="ATTACHMENT_ID\tPVC\tPV\tNODE\tCLAIM\tSTATUS\tATTACHED_POD\tPOD_NODE\tACCESS_MODE"

# Initialize rows array
rows=()

# Add header to rows
rows+=("$header")

# Fetch all PV details once
declare -A pv_to_pvc
while read -r pv pvc_ns pvc_name access_mode; do
  pv_to_pvc["$pv"]="$pvc_ns/$pvc_name;$access_mode"
done < <(kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.claimRef.namespace}{" "}{.spec.claimRef.name}{" "}{.spec.accessModes[0]}{"\n"}{end}')

# List all VolumeAttachments
while read -r va; do
  attachment=$(echo "$va" | jq -r '.metadata.name')
  node=$(echo "$va" | jq -r '.spec.nodeName')
  pv=$(echo "$va" | jq -r '.spec.source.persistentVolumeName')
  status=$(echo "$va" | jq -r '.status.attached')

  pvc_access=${pv_to_pvc[$pv]}
  pvc=$(echo "$pvc_access" | cut -d';' -f1)
  access_mode=$(echo "$pvc_access" | cut -d';' -f2)

  if [[ -z "$pvc" || "$pvc" == "/" ]]; then
    errors+=("PV $pv has no PVC bound. VolumeAttachment $attachment may be stale.")
    rows+=("$attachment\tN/A\t$pv\t$node\tN/A\t$status\tN/A\tN/A\t$access_mode")
    continue
  fi

  pvc_namespace=$(echo "$pvc" | cut -d'/' -f1)
  pvc_name=$(echo "$pvc" | cut -d'/' -f2)

  # Check pods using the PVC
  pod_using_pvc=$(kubectl get pods -n "$pvc_namespace" -o json | jq -r --arg pvc_name "$pvc_name" '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName==$pvc_name) | "\(.metadata.name)\t\(.spec.nodeName)"')

  if [ -z "$pod_using_pvc" ]; then
    errors+=("VolumeAttachment $attachment (PVC: $pvc, Node: $node) has no active pods.")
    rows+=("$attachment\t$pvc\t$pv\t$node\tBound\t$status\tN/A\tN/A\t$access_mode")
  else
    while IFS=$'\t' read -r pod pod_node; do
      if [ "$pod_node" != "$node" ]; then
        errors+=("- Mismatch detected: PVC $pvc attached to node $node, but pod $pod is on node $pod_node.")
        errors+=("Fix by: kubectl delete volumeattachments $attachment")
      fi

      rows+=("$attachment\t$pvc\t$pv\t$node\tBound\t$status\t$pod\t$pod_node\t$access_mode")
    done <<< "$pod_using_pvc"
  fi
done < <(kubectl get volumeattachments -o json | jq -c '.items[]')

# Display the table
printf "%b\n" "${rows[@]}" | column -t -s $'\t'

# Display errors if any
if [ ${#errors[@]} -gt 0 ]; then
  echo -e "\nDetected Issues:"
  for error in "${errors[@]}"; do
    echo "$error"
  done
fi