#!/bin/bash

read -p "Nœud ou plage de nœuds à configurer (ex: 3 ou 1-8) : " host_input

if [[ "$host_input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
  start="${BASH_REMATCH[1]}"
  end="${BASH_REMATCH[2]}"
  hosts=$(seq "$start" "$end" | xargs -I{} echo "pve{}")
elif [[ "$host_input" =~ ^[0-9]+$ ]]; then
  hosts="pve$host_input"
elif [[ "$host_input" =~ ^pve[0-9]+$ ]]; then
  hosts="$host_input"
else
  echo "Format invalide. Entrez un numéro de nœud seul (ex: 3), une plage (ex: 1-8) ou un nom complet (ex: pve3)."
  exit 1
fi

read -p "Souhaitez-vous (1) créer ou (2) supprimer un bridge ? (1/2) : " action

read -p "Nom du bridge concerné (ex: vmbr1) : " bridge_name

if [[ "$action" == "1" ]]; then
  read -p "MTU du bridge (ex: 9000) : " bridge_mtu
  read -p "Le bridge doit-il être VLAN-aware ? (o/n) : " vlan_aware
  if [[ "$vlan_aware" =~ ^[oO]$ ]]; then
    vlan_config="    bridge-vlan-aware yes
    bridge-vids 2-4094"
  else
    vlan_config=""
  fi

  read -p "Souhaitez-vous attacher une interface physique au bridge ? (o/n) : " with_phys
  if [[ "$with_phys" =~ ^[oO]$ ]]; then
    read -p "Nom de l'interface physique (ex: enp3s0) : " phys_iface
  else
    phys_iface=""
  fi
fi

current_host=$(hostname)

for host in $hosts; do
  if [[ "$host" == "$current_host" ]]; then
    echo "🔧 Configuration locale sur $host"
    bash -s <<EOF

iface_file="/etc/network/interfaces"

if [[ "$action" == "1" ]]; then

  if [ -n "$phys_iface" ]; then
    # Appliquer immédiatement le MTU
    ip link set dev $phys_iface mtu $bridge_mtu

    # Gestion fiable du MTU dans le fichier interfaces
    iface_name="$phys_iface"
    mtu_val="$bridge_mtu"

    if grep -qE "^iface \$iface_name inet manual" "\$iface_file"; then
      if sed -n "/^iface \$iface_name inet manual/,/^iface /p" "\$iface_file" | grep -qE "^\s*mtu\s+[0-9]+"; then
        sed -i "/^iface \$iface_name inet manual/,/^iface / s/^\s*mtu\s\+[0-9]\+/    mtu \$mtu_val/" "\$iface_file"
      else
        sed -i "/^iface \$iface_name inet manual/a\\    mtu \$mtu_val" "\$iface_file"
      fi
    else
      cat <<EOC >> "\$iface_file"

auto \$iface_name
iface \$iface_name inet manual
    mtu \$mtu_val
EOC
    fi
  fi

  if ! grep -q "^auto $bridge_name" \$iface_file; then
    echo "" >> \$iface_file
    cat <<EOC >> \$iface_file
auto $bridge_name
iface $bridge_name inet manual
$( [ -n "$phys_iface" ] && echo "    bridge-ports $phys_iface" || echo "    bridge-ports none" )
    bridge-stp off
    bridge-fd 0
$vlan_config
    mtu $bridge_mtu
EOC
  fi

  ifup $bridge_name || echo "⚠️  Impossible de monter $bridge_name immédiatement. Vérifiez la config réseau."
  echo "[\$(hostname)] ✅ Bridge $bridge_name configuré avec MTU $bridge_mtu"

else

  if grep -q "^auto $bridge_name" \$iface_file; then
    sed -i "/^auto $bridge_name/,/^auto / { /^auto /!d; /^auto $bridge_name/d; }" \$iface_file
    sed -i "/^auto $bridge_name$/d" \$iface_file

    ifdown $bridge_name 2>/dev/null || true
    echo "[\$(hostname)] 🗑️ Bridge $bridge_name supprimé."
  else
    echo "[\$(hostname)] ⚠️  Bridge $bridge_name introuvable."
  fi

fi

EOF
  else
    echo "🌐 SSH vers $host"
    ssh -o StrictHostKeyChecking=accept-new root@$host bash -s <<EOF

iface_file="/etc/network/interfaces"

if [[ "$action" == "1" ]]; then

  if [ -n "$phys_iface" ]; then
    ip link set dev $phys_iface mtu $bridge_mtu

    iface_name="$phys_iface"
    mtu_val="$bridge_mtu"

    if grep -qE "^iface \$iface_name inet manual" "\$iface_file"; then
      if sed -n "/^iface \$iface_name inet manual/,/^iface /p" "\$iface_file" | grep -qE "^\s*mtu\s+[0-9]+"; then
        sed -i "/^iface \$iface_name inet manual/,/^iface / s/^\s*mtu\s+[0-9]+/    mtu \$mtu_val/" "\$iface_file"
      else
        sed -i "/^iface \$iface_name inet manual/a\\    mtu \$mtu_val" "\$iface_file"
      fi
    else
      cat <<EOC >> "\$iface_file"

auto \$iface_name
iface \$iface_name inet manual
    mtu \$mtu_val
EOC
    fi
  fi

  if ! grep -q "^auto $bridge_name" \$iface_file; then
    echo "" >> \$iface_file
    cat <<EOC >> \$iface_file
auto $bridge_name
iface $bridge_name inet manual
$( [ -n "$phys_iface" ] && echo "    bridge-ports $phys_iface" || echo "    bridge-ports none" )
    bridge-stp off
    bridge-fd 0
$vlan_config
    mtu $bridge_mtu
EOC
  fi

  ifup $bridge_name || echo "⚠️  Impossible de monter $bridge_name immédiatement. Vérifiez la config réseau."
  echo "[\$(hostname)] ✅ Bridge $bridge_name configuré avec MTU $bridge_mtu"

else

  if grep -q "^auto $bridge_name" \$iface_file; then
    sed -i "/^auto $bridge_name/,/^auto / { /^auto /!d; /^auto $bridge_name/d; }" \$iface_file
    sed -i "/^auto $bridge_name$/d" \$iface_file

    ifdown $bridge_name 2>/dev/null || true
    echo "[\$(hostname)] 🗑️ Bridge $bridge_name supprimé."
  else
    echo "[\$(hostname)] ⚠️  Bridge $bridge_name introuvable."
  fi

fi

EOF
  fi
done
