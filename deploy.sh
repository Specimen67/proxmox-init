#!/bin/bash
set -eu  # stop sur erreur et variable non définie

# Variables globales
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/proxmox-lab-setup.log"
IP_SITE="192.168.67.20"
FQDN=".strasbourg.dawan.fr"
ROOT_PASS="proxmoxx"

source "$SCRIPT_DIR/lib/scan.sh" #scan des PVE disponibles.
source "$SCRIPT_DIR/lib/repositories.sh" #Modification des dépôts
source "$SCRIPT_DIR/lib/hosts_file.sh" #Modification du fichier hosts
source "$SCRIPT_DIR/lib/cluster_and_nodes.sh" #Fonctions de configuration du cluster et des noeuds.


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
    local start=0 end=-1 nb_pve=0

    step "Scan des hôtes disponibles"
    pve_scan start end nb_pve
    ok "$nb_pve hôtes détectés."

    step "Copie des sources.list.d"
    copie_source_list
    ok "ok."

    step "Création du cluster."
    create_cluster
    ok "Cluster Dawan créé"
    
    step "Installation de sshpass pour les commandes distantes."
    apt update && apt install sshpass -y #Installation de sshpass pour les commandes distantes.
    ok "ok."

    step "Remplissage du fichier hosts local."
    local_hosts
    ok "ok."

    step "Copie de la clé ssh vers les noeuds distants."
    copy_rsa "$start" "$end"
    ok "ok."

    step "Copie du fichier hosts sur les noeuds distants."
    remote_hosts "$start" "$end"
    ok "ok."

    step "Ajout des hôtes au cluster Dawan"
    add_host "$start" "$end"
    ok "ok."


}

main "$@"
exec 3>&-