#!/bin/bash

create_cluster() {
    pvecm create Dawan
}

copy_rsa() {
    local PVKEY_RSA_DIR="/root/.ssh/id_rsa"
    local CONFIG_DIR="/root/.ssh/config"
    local start=$1
    local end=$2

    if [[ ! -f "$PVKEY_RSA_DIR" ]]; then
        ssh-keygen -t rsa -N "" -f "$PVKEY_RSA_DIR" #Génération de la paire de clé
    fi

    cp "$SCRIPT_DIR/ssh/config" "$CONFIG_DIR"

    for ((i=start; i<=end; i++)); do
        if [[ "pve$i" != "$(hostname)" ]]; then
            info "Copie de la clé vers pve$i"
            sshpass -p "$ROOT_PASS" ssh-copy-id  root@pve$i #Copie de la clé SSH sur les noeuds distants
        fi
    done
}

add_host() {
    local PBKEY_RSA_DIR="/root/.ssh/id_rsa.pub"
    local PVKEY_RSA_DIR="/root/.ssh/id_rsa"
    local AUTHORIZED_DIR="/etc/pve/priv/authorized_keys"
    local start=$1
    local end=$2
    local PUBKEY
    local MASTER_PVE=$(hostname)
    local CONFIG_DIR="/root/.ssh/config"

    for ((i=start; i<=end; i++)); do
        if [[ "pve$i" != "$(hostname)" ]]; then
            info "Ajout de pve$i..."
            ssh root@pve$i "test -f $PVKEY_RSA_DIR || ssh-keygen -t rsa -N '' -f $PVKEY_RSA_DIR"
            scp "$SCRIPT_DIR/ssh/config" "root@pve$i:$CONFIG_DIR"
            PUBKEY="$(ssh root@pve$i cat $PBKEY_RSA_DIR)"
            grep -qxF "$PUBKEY" "$AUTHORIZED_DIR" || echo "$PUBKEY" >> "$AUTHORIZED_DIR"
            ssh root@"pve$i" "pvecm add '$MASTER_PVE' --use_ssh 1"
            info "Ok."
        fi
    done
}