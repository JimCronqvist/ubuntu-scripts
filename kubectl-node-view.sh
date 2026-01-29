#!/usr/bin/env bash
set -euo pipefail

# Requires: kubectl, jq, metrics-server (for "kubectl top")

# ---------- Helpers for unit conversion ----------

cpu_to_milli() {
  local v="$1"
  [[ -z "$v" || "$v" == "0" ]] && { echo 0; return; }
  if [[ "$v" == *m ]]; then
    echo "${v%m}"
  else
    awk "BEGIN { printf \"%d\", $v*1000 }"
  fi
}

mem_to_mib() {
  local v="$1"
  [[ -z "$v" || "$v" == "0" ]] && { echo 0; return; }

  local num unit
  num="${v%%[KMGTP]*}"
  unit="${v#$num}"

  case "$unit" in
    Ki) awk "BEGIN { printf \"%d\", $num/1024 }" ;;
    Mi|"") awk "BEGIN { printf \"%d\", $num }" ;;
    Gi) awk "BEGIN { printf \"%d\", $num*1024 }" ;;
    Ti) awk "BEGIN { printf \"%d\", $num*1024*1024 }" ;;
    K)  awk "BEGIN { printf \"%d\", $num/1024 }" ;;
    M)  awk "BEGIN { printf \"%d\", $num }" ;;
    G)  awk "BEGIN { printf \"%d\", $num*1024 }" ;;
    T)  awk "BEGIN { printf \"%d\", $num*1024*1024 }" ;;
    *)  echo 0 ;;
  esac
}

milli_to_str() { echo "${1}m"; }
mib_to_str()   { echo "${1}Mi"; }

mib_to_gi_str() {
  local mi="$1"
  [[ -z "$mi" ]] && { echo "0Gi"; return; }
  awk "BEGIN { printf \"%.2fGi\", $mi/1024 }"
}

# ---------- Collect node info ----------

nodes_json="$(kubectl get nodes -o json)"

declare -A NODE_ZONE NODE_TYPE NODE_CPU_CAP NODE_MEM_CAP NODE_CPU_ALLOC NODE_MEM_ALLOC
NODE_LIST=()

while IFS=$'\t' read -r name zone itype cpuCap memCap cpuAlloc memAlloc; do
  NODE_LIST+=("$name")
  NODE_ZONE["$name"]="$zone"
  NODE_TYPE["$name"]="$itype"
  NODE_CPU_CAP["$name"]="$cpuCap"
  NODE_MEM_CAP["$name"]="$memCap"
  NODE_CPU_ALLOC["$name"]="$cpuAlloc"
  NODE_MEM_ALLOC["$name"]="$memAlloc"
