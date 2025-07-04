#!/bin/bash

# Rediriger la sortie vers un fichier log tout en affichant les grandes lignes
exec > >(tee -a /var/log/proxmox-lab-setup.log) 2>&1

# Fonction d'affichage des grandes étapes
declare -i STEP_NUM=1
step() {
  echo -e "\n\033[1;34m[$STEP_NUM] 🔷 $1\033[0m"
  STEP_NUM+=1
}

start=2
end=1

for i in {2..8}; do
  ip="192.168.67.20$i"
  if ping -c 1 -W 1 "$ip" > /dev/null 2>&1; then
    echo "Nœud détecté : $ip"
    end=$i
  fi

done

if [[ $end -lt $start ]]; then
  echo " Aucun nœud détecté dans la plage 202 à 208."
  exit 1
fi

node_range="$start-$end"
echo "Plage de nœuds détectée : $node_range"

step "Création du cluster"
pvecm create Dawan

#step "Lecture de la plage des nœuds"
#read -p "Plage des nœuds à ajouter (par défaut: 1-8) [1-8] : " node_range
#node_range=${node_range:-1-8}

#if [[ ! "$node_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
#  echo "Format invalide, utilisez par exemple : 1-8"
#  exit 1
#fi

#start=${BASH_REMATCH[1]}
#end=${BASH_REMATCH[2]}

step "Ajout des nœuds au cluster via expect"
for i in $(seq "$start" "$end"); do
  ip="192.168.67.2$i"
  echo "Ajout du nœud $ip"
  ./join_node.expect "$ip"
done

step "Modification des fichiers hosts des PVE du cluster"
bash ajout_hosts.bash "1-$end"

#step "Copie des sources.list.d"
SRC_DIR="./sources.list.d"
DEST_DIR="/etc/apt/sources.list.d/"

