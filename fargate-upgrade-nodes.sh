#!/bin/bash

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text --query 'Account')
AWS_REGION=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath="{.contexts[?(@.name == '$(kubectl config current-context)')].context.cluster}" | cut -d / -f 2)

echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo "AWS Region: $AWS_REGION"
echo "Cluster Name: $CLUSTER_NAME"


if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <kubernetes version>"
    echo "Usage: bash fargate-upgrade-nodes.sh v1.28"
    exit 1
fi

BLUE=$(tput setaf 6)
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
NORMAL=$(tput sgr0)

VERSION="$1"
RESTART_DEPLOYMENTS=()

echo ""
echo "Checking each Fargate node to see if an upgrade is required:"

for i in $(kubectl get pods --field-selector=status.phase=Running --all-namespaces -o jsonpath="{range .items[*]}{.metadata.namespace}{','}{.metadata.name}{','}{.spec.nodeName}{','}{.metadata.ownerReferences[0].name}{'\n'}" | grep -E 'fargate-ip-(.*).compute.internal' | sed -E 's/(.*)-([^-]+)$/\1/g'); do
    namespace=$(echo "$i" | cut -f1 -d',')
    pod=$(echo $i | cut -f2 -d',')
    node=$(echo "$i" | cut -f3 -d',')
    deployment=$(echo "$i" | cut -f4 -d',')

    node_version=$(kubectl get node "$node" --no-headers | awk '{ print $5 }')

    if [[ $node_version =~ $VERSION ]]; then
        echo -e "${RED}The Fargate node for pod '$pod' has already been upgraded.${NORMAL}"
    else
        RESTART_DEPLOYMENTS+=("$namespace:$deployment")
        echo -e "${GREEN}The Fargate node for pod $pod will be upgraded!${NORMAL}"
    fi
done

echo ""
echo -e "${BLUE}The following deployments will be restarted to force new Fargate nodes with the latest version:${NORMAL}"
echo "${RESTART_DEPLOYMENTS[@]}" | xargs -n1 | sort -u | sed 's/:/\t/g'
echo ""
read -n 1 -r -s -p $'Press enter to continue...\n'

for i in $(echo "${RESTART_DEPLOYMENTS[@]}" | xargs -n1 | sort -u); do
    namespace=$(echo "$i" | cut -f1 -d':')
    deployment=$(echo "$i" | cut -f2 -d':')

    echo ""
    kubectl -n "$namespace" rollout restart "deployment/$deployment"
    kubectl -n "$namespace" rollout status "deployment/$deployment"
done