done < <(
  printf "%s" "$nodes_json" | jq -r '
    .items[]
    | [
        .metadata.name,
        (.metadata.labels["topology.kubernetes.io/zone"]
         // .metadata.labels["failure-domain.beta.kubernetes.io/zone"]
         // "-"),
        (.metadata.labels["node.kubernetes.io/instance-type"]
         // .metadata.labels["beta.kubernetes.io/instance-type"]
         // "-"),
        .status.capacity.cpu,
        .status.capacity.memory,
        .status.allocatable.cpu,
        .status.allocatable.memory
      ]
    | @tsv
  '
)

# ---------- Node metrics ----------

declare -A NODE_CPU_USED NODE_MEM_USED NODE_CPU_PCT NODE_MEM_PCT

if kubectl top nodes &>/dev/null; then
  while read -r name cpu cpu_pct mem mem_pct; do
    NODE_CPU_USED["$name"]="$cpu"
    NODE_CPU_PCT["$name"]="$cpu_pct"
    NODE_MEM_USED["$name"]="$mem"
    NODE_MEM_PCT["$name"]="$mem_pct"
  done < <(kubectl top nodes --no-headers 2>/dev/null || true)
fi

# ---------- Pod live usage ----------

declare -A METRIC_CPU METRIC_MEM

if kubectl top pods -A &>/dev/null; then
  while read -r ns pod container cpu mem; do
    METRIC_CPU["$ns/$pod/$container"]="$cpu"
    METRIC_MEM["$ns/$pod/$container"]="$mem"
  done < <(kubectl top pods -A --containers --no-headers | awk '{print $1, $2, $3, $4, $5}')
fi

# ---------- Pod spec & aggregation ----------

pods_json="$(kubectl get pods -A -o json)"

declare -A POD_NODE POD_OWNER POD_NS POD_NAME
declare -A POD_CPU_REQ POD_CPU_LIM POD_CPU_USE
declare -A POD_MEM_REQ POD_MEM_LIM POD_MEM_USE

POD_KEYS=()

while IFS=$'\t' read -r node ns pod ownerKind ownerName container cpuReq cpuLim memReq memLim; do
  key="$ns/$pod"
  [[ -z "$node" ]] && continue

  if [[ -z "${POD_NODE[$key]+x}" ]]; then
    POD_NODE["$key"]="$node"
    POD_NS["$key"]="$ns"
    POD_NAME["$key"]="$pod"

    [[ "$ownerKind" == "ReplicaSet" ]] && ownerKind="Deployment"
    [[ -z "$ownerKind" ]] && ownerKind="Pod"
    POD_OWNER["$key"]="$ownerKind"

    POD_KEYS+=("$key")
  fi

  cpuReqM=$(cpu_to_milli "$cpuReq")
  cpuLimM=$(cpu_to_milli "$cpuLim")
  memReqMi=$(mem_to_mib "$memReq")
  memLimMi=$(mem_to_mib "$memLim")

  cpuUseM=$(cpu_to_milli "${METRIC_CPU[$ns/$pod/$container]:-0}")
  memUseMi=$(mem_to_mib "${METRIC_MEM[$ns/$pod/$container]:-0}")

  POD_CPU_REQ["$key"]=$(( ${POD_CPU_REQ[$key]:-0} + cpuReqM ))
  POD_CPU_LIM["$key"]=$(( ${POD_CPU_LIM[$key]:-0} + cpuLimM ))
  POD_CPU_USE["$key"]=$(( ${POD_CPU_USE[$key]:-0} + cpuUseM ))

  POD_MEM_REQ["$key"]=$(( ${POD_MEM_REQ[$key]:-0} + memReqMi ))
  POD_MEM_LIM["$key"]=$(( ${POD_MEM_LIM[$key]:-0} + memLimMi ))
  POD_MEM_USE["$key"]=$(( ${POD_MEM_USE[$key]:-0} + memUseMi ))

done < <(
  printf "%s" "$pods_json" | jq -r '
    .items[]
    | select(
        .status.phase != "Succeeded"
        and .status.phase != "Failed"
        and (.spec.nodeName // "") != ""
      )
    | . as $pod
    | ($pod.metadata.namespace) as $ns
    | ($pod.metadata.name) as $podname
    | ($pod.spec.nodeName) as $node
    | ($pod.metadata.ownerReferences[0].kind // "Pod") as $ownerKind
    | ($pod.metadata.ownerReferences[0].name // $podname) as $ownerName
    | .spec.containers[]
    | [
        $node, $ns, $podname, $ownerKind, $ownerName, .name,
        (.resources.requests.cpu // "0"),
        (.resources.limits.cpu // "0"),
        (.resources.requests.memory // "0"),
        (.resources.limits.memory // "0")
      ]
    | @tsv
  '
)

# ---------- Output ----------

mapfile -t NODE_LIST_SORTED < <(printf "%s\n" "${NODE_LIST[@]}" | sort)

for node in "${NODE_LIST_SORTED[@]}"; do
  zone="${NODE_ZONE[$node]}"
  itype="${NODE_TYPE[$node]}"

  cpuAlloc="${NODE_CPU_ALLOC[$node]:--}"
  cpuCap="${NODE_CPU_CAP[$node]:--}"

  memAllocMi=$(mem_to_mib "${NODE_MEM_ALLOC[$node]:-0}")
  memCapMi=$(mem_to_mib "${NODE_MEM_CAP[$node]:-0}")
  memAllocGi=$(mib_to_gi_str "$memAllocMi")
  memCapGi=$(mib_to_gi_str "$memCapMi")

  cpuUsed="${NODE_CPU_USED[$node]:--}"
  cpuPct="${NODE_CPU_PCT[$node]:--}"

  memUsedRaw="${NODE_MEM_USED[$node]:--}"
  memPct="${NODE_MEM_PCT[$node]:--}"

  if [[ "$memUsedRaw" != "-" ]]; then
    memUsedMi=$(mem_to_mib "$memUsedRaw")
    memUsedGi=$(mib_to_gi_str "$memUsedMi")
  else
    memUsedGi="-"
  fi

  cpuUseStr="$cpuUsed"
  if [[ "$cpuUsed" != "-" && "$cpuPct" != "-" ]]; then
    cpuUseStr="${cpuUsed}(${cpuPct})"
  fi

  memUseStr="$memUsedGi"
  if [[ "$memUsedGi" != "-" && "$memPct" != "-" ]]; then
    memUseStr="${memUsedGi}(${memPct})"
  fi

  # ---- Node header + row ----
  printf "%0.s-" {1..180}; echo
  printf "%-45s %-10s %-14s %-22s %-22s %-18s %-18s\n" \
    "NODE" "ZONE" "INSTANCE_TYPE" "CPU(use/alloc)" "MEM(use/alloc)" "CPU(cap)" "MEM(cap)"
  printf "%-45s %-10s %-14s %-22s %-22s %-18s %-18s\n" \
    "$node" "$zone" "$itype" \
    "$cpuUseStr/$cpuAlloc" "$memUseStr/$memAllocGi" \
    "$cpuCap" "$memCapGi"

  echo  # blank line between node row and pods

  # ---- Pod header ----
  printf "  %-12s %-20s %-65s %-16s %-10s %-16s %-10s\n" \
    "TYPE" "NAMESPACE" "POD" "CPU req/lim" "CPU%" "MEM req/lim" "MEM%"

  # Pods on this node
  mapfile -t node_pods < <(
    for key in "${POD_KEYS[@]}"; do
      [[ "${POD_NODE[$key]}" == "$node" ]] && echo "$key"
    done | sort
  )

  for key in "${node_pods[@]}"; do
    ns="${POD_NS[$key]}"
    pod="${POD_NAME[$key]}"
    type="${POD_OWNER[$key]}"

    cpuReqM=${POD_CPU_REQ[$key]:-0}
    cpuLimM=${POD_CPU_LIM[$key]:-0}
    cpuUseM=${POD_CPU_USE[$key]:-0}
    memReqMi=${POD_MEM_REQ[$key]:-0}
    memLimMi=${POD_MEM_LIM[$key]:-0}
    memUseMi=${POD_MEM_USE[$key]:-0}

    # ----- CPU req/lim display -----
    if (( cpuReqM == 0 && cpuLimM == 0 )); then
      cpuReqLimStr="-"
    else
      cpuReqStr=$([[ $cpuReqM -eq 0 ]] && echo "-" || milli_to_str "$cpuReqM")
      cpuLimStr=$([[ $cpuLimM -eq 0 ]] && echo "-" || milli_to_str "$cpuLimM")
      cpuReqLimStr="${cpuReqStr}/${cpuLimStr}"
    fi

    # ----- MEM req/lim display -----
    if (( memReqMi == 0 && memLimMi == 0 )); then
      memReqLimStr="-"
    else
      memReqStr=$([[ $memReqMi -eq 0 ]] && echo "-" || mib_to_str "$memReqMi")
      memLimStr=$([[ $memLimMi -eq 0 ]] && echo "-" || mib_to_str "$memLimMi")
      memReqLimStr="${memReqStr}/${memLimStr}"
    fi

    # ----- Usage % -----
    den_cpu=$cpuReqM
    (( den_cpu == 0 && cpuLimM > 0 )) && den_cpu=$cpuLimM
    if (( den_cpu > 0 )); then
      cpuPctUse=$(( cpuUseM * 100 / den_cpu ))
    else
      cpuPctUse=0
    fi

    den_mem=$memReqMi
    (( den_mem == 0 && memLimMi > 0 )) && den_mem=$memLimMi
    if (( den_mem > 0 )); then
      memPctUse=$(( memUseMi * 100 / den_mem ))
    else
      memPctUse=0
    fi

    printf "  %-12s %-20s %-65s %-16s %-10s %-16s %-10s\n" \
      "$type" "$ns" "$pod" \
      "$cpuReqLimStr" "${cpuPctUse}%" \
      "$memReqLimStr" "${memPctUse}%"
  done

  echo
done
