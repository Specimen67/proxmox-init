#!/bin/bash

pve_scan() {
    local -n start_ref=$1
    local -n end_ref=$2
    local -n nb_pve_ref=$3
    for i in {1..8}; do
        ip="$IP_SITE$i"
        if ping -c 1 -W 1 "$ip" > /dev/null 2>&1; then
            if [[ "$start_ref" -eq 0 ]]; then
                start_ref="$i"
            fi
            info "Nœud détecté : $ip"
            end_ref=$i
            nb_pve_ref=$((nb_pve_ref+1))
        fi
    done


    if [[ $end_ref -lt $start_ref ]]; then
        fail  "Aucun nœud détecté."
        exit 1
    fi
}