#!/bin/bash

echo "This script updates the kubeconfig file for all EKS clusters in all AWS regions."
echo "We will look for clusters using the following identity, please confirm:"
aws sts get-caller-identity
read -p "Press enter to continue..."
echo ""
echo ""

# Get all AWS regions
regions=$(aws ec2 describe-regions --query "Regions[*].RegionName" --output text)

for region in $regions; do
  echo -n "Checking region '$region'..."
  
  # Get list of clusters in the region
  clusters=$(aws eks list-clusters --region "$region" --output text --query 'clusters[]')

  if [ -n "$clusters" ]; then
    echo " found $(echo $clusters | wc -w) cluster(s)."
    for cluster in $clusters; do
      echo ""
      echo "Updating kubeconfig for cluster: $cluster in region: $region"
      aws eks --region "$region" update-kubeconfig --name "$cluster"
    done
    echo ""
  else
    echo " no cluster found."
  fi
done
