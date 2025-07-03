#!/bin/bash

# Création du cluster
pvecm create Dawan

# Lecture de la plage des nœuds
read -p "Plage des nœuds à ajouter (par défaut: 1-8) [1-8] : " node_range
node_range=${node_range:-1-8}

if [[ ! "$node_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
  echo "Format invalide, utilisez par exemple : 1-8"
  exit 1
fi

start=${BASH_REMATCH[1]}
end=${BASH_REMATCH[2]}

# Ajout des nœuds au cluster via expect
for i in $(seq "$start" "$end"); do
  ip="192.168.67.2$i"
  echo "Ajout du nœud $ip"
  ./join_node.expect "$ip"
done

# Modification des fichiers hosts des PVE du cluster
bash ajout_hosts.bash "$node_range"

# Copie des sources.list.d localement et sur les nœuds distants
SRC_DIR="./sources.list.d"
DEST_DIR="/etc/apt/sources.list.d/"

echo "Copie locale du dossier $SRC_DIR vers $DEST_DIR"
sudo cp -r "$SRC_DIR"/* "$DEST_DIR"

for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Copie vers $host"
  scp -r "$SRC_DIR"/* root@"$host":"$DEST_DIR"
done

# Mise à jour des nœuds distants en arrière-plan
for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Lancement de la mise à jour sur $host en arrière-plan"
  ssh root@"$host" "nohup bash -c 'apt update && apt upgrade -y > /var/log/maj.log 2>&1' >/dev/null 2>&1 &"
done

# Mise à jour locale (attente)
echo "Mise à jour locale..."
if sudo apt update && sudo apt upgrade -y; then
  echo "Mise à jour terminée avec succès."
else
  echo "Erreur lors de la mise à jour locale."
  exit 1
fi

# Suppression de la bannière no-subscription sur tous les nœuds
local_host=$(hostname)

for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Exécution suppression bannière sur $host..."

  if [[ "$host" == "$local_host" ]]; then
    # Exécution locale
    sed -i.bak "s/.data.status.toLowerCase() !== 'active') {/.data.status.toLowerCase() !== 'active') { orig_cmd(); } else if ( false ) {/" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
    systemctl restart pveproxy.service

    if [ $? -eq 0 ]; then
      echo "✔ Commandes exécutées avec succès sur $host"
    else
      echo "✘ Erreur lors de l'exécution locale sur $host"
    fi
  else
    # Exécution distante via SSH
    ssh root@"$host" bash -s <<'EOF'
sed -i.bak "s/.data.status.toLowerCase() !== 'active') {/.data.status.toLowerCase() !== 'active') { orig_cmd(); } else if ( false ) {/" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
systemctl restart pveproxy.service
EOF

    if [ $? -eq 0 ]; then
      echo "✔ Commandes exécutées avec succès sur $host"
    else
      echo "✘ Erreur lors de l'exécution sur $host"
    fi
  fi
done

# Création des bridge sur les noeuds
for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Configuration du bridge vmbr1 sur $host"

  bridge_config=$(cat <<EOF
auto vmbr1
iface vmbr1 inet manual
    bridge-ports enp3s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
    mtu 9000
EOF
  )

  if [[ "$host" == "$local_host" ]]; then
    # Exécution locale
    if ! grep -q "^auto vmbr1" /etc/network/interfaces; then
      echo -e "\n$bridge_config" | sudo tee -a /etc/network/interfaces > /dev/null
    fi
    sudo ifup vmbr1 || echo "⚠️ Impossible de monter vmbr1 sur $host"
  else
    # Exécution distante via SSH
    ssh root@"$host" bash -c "'
      if ! grep -q \"^auto vmbr1\" /etc/network/interfaces; then
        echo -e \"\n$bridge_config\" | tee -a /etc/network/interfaces > /dev/null
      fi
      ifup vmbr1 || echo \"⚠️ Impossible de monter vmbr1 sur $host\"
    '"
  fi
done

# Création de la zone SDN
zone_name="VLAN"
bridge_name="vmbr1"
mtu_val=9000

cat <<EOF >> /etc/pve/sdn/zones.cfg

vlan: $zone_name
    bridge $bridge_name
    ipam pve
    mtu $mtu_val
EOF
pvesh set /cluster/sdn

# Création des Vnets
vnets_cfg="/etc/pve/sdn/vnets.cfg"
interfaces_cfg_local="/etc/network/interfaces.d/sdn"

local_host=$(hostname)

# Vider les fichiers avant écriture
> "$vnets_cfg"
> "$interfaces_cfg_local"

add_vnet() {
  local vnet_name=$1
  local tag=$2

  cat >> "$vnets_cfg" <<EOF
vnet: $vnet_name
    zone $zone_name
    tag $tag
    vlanaware 1

EOF

  cat >> "$interfaces_cfg_local" <<EOF
auto $vnet_name
iface $vnet_name
    bridge_ports $bridge.$tag
    bridge_stp off
    bridge_fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
    mtu $mtu

EOF
}

# Création des vnets dans la plage
for i in $(seq "$start" "$end"); do
  vnet_name="v${i}00"
  tag="${i}00"
  add_vnet "$vnet_name" "$tag"
done

# Ajout des vnets spécifiques
for vnet in v120 v340 v560 v780; do
  tag=${vnet:1}
  add_vnet "$vnet" "$tag"
done


# Synchroniser le fichier interfaces.d/sdn sur les nœuds distants
for i in $(seq "$start" "$end"); do
  host="pve$i"
  if [[ "$host" == "$local_host" ]]; then
    echo " - $host (local) : pas de copie nécessaire"
  else
    echo "Copie du fichier interfaces.d/sdn vers $host"
    scp "$interfaces_cfg_local" root@"$host":"$interfaces_cfg_local"
  fi
done

echo "Configuration des vnets terminée."


# creation du vg stockage-vm
# Exécution locale (supposons local_host = pve1)
echo "Exécution locale sur $local_host"
bash ./disks.bash

# Exécution distante sur les autres nœuds
for i in $(seq "$start" "$end"); do
  host="pve$i"
  if [[ "$host" == "$local_host" ]]; then
    echo "Skipping local host $host (already done)"
    continue
  fi
  echo "Exécution sur $host via SSH"
  scp ./disks.bash root@"$host":/root/
  ssh root@"$host" bash /root/disks.bash
done


