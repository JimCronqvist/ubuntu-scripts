#!/bin/bash

# Simulate EC2 Spot Instance Interruption Notice
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-instance-termination-notices.html

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text --query 'Account')
AWS_REGION=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath="{.contexts[?(@.name == '$(kubectl config current-context)')].context.cluster}" | cut -d / -f 2)
SQS_QUEUE_URL=$(aws sqs get-queue-url --queue-name "Karpenter-$CLUSTER_NAME" --query "QueueUrl" --output text)

echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo "AWS Region: $AWS_REGION"
echo "Cluster Name: $CLUSTER_NAME"
echo "SQS Queue URL: $SQS_QUEUE_URL"
echo ""

if [ $# -eq 0 ]; then
  # If no arguments are passed, print out the EC2 nodes
  echo "EC2 Instances for EKS cluster $CLUSTER_NAME:"
  echo ""
  #kubectl get nodes | grep -v "^fargate"
  aws ec2 describe-instances \
    --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME" \
    --query "Reservations[*].Instances[*].{Name: Tags[?Key=='Name'].Value | [0],InstanceID: InstanceId, InstanceType: InstanceType, InstanceState: State.Name, AvailabilityZone: Placement.AvailabilityZone, LocalIP: NetworkInterfaces[0].PrivateIpAddress}" \
    --output text
  echo ""
  echo "Usage: ./simulate-spot-interruption.sh <instance-id|instance-name>"
  echo ""
  exit 1
fi

INPUT="$1"
if [[ "$INPUT" == i-* ]]; then
  # If $1 starts with "i-", treat it as an instance ID
  INSTANCE_ID="$INPUT"
  INSTANCE_NAME=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query "Reservations[*].Instances[*].Tags[?Key=='Name'].Value | [0]" --output text)
else
  # If not, treat it as an instance name
  INSTANCE_NAME="$INPUT"
  INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" --query "Reservations[*].Instances[*].InstanceId" --output text)
fi

# Function to list pods on the specified node
list_pods_on_node() {
  kubectl get pods --all-namespaces --field-selector spec.nodeName="$INSTANCE_NAME" -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,OWNER_KIND:.metadata.ownerReferences[0].kind,AGE:.metadata.creationTimestamp" --no-headers
}

echo "EC2 Instance ID: $INSTANCE_ID"
echo "EC2 Instance Name: $INSTANCE_NAME"
echo "Cluster Name: $CLUSTER_NAME"
echo "AWS Region: $AWS_REGION"
echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo "SQS Queue URL: $SQS_QUEUE_URL"
echo ""
echo "Existing pods on node $INSTANCE_NAME to be drained:"
echo ""
list_pods_on_node
echo ""

MESSAGE_REBALANCE_RECOMMENDATION='{
  "version": "0",
  "id": "'$(uuidgen)'",
  "detail-type": "EC2 Instance Rebalance Recommendation",
  "source": "aws.ec2",
  "account": "'$AWS_ACCOUNT_ID'",
  "time": "'$(date --iso-8601=seconds)'",
  "region": "'$AWS_REGION'",
  "resources": [
    "arn:aws:ec2:'$AWS_REGION':'$AWS_ACCOUNT_ID':instance/'$INSTANCE_ID'"
  ],
  "detail": {
    "instance-id": "'$INSTANCE_ID'"
  }
}'

# Simulated interruption notice message in JSON format
MESSAGE_INTERRUPTION_WARNING='{
  "version": "0",
  "id": "'$(uuidgen)'",
  "detail-type": "EC2 Spot Instance Interruption Warning",
  "source": "aws.ec2",
  "account": "'$AWS_ACCOUNT_ID'",
  "time": "'$(date --iso-8601=seconds)'",
  "region": "'$AWS_REGION'",
  "resources": [
    "arn:aws:ec2:'$AWS_REGION':'$AWS_ACCOUNT_ID':instance/'$INSTANCE_ID'"
  ],
  "detail": {
    "instance-id": "'$INSTANCE_ID'",
    "instance-action": "terminate"
  }
}'

# Send the simulated rebalance warning to SQS, this usually goes out a bit before the interruption notice happens
#aws sqs send-message --queue-url "$SQS_QUEUE_URL" --message-body "$(echo "$MESSAGE_REBALANCE_RECOMMENDATION" | jq -c .)"
#echo ""
#read -p "Press enter to send off the interruption notice..."

# Send the simulated interruption notice to SQS
echo "Sending off an interruption notice to SQS for Karpenter to pick up..."
aws sqs send-message --queue-url "$SQS_QUEUE_URL" --message-body "$(echo "$MESSAGE_INTERRUPTION_WARNING" | jq -c .)"
echo ""

# Wait for ~2 minutes for all pods to be drained to simulate the notice period
echo "Waiting for ~2 minutes to simulate the notice period..."
echo ""

# Wait for up to 2 minutes for all pods to be drained
timeout=$((SECONDS + 120))
while [ $SECONDS -lt $timeout ]; do
  pods=$(list_pods_on_node)
  pending_pods=$(echo "$pods" | grep -v "Succeeded\|Completed")
  if [ -n "$pending_pods" ]; then
    echo "Waiting for pods on node $INSTANCE_NAME to be drained... Pending Pods:"
    echo ""
    echo "$pending_pods"
    echo ""
    sleep 3
  else
    echo "All pods on node $INSTANCE_NAME have been drained."
    break
  fi
done

# Check if the timeout was reached
if [ $SECONDS -ge $timeout ]; then
  echo ""
  echo "Timeout reached. Not all pods on node $INSTANCE_NAME were drained within the 2 minute timeframe!"
  echo ""
fi

# Terminate the EC2 instance
read -p "Press enter to terminate the EC2 instance..."
echo "Terminating the EC2 instance."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
