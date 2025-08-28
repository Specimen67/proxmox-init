#!/bin/bash
set -eu  # stop sur erreur et variable non définie

# Variables globales
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/proxmox-lab-setup.log"

source "$SCRIPT_DIR/lib/scan.sh" #scan des PVE disponibles.
source "$SCRIPT_DIR/lib/repositories.sh" #Modification des dépôts
source "$SCRIPT_DIR/lib/hosts_file.sh" #Modification du fichier hosts


mkdir -p "$(dirname "$LOG_FILE")"
exec 3>&1
exec 1>>"$LOG_FILE" 2>&1

declare -i STEP_NUM=1
step()  { echo -e "\n\033[1;34m[$STEP_NUM] 🔷 $*\033[0m" >&3; STEP_NUM+=1; }
info()  { echo -e "  ▸ $*" >&3; }
ok()    { echo -e "  \033[1;32m✓ $*\033[0m" >&3; }
warn()  { echo -e "  \033[1;33m! $*\033[0m" >&3; }
fail()  { echo -e "  \033[1;31m✗ $*\033[0m" >&3; }

main() {
    #Variables locales
    local start=-1 end=0 nb_pve=0

    step "Scan des hôtes disponibles"
    pve_scan start end nb_pve

    step "Copie des sources.list.d"
    copie_source_list
    ok "ok."

    step "Création du cluster"
    pvecm create Dawan
    ok "Cluster Dawan créé"
    
    step "Installation de sshpass pour les commandes distantes."
    apt update && apt install sshpass #Installation de sshpass pour les commandes distantes.
    ok "ok."

    step Remplissage du fichier hosts local
    local_hosts "$start" "$end"


}

main "$@"
exec 3>&-