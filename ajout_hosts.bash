# === Synchronisation /etc/hosts sur tous les hôtes via SSH ===

current_host=$(hostname)

read -p "Plage de nœuds à enregistrer dans /etc/hosts (ex: 1-8) : " host_range

# Vérification et extraction de la plage
if [[ "$host_range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
  start="${BASH_REMATCH[1]}"
  end="${BASH_REMATCH[2]}"
else
  echo "Format de plage invalide. Utilisez par exemple : 1-8"
  exit 1
fi

echo "🔧 Synchronisation de /etc/hosts sur tous les nœuds pve${start} à pve${end}..."

# Générer la liste des lignes à ajouter
declare -A host_lines

for i in $(seq "$start" "$end"); do
  host="pve$i"
  ip="192.168.67.20$i"
  host_lines["$host"]="$ip $host"
done

# Fonction pour injecter des lignes dans /etc/hosts d’un hôte cible
update_hosts_on_node() {
  node="$1"
  echo "🛠️  Connexion à $node..."

  for target in "${!host_lines[@]}"; do
    if [[ "$target" != "$node" ]]; then
      line="${host_lines[$target]}"
      ssh -o StrictHostKeyChecking=accept-new "$node" "grep -qF '$line' /etc/hosts || echo '$line' | tee -a /etc/hosts >/dev/null && echo 'Ajouté : $line'" || echo "❌ Erreur SSH vers $node"
    fi
  done
}

# Met à jour tous les hôtes (y compris local)
for i in $(seq "$start" "$end"); do
  node="pve$i"
  if [[ "$node" == "$current_host" ]]; then
    echo "🖥️  Mise à jour locale sur $node"
    for target in "${!host_lines[@]}"; do
      if [[ "$target" != "$node" ]]; then
        line="${host_lines[$target]}"
        grep -qF "$line" /etc/hosts || echo "$line" |  tee -a /etc/hosts >/dev/null && echo "Ajouté : $line"
      fi
    done
  else
    update_hosts_on_node "$node"
  fi
done
