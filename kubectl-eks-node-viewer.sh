#!/bin/bash

# This script launches eks-node-viewer in the region of the Kubernetes cluster
# It requires the AWS CLI, kubectl, and eks-node-viewer to be installed and configured
# You can pass any additional arguments to eks-node-viewer as needed.
# Examples:
# ./kubectl-eks-node-viewer.sh -resources cpu,memory
# ./kubectl-eks-node-viewer.sh -resources memory

set -euo pipefail

# Dependencies check
command -v aws >/dev/null 2>&1 || { echo >&2 "aws cli required but not installed."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo >&2 "kubectl required but not installed."; exit 1; }
command -v eks-node-viewer >/dev/null 2>&1 || { echo >&2 "eks-node-viewer required but not installed."; exit 1; }

echo "🔍 Detecting cluster region..."
REGION=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/region}')
echo "✅ Cluster region detected: ${REGION}"

if [ -z "$REGION" ]; then
    echo "❌ Could not detect region from Kubernetes nodes. Exiting."
    exit 1
fi

echo "✅ Detected Kubernetes region: $REGION"
echo "🚀 Launching eks-node-viewer in region $REGION..."

AWS_REGION=${REGION} eks-node-viewer -extra-labels "nodepool,karpenter.sh/nodepool,topology.kubernetes.io/zone" -node-sort "karpenter.sh/nodepool" "$@"
