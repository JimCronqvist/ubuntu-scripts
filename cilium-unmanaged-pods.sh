#!/usr/bin/env bash

function all_ceps {
  kubectl get cep --all-namespaces -o json |
    jq -r '.items[].metadata | "\(.namespace)/\(.name)"' | sort
}

function all_pods {
  kubectl get pods --all-namespaces -o json |
    jq -r '
      .items[]
      | select((.status.phase=="Running" or .status.phase=="Pending")
          and (.spec.hostNetwork==true | not)
          and ((.spec.nodeName // "") | contains("fargate") | not))
      | "\(.metadata.namespace)/\(.metadata.name)\t\(.spec.nodeName // "None")"
    ' | sort
}

echo "Skipping pods with host networking enabled, on Fargate nodes, or not in Running or Pending phase..." >&2

join -t $'\t' -v2 <(all_ceps) <(all_pods) | column -t