echo "Copie du dossier $SRC_DIR vers $DEST_DIR"
sudo cp -r "$SRC_DIR"/* "$DEST_DIR"

for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Copie vers $host"
  scp -r "$SRC_DIR"/* root@"$host":"$DEST_DIR"
done

echo 'Acquire::http { Proxy "http://192.168.67.181:3142"; }' > /etc/apt/apt.conf.d/99cache-proxy
for i in $(seq $start $end); do
  ssh pve$i "cat > /etc/apt/apt.conf.d/99cache-proxy <<EOF
Acquire::http { Proxy \"http://192.168.67.181:3142\"; }
EOF"
done

step "Mise à jour des nœuds distants en arrière-plan"
for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Lancement de la mise à jour sur $host en arrière-plan"
  ssh root@"$host" "nohup bash -c 'apt update && apt upgrade -y > /var/log/maj.log 2>&1' >/dev/null 2>&1 &"
done

step "Mise à jour locale"
if sudo apt update && sudo apt upgrade -y; then
  echo "Mise à jour terminée avec succès."
else
  echo "Erreur lors de la mise à jour locale."
  exit 1
fi

step "Suppression de la bannière no-subscription sur tous les nœuds"

sed -i.bak "s/.data.status.toLowerCase() !== 'active') {/.data.status.toLowerCase() !== 'active') { orig_cmd(); } else if ( false ) {/" /u>
systemctl restart pveproxy.service

for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Exécution suppression bannière sur $host..."
  ssh root@"$host" bash -s <<'EOF'
sed -i.bak "s/.data.status.toLowerCase() !== 'active') {/.data.status.toLowerCase() !== 'active') { orig_cmd(); } else if ( false ) {/" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
systemctl restart pveproxy.service
EOF
done

step "Création des bridge sur les noeuds"
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

if ! grep -q "^auto vmbr1" /etc/network/interfaces; then
  echo -e "\n$bridge_config" | sudo tee -a /etc/network/interfaces > /dev/null
fi
sudo ifup vmbr1 || echo "⚠️ Impossible de monter vmbr1 sur $host"

for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Configuration du bridge vmbr1 sur $host"
  ssh root@"$host" bash -c "'
    if ! grep -q \"^auto vmbr1\" /etc/network/interfaces; then
      echo -e \"\n$bridge_config\" | tee -a /etc/network/interfaces > /dev/null
    fi
    ifup vmbr1 || echo \"⚠️ Impossible de monter vmbr1 sur $host\"
  '"
done

step "Création de la zone SDN"
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

step "Création des Vnets"
vnets_cfg="/etc/pve/sdn/vnets.cfg"
interfaces_cfg_local="/etc/network/interfaces.d/sdn"

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

step "Création des vnets dans la plage"
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


step "creation du vg stockage-vm"
bash ./disks.bash

# Exécution distante sur les autres nœuds
for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Exécution sur $host via SSH"
  scp ./disks.bash root@"$host":/root/
  ssh root@"$host" bash /root/disks.bash
done


step "Ajout du stockage NFS ISO au cluster Proxmox"
STORAGE_CFG="/etc/pve/storage.cfg"
STORAGE_NAME="ISO"

# Vérifie si le bloc existe déjà
if grep -q "^nfs: $STORAGE_NAME" "$STORAGE_CFG"; then
  echo "Le stockage '$STORAGE_NAME' est déjà présent dans storage.cfg"
else
  echo "Ajout du stockage NFS '$STORAGE_NAME' à $STORAGE_CFG"

  cat <<EOF >> "$STORAGE_CFG"

nfs: $STORAGE_NAME
        export /mnt/ISO
        path /mnt/pve/ISO
        server 192.168.67.181
        content vztmpl,iso
        prune-backups keep-all=1
EOF

  echo "Stockage '$STORAGE_NAME' ajouté avec succès."
fi


step "Copie du template 100"
cp ./100.conf /etc/pve/nodes/pve1/qemu-server/100.conf

step "Clonage des VM"
echo "Clonage des VM sur pve1"

for i in $(seq 1 3); do
  vmid="2${i}1"
  name="pve${i}1"
  qm clone 100 "$vmid" --name "$name" --target pve1
done

# Clonage des VM sur les autres noeuds

for i in $(seq $start $end); do
  echo "Clonage des VM sur pve$i"
  for j in $(seq 1 3); do
    vmid="2${j}${i}"
    name="pve${j}${i}"
    qm clone 100 "$vmid" --name "$name" --target pve$i
  done
done

step "Ajout des disques de VM"
# Ajout des disques aux VM de pve1

options=",discard=on,ssd=1,iothread=1"
for i in $(seq 1 3); do
  scsi=0
  for val in 50 100 100 150; do
    vmid="2${i}1"
    taille="$val"
    qm set $vmid --scsi$scsi stockage-vm:$taille$options
    scsi=$((scsi + 1))
    if [ "$i" -eq 1 ] && [ "$scsi" -eq 3 ]; then
      for sup in $(seq 4 13); do
        qm set $vmid --scsi$sup stockage-vm:10$options
      done
    fi
  done
done

# Ajout des disques aux VM des autres PVE
for i in $(seq $start $end); do
  for j in $(seq 1 3); do
    scsi=0
    for val in 50 100 100 150; do
      vmid="2${j}${i}"
      taille="$val"
      target_host="pve$i"
      ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm status $vmid &>/dev/null" || continue
      echo "Ajout de scsi$scsi à VM $vmid via $target_host"
      ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --scsi$scsi stockage-vm:$taille$options"
      if [ "$j" -eq 1 ] && [ "$scsi" -eq 3 ]; then
        for sup in $(seq 4 13); do
          ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm status $vmid &>/dev/null" || continue
          echo "Ajout de scsi$scsi à VM $vmid via $target_host"
          ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --scsi$sup stockage-vm:10$options"
        done
      fi
    scsi=$((scsi + 1))
    done
  done
done

step "ajout des réseaux aux VM"

for i in $(seq 1 3); do
  vmid="2${i}1"
  qm set $vmid --net0 bridge=vmbr0,mtu=1500,firewall=1
  qm set $vmid --net1 bridge=vmbr0,mtu=1500,firewall=1
  qm set $vmid --net2 bridge=v100,mtu=9000,firewall=1
  qm set $vmid --net3 bridge=v100,mtu=9000,firewall=1
  qm set $vmid --net4 bridge=v120,mtu=9000,firewall=1
done

for i in $(seq $start $end); do
  target_host="pve$i"
  for j in $(seq 1 3); do
    vmid="2${j}${i}"
    for net in $(seq 0 1); do
      ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --net$net bridge=vmbr0,mtu=1500,firewall=1"
    done
    for net in $(seq 2 3); do
      ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --net$net bridge=v${i}00,mtu=9000,firewall=1"
    done
    net=4
    case "$i" in
      1|2 
        ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --net$net bridge=v120,mtu=9000,firewall=1"
        ;;
      3|4 
        ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --net$net bridge=v340,mtu=9000,firewall=1"
        ;;
      5|6 
        ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --net$net bridge=v560,mtu=9000,firewall=1"
        ;;
      7|8 
        ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --net$net bridge=v780,mtu=9000,firewall=1"
        ;;
    esac
  done
done
