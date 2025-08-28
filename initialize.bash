#!/bin/bash


step "Modification des fichiers hosts des PVE du cluster"
bash ajout_hosts.bash "1-$end"



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
if apt update && apt upgrade -y; then
  echo "Mise à jour terminée avec succès."
else
  echo "Erreur lors de la mise à jour locale."
  exit 1
fi

step "Suppression de la bannière no-subscription sur tous les nœuds"

sed -i.bak "s/.data.status.toLowerCase() !== 'active') {/.data.status.toLowerCase() !== 'active') { orig_cmd(); } else if ( false ) {/" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
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
  sed -i '/^iface enp3s0 inet manual/a\        mtu 9000' /etc/network/interfaces
  echo -e "\n$bridge_config" | tee -a /etc/network/interfaces > /dev/null
fi

ifup vmbr1 || echo "⚠️ Impossible de monter vmbr1 sur pve1"

for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Configuration du bridge vmbr1 sur $host"

  ssh root@"$host" "bash -c '
    if ! grep -q \"^auto vmbr1\" /etc/network/interfaces; then
      sed -i \"/^iface enp3s0 inet manual/a\\        mtu 9000\" /etc/network/interfaces
      cat <<EOF >> /etc/network/interfaces

auto vmbr1
iface vmbr1 inet manual
    bridge-ports enp3s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
    mtu 9000
EOF
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
sleep 15

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

pvesh set /cluster/sdn
sleep 15
echo "Configuration des vnets terminée."


step "creation du vg stockage-vm"
bash ./disk.bash

# Exécution distante sur les autres nœuds
for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Exécution sur $host via SSH"
  scp ./disk.bash root@"$host":/root/
  ssh root@"$host" bash /root/disk.bash
done


step "Ajout du stockage NFS ISO au cluster Proxmox"
STORAGE_CFG="/etc/pve/storage.cfg"
STORAGE_NAME="ISO"

cp ./storage.cfg /etc/pve/storage.cfg


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
  qm set $vmid --net0 virtio,bridge=vmbr0,mtu=1500,firewall=1
  qm set $vmid --net1 virtio,bridge=vmbr0,mtu=1500,firewall=1
  qm set $vmid --net2 virtio,bridge=v100,mtu=9000,firewall=1
  qm set $vmid --net3 virtio,bridge=v100,mtu=9000,firewall=1
  qm set $vmid --net4 virtio,bridge=v120,mtu=9000,firewall=1
done

for i in $(seq $start $end); do
  target_host="pve$i"
  for j in $(seq 1 3); do
    vmid="2${j}${i}"
    for net in $(seq 0 1); do
      ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --net$net virtio,bridge=vmbr0,mtu=1500,firewall=1"
    done
    for net in $(seq 2 3); do
      ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --net$net virtio,bridge=v${i}00,mtu=9000,firewall=1"
    done
    net=4
    case "$i" in
      1|2) 
        ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --net$net virtio,bridge=v120,mtu=9000,firewall=1"
        ;;
      3|4) 
        ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --net$net virtio,bridge=v340,mtu=9000,firewall=1"
        ;;
      5|6) 
        ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --net$net virtio,bridge=v560,mtu=9000,firewall=1"
        ;;
      7|8) 
        ssh -o StrictHostKeyChecking=accept-new "$target_host" "qm set $vmid --net$net virtio,bridge=v780,mtu=9000,firewall=1"
        ;;
    esac
  done
done
