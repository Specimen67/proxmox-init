#!/bin/bash

local_hosts() {
    local HOSTS_DIR="/etc/hosts"

    cp "$SCRIPT_DIR/hosts/hosts" "$HOSTS_DIR"
}

remote_hosts() {
    local HOSTS_DIR="/etc/hosts"
    local start=$1
    local end=$2

    for ((i=start; i<=end; i++)); do
        if [[ "pve$i" != "$(hostname)" ]]; then
            scp "$SCRIPT_DIR/hosts/hosts" "root@pve$i:$HOSTS_DIR"
        fi
    done
}