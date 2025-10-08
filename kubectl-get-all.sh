#!/usr/bin/env bash
set -euo pipefail

# List all namespaced Kubernetes resources in a given namespace.

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <namespace>"
  echo "Example: $0 default"
  exit 1
fi

namespace="$1"

echo "📦 Listing all resources in namespace: $namespace"

echo
# List all namespaced resource types, then get them all in the given namespace
kubectl api-resources --verbs=list --namespaced -o name | xargs -t -n1 kubectl get --show-kind --ignore-not-found -n "$namespace"
