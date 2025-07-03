#!/bin/bash

# Création du cluster
pvecm create Dawan

# Ajout des hôtes
read -p "Plage des nœuds à ajouter (par défaut: 1-8) [1-8] : " node_range
node_range=${node_range:-1-8}

if [[ ! "$node_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
  echo "Format invalide, utilisez par exemple : 1-8"
  exit 1
fi

start=${BASH_REMATCH[1]}
end=${BASH_REMATCH[2]}

for i in $(seq "$start" "$end"); do
  ip="192.168.67.2$i"
  echo "Ajout du nœud $ip"
  ./join_node.expect "$ip"
done

# Modification des fichiers hosts des pve du cluster
bash ajout_hosts.bash node_range

# Modification des sources list
start=${node_range%-*}
end=${node_range#*-}

SRC_DIR="./sources.list.d"
DEST_DIR="/etc/apt/sources.list.d/"

echo "Copie locale du dossier $SRC_DIR vers $DEST_DIR"
sudo cp -r "$SRC_DIR"/* "$DEST_DIR"

for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Copie vers $host"
  scp -r "$SRC_DIR"/* root@"$host":"$DEST_DIR"
done

# Mise à jour des hôtes
start=${node_range%-*}
end=${node_range#*-}

for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Lancement de la mise à jour sur $host en arrière-plan"
  ssh root@"$host" "nohup bash -c 'apt update && apt upgrade -y > /var/log/maj.log 2>&1' >/dev/null 2>&1 &"
done

echo "Mise à jour en local..."
if sudo apt update && sudo apt upgrade -y; then
  echo "Mise à jour terminée avec succès."
else
  echo "Erreur lors de la mise à jour locale."
  exit 1
fi

#retrait de la bannière no-subscription
#!/bin/bash

# Supposons que node_range est déjà définie, ex: "1-8"
start=${node_range%-*}
end=${node_range#*-}

local_host=$(hostname)

for i in $(seq "$start" "$end"); do
  host="pve$i"
  echo "Exécution sur $host..."

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
