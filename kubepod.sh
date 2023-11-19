#!/usr/bin/env bash

# Add it as a global executable
# curl -s https://raw.githubusercontent.com/JimCronqvist/ubuntu-scripts/master/kubepod.sh | sudo tee /usr/local/bin/kubepod >/dev/null && sudo chmod +x /usr/local/bin/kubepod

PODS=( $(kubectl get pods -A --template='{{range .items}}{{ .metadata.namespace }}/{{ .metadata.name }} {{ .status.phase }}{{printf "\n"}}{{end}}' | sort) )

while true; do
    CHOICE=$(whiptail --ok-button "Select" --cancel-button "Exit" --title "Manage Kubernetes Pods" --menu "Select a Pod" 0 0 0 "${PODS[@]}" 3>&2 2>&1 1>&3)
    if [[ -z "$CHOICE" ]]; then
        exit
    fi
    NAMESPACE=$(echo "$CHOICE" | cut -d'/' -f1)
    POD=$(echo "$CHOICE" | cut -d'/' -f2)

    INFO="\n"
    INFO+="Namespace: $NAMESPACE\n"
    INFO+="Pod: $POD\n"

    MODE=$(whiptail --noitem --ok-button "Select" --cancel-button "Back" --title "$POD" --menu "$INFO" 0 0 0 "exec" "" "logs" "" 3>&2 2>&1 1>&3)
    case $MODE in
        "exec")
            kubectl logs --tail 100 -n "$NAMESPACE" "$POD"
            echo ""
            echo "Logging in to the pod..."
            echo ""
            echo kubectl -it exec -n "$NAMESPACE" "$POD" -- sh -c "(bash || ash || sh)"
            kubectl -it exec -n "$NAMESPACE" "$POD" -- sh -c "(bash || ash || sh)"
            ;;
        "logs")
            kubectl logs --tail 500 --follow -n "$NAMESPACE" "$POD"
            ;;
    esac
done
