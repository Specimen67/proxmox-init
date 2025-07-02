#!/bin/bash

zones_cfg="/etc/pve/sdn/zones.cfg"
vnets_cfg="/etc/pve/sdn/vnets.cfg"
sdn_iface_file="/etc/network/interfaces.d/sdn"

delete_zone() {
  local zone="$1"
  local file="$2"

  if grep -q "^vlan: $zone\$" "$file"; then
    start_line=$(grep -n "^vlan: $zone\$" "$file" | cut -d: -f1)
    next_line=$(tail -n +"$((start_line + 1))" "$file" | grep -n "^vlan:" | head -n1 | cut -d: -f1)

    if [ -z "$next_line" ]; then
      sed -i "${start_line},\$d" "$file"
    else
      end_line=$((start_line + next_line - 1))
      sed -i "${start_line},${end_line}d" "$file"
    fi

    echo "Zone SDN '$zone' supprimée proprement."
  else
    echo "Zone SDN '$zone' non trouvée."
  fi
}

remove_nodes_from_zone() {
  local zone="$1"
  local file="$2"
  local remove_nodes_csv="$3"

  local nodes_line
  nodes_line=$(sed -n "/^vlan: $zone\$/,/^vlan:/p" "$file" | grep "^        nodes ")

  if [ -z "$nodes_line" ]; then
    echo "La zone '$zone' s'applique actuellement tous les nœuds."
    read -p "Veuillez entrer la plage des nœuds actuellement dans la zone (ex: 1-8) : " node_range
    if [[ "$node_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      nodes_list=$(seq "$start" "$end" | xargs -I{} echo -n "pve{} ")
    else
      echo "Format invalide, utilisez par exemple : 1-8"
      exit 1
    fi

    IFS=' ' read -r -a full_nodes_arr <<< "$nodes_list"
    IFS=',' read -r -a remove_nodes_arr <<< "$remove_nodes_csv"
    new_nodes_arr=()
    for fn in "${full_nodes_arr[@]}"; do
      skip=0
      for rn in "${remove_nodes_arr[@]}"; do
        [[ "$fn" == "$rn" ]] && skip=1 && break
      done
      [[ $skip -eq 0 ]] && new_nodes_arr+=("$fn")
    done

    if [ ${#new_nodes_arr[@]} -eq 0 ]; then
      sed -i "/^vlan: $zone\$/,/^vlan:/ s/^        nodes .*\$//" "$file"
      echo "La liste de noeuds est vide, la zone '$zone' s'applique désormais à tous les nœuds."
      return
    fi

    new_nodes_csv=$(IFS=','; echo "${new_nodes_arr[*]}")

    if grep -q "^vlan: $zone\$" "$file"; then
      sed -i "/^vlan: $zone\$/,/^vlan:/ s/^        nodes .*\$//" "$file"
      sed -i "/^vlan: $zone\$/a\        nodes $new_nodes_csv" "$file"
      echo "Ligne 'nodes' ajoutée avec : $new_nodes_csv"
    else
      echo "Erreur : zone '$zone' introuvable pour ajouter la ligne nodes."
    fi

    echo "Nœuds $remove_nodes_csv retirés de la zone '$zone'. Nouvelle liste : $new_nodes_csv"

  else
    current_nodes=$(echo "$nodes_line" | sed "s/^[[:space:]]*nodes //")
    IFS=',' read -r -a current_nodes_arr <<< "$current_nodes"
    IFS=',' read -r -a remove_nodes_arr <<< "$remove_nodes_csv"

    new_nodes_arr=()
    for cn in "${current_nodes_arr[@]}"; do
      skip=0
      for rn in "${remove_nodes_arr[@]}"; do
        [[ "$cn" == "$rn" ]] && skip=1 && break
      done
      [[ $skip -eq 0 ]] && new_nodes_arr+=("$cn")
    done

    if [ ${#new_nodes_arr[@]} -eq 0 ]; then
      sed -i "/^vlan: $zone\$/,/^vlan:/ s/^        nodes .*\$//" "$file"
      echo "Tous les nœuds ont été retirés, ligne 'nodes' supprimée (zone s'applique à tous)."
    else
      new_nodes_csv=$(IFS=','; echo "${new_nodes_arr[*]}")
      sed -i "/^vlan: $zone\$/,/^vlan:/ s/^        nodes .*\$/        nodes $new_nodes_csv/" "$file"
      echo "Nœuds $remove_nodes_csv retirés. Nouvelle liste : $new_nodes_csv"
    fi
  fi
}

update_sdn_iface_on_node() {
  local node="$1"
  local iface_name="$2"
  local bridge_name="$3"
  local tag_vlan="$4"
  local mtu_val="$5"
  local vlan_aware="$6"

  local vlan_cfg=""
  if [[ "$vlan_aware" -eq 1 ]]; then
    vlan_cfg="        bridge-vlan-aware yes
        bridge-vids 2-4094"
  fi

  read -r -d '' iface_block <<EOF || true
auto $iface_name
iface $iface_name
        bridge_ports $bridge_name.$tag_vlan
        bridge_stp off
        bridge_fd 0
$vlan_cfg
        mtu $mtu_val

EOF

  if [[ "$node" == "$(hostname)" ]]; then
    sed -i "/^auto $iface_name\$/,/^$/d" "$sdn_iface_file"
    echo "$iface_block" >> "$sdn_iface_file"
    echo "[$node] Section $iface_name mise à jour localement dans $sdn_iface_file."
  else
    ssh -o StrictHostKeyChecking=accept-new root@"$node" bash -s <<EOF
sed -i "/^auto $iface_name\$/,/^$/d" "$sdn_iface_file"
cat >> "$sdn_iface_file" <<EOL
$iface_block
EOL
echo "[$node] Section $iface_name mise à jour via SSH dans $sdn_iface_file."
EOF
  fi
}

remove_sdn_iface_on_node() {
  local node="$1"
  local iface_name="$2"

  if [[ "$node" == "$(hostname)" ]]; then
    sed -i "/^auto $iface_name\$/,/^$/d" "$sdn_iface_file"
    echo "[$node] Section $iface_name supprimée localement dans $sdn_iface_file."
  else
    ssh -o StrictHostKeyChecking=accept-new root@"$node" bash -s <<EOF
sed -i "/^auto $iface_name\$/,/^$/d" "$sdn_iface_file"
echo "[$node] Section $iface_name supprimée via SSH dans $sdn_iface_file."
EOF
  fi
}

echo "Que voulez-vous gérer ?"
echo "1) Zone SDN"
echo "2) VNet SDN"
read -p "Choix (1 ou 2) : " resource_type

if [[ "$resource_type" != "1" && "$resource_type" != "2" ]]; then
  echo "Choix invalide."
  exit 1
fi

read -p "Souhaitez-vous (1) créer ou (2) supprimer ? (1/2) : " action

if [[ "$action" != "1" && "$action" != "2" ]]; then
  echo "Choix invalide."
  exit 1
fi

if [[ "$resource_type" == "1" ]]; then
  read -p "Nom de la zone SDN : " zone_name
  if [[ ! "$zone_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Nom de zone invalide (alphanumérique, -, _)."
    exit 1
  fi

  if [ "$action" == "1" ]; then
    read -p "Nom du bridge (ex: vmbr1) : " bridge_name
    read -p "MTU (ex: 9000) : " mtu_val
    read -p "Plage/hôtes concernés (ex: 7,8 ou 7-9 ou all) : " nodes_input

    if [[ "$nodes_input" == "all" ]]; then
      nodes="all"
    elif [[ "$nodes_input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
      nodes=$(seq "$start" "$end" | xargs -I{} echo -n "pve{}," )
      nodes="${nodes%,}"
    else
      IFS=',' read -ra arr <<< "$nodes_input"
      nodes=""
      for n in "${arr[@]}"; do
        n=$(echo "$n" | tr -d ' ')
        if [[ "$n" =~ ^pve[0-9]+$ ]]; then
          nodes+="$n,"
        elif [[ "$n" =~ ^[0-9]+$ ]]; then
          nodes+="pve$n,"
        else
          echo "Format de noeud invalide: $n"
          exit 1
        fi
      done
      nodes="${nodes%,}"
    fi

    sed -i "/^vlan: $zone_name\$/,/^vlan:/ { /^vlan: $zone_name\$/!{/^vlan:/!d} }" "$zones_cfg"

    {
      echo ""
      echo "vlan: $zone_name"
      echo "        bridge $bridge_name"
      echo "        ipam pve"
      echo "        mtu $mtu_val"
      if [[ "$nodes" != "all" ]]; then
        echo "        nodes $nodes"
      fi
    } >> "$zones_cfg"

    echo "Zone SDN '$zone_name' créée/modifiée avec succès."

  else
    read -p "Voulez-vous supprimer la zone entièrement (toutes les occurences) ? (o/n) : " full_del
    if [[ "$full_del" =~ ^[oO]$ ]]; then
      delete_zone "$zone_name" "$zones_cfg"
    else
      read -p "Liste des nœuds à retirer (ex: pve1,pve3) : " nodes_to_remove
      remove_nodes_from_zone "$zone_name" "$zones_cfg" "$nodes_to_remove"
    fi
  fi

elif [[ "$resource_type" == "2" ]]; then
  read -p "Nom du vnet (ex: v700) : " vnet_name
  if [[ ! "$vnet_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Nom de vnet invalide."
    exit 1
  fi

  if [ "$action" == "1" ]; then
    read -p "Zone associée : " zone_assoc

    bridge_name=$(sed -n "/^vlan: $zone_assoc\$/,/^vlan:/ { /^[[:space:]]*bridge / { s/^[[:space:]]*bridge //; p; q } }" "$zones_cfg")
    if [ -z "$bridge_name" ]; then
      echo "Erreur : zone '$zone_assoc' introuvable ou sans bridge défini."
      exit 1
    fi

    read -p "MTU (ex: 9000) : " mtu_val
    read -p "Le vnet doit-il être VLAN-aware ? (o/n) : " vlan_aware
    if [[ "$vlan_aware" =~ ^[oO]$ ]]; then
      vlanaware_val=1
      vlan_aware_cfg="        bridge-vlan-aware yes
        bridge-vids 2-4094"
    else
      vlanaware_val=0
      vlan_aware_cfg=""
    fi

    read -p "Tag VLAN (ex: 700) : " tag_vlan

    sed -i "/^vnet: $vnet_name\$/,/^vnet:/d" "$vnets_cfg"
    {
      echo ""
      echo "vnet: $vnet_name"
      echo "        zone $zone_assoc"
      echo "        tag $tag_vlan"
      echo "        vlanaware $vlanaware_val"
    } >> "$vnets_cfg"

    # Récupérer la liste des nœuds dans la zone
    nodes_line=$(sed -n "/^vlan: $zone_assoc\$/,/^vlan:/p" "$zones_cfg" | grep "^        nodes ")
    if [ -z "$nodes_line" ]; then
      read -p "Zone sans liste nodes. Entrez la plage des nœuds concernés (ex: 1-8) : " node_range
      if [[ "$node_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[2]}"
        nodes_list=$(seq "$start" "$end" | xargs -I{} echo -n "pve{} ")
      else
        echo "Format invalide, utilisez par exemple : 1-8"
        exit 1
      fi
    else
      nodes_list=$(echo "$nodes_line" | sed "s/^[[:space:]]*nodes //" | tr ',' ' ')
    fi

    for node in $nodes_list; do
      update_sdn_iface_on_node "$node" "$vnet_name" "$bridge_name" "$tag_vlan" "$mtu_val" "$vlanaware_val"
    done

  else
    # Suppression vnet
    start_line=$(grep -n "^vnet: $vnet_name\$" "$vnets_cfg" | cut -d: -f1)
    if [ -z "$start_line" ]; then
      echo "VNet '$vnet_name' non trouvé."
    else
      next_line=$(tail -n +$((start_line+1)) "$vnets_cfg" | grep -n "^vnet:" | head -n1 | cut -d: -f1)
      if [ -z "$next_line" ]; then
        sed -i "${start_line},\$d" "$vnets_cfg"
      else
        end_line=$((start_line + next_line -1))
        sed -i "${start_line},${end_line}d" "$vnets_cfg"
      fi
      echo "VNet '$vnet_name' supprimé dans $vnets_cfg."
    fi

    # Récupérer zone associée au vnet
    zone_of_vnet=$(sed -n "/^vnet: $vnet_name\$/,/^vnet:/p" "$vnets_cfg" | grep "^        zone " | sed "s/^[[:space:]]*zone //")
    if [ -n "$zone_of_vnet" ]; then
      nodes_line_zone=$(sed -n "/^vlan: $zone_of_vnet\$/,/^vlan:/p" "$zones_cfg" | grep "^        nodes ")
      if [ -z "$nodes_line_zone" ]; then
        read -p "Zone sans liste nodes. Entrez la plage des nœuds concernés (ex: 1-8) : " node_range
        if [[ "$node_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
          start="${BASH_REMATCH[1]}"
          end="${BASH_REMATCH[2]}"
          nodes_list=$(seq "$start" "$end" | xargs -I{} echo -n "pve{} ")
        else
          echo "Format invalide, utilisez par exemple : 1-8"
          exit 1
        fi
      else
        nodes_list=$(echo "$nodes_line_zone" | sed "s/^[[:space:]]*nodes //" | tr ',' ' ')
      fi

      for node in $nodes_list; do
        remove_sdn_iface_on_node "$node" "$vnet_name"
      done
    fi
  fi
fi

pvesh set /cluster/sdn && echo "Configuration SDN appliquée via pvesh."
