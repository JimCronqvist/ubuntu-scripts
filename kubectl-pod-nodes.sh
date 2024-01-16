#!/bin/bash

#
# Display a list of all nodes, with the option to pass in a deployment instance name, which will show on which nodes all pods are located on. Useful for testing topologySpreadConstraints, etc.
# Usage: bash kubectl-pod-nodes.sh traefik-traefik
#

DEPLOYMENT_INSTANCE_NAME="$1"

# Function to list nodes and their availability zones
list_nodes() {
    kubectl get nodes --sort-by="{.metadata.labels.topology\.kubernetes\.io/zone}" -o custom-columns="NODE:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,INSTANCE_TYPE:.metadata.labels.beta\.kubernetes\.io/instance-type,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory" | grep -v '^fargate-'
}

# Function to list pod names for a specific deployment
list_pods_for_deployment() {
    local name="$1"
    kubectl get pods --all-namespaces -o custom-columns="NODE:.spec.nodeName,POD:.metadata.name" -l app.kubernetes.io/instance="$name" 2>/dev/null | awk 'NR>1 {nodes[$1]=nodes[$1]","$2} END {for (node in nodes) {print node,nodes[node]}}'
}

if [ $# -eq 0 ]; then
  list_nodes
else
    # List nodes with pod information for the specified deployment
    #echo "NODE AVAILABILITY_ZONE PODS"
    list_nodes | while read -r node zone instance_type cpu memory; do
        pod_info=$(list_pods_for_deployment "$DEPLOYMENT_INSTANCE_NAME" | grep "^$node")
        printf "%-44s %-15s %-19s %-3s %-13s %s \n" $node $zone $instance_type $cpu $memory "$(echo ${pod_info:--} | cut -d' ' -f2 | sed 's/^,//g')"
    done
fi
