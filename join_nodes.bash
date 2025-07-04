#!/bin/bash

# Vérification des arguments
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <IP_DU_NOEUD>"
  exit 1
fi

NODE_IP="$1"
MASTER_IP="192.168.67.201"
ROOT_PASS="proxmoxx"

# 1. Génération de clé SSH si absente
if [[ ! -f /root/.ssh/id_rsa ]]; then
  ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa
fi

# 2. Ajouter StrictHostKeyChecking une seule fois
grep -q "StrictHostKeyChecking accept-new" /root/.ssh/config 2>/dev/null || \
  echo "StrictHostKeyChecking accept-new" >> /root/.ssh/config

# 3. Installer sshpass si nécessaire
if ! command -v sshpass >/dev/null; then
  apt install -y sshpass
fi

# 4. Copier la clé publique vers le nœud distant
echo "🔐 Copie de la clé SSH vers $NODE_IP"
sshpass -p "$ROOT_PASS" ssh-copy-id -o StrictHostKeyChecking=accept-new root@"$NODE_IP" >/dev/null

# 5. Connexion SSH au nœud et exécution du join
echo "🤝 Connexion à $NODE_IP et ajout au cluster"
ssh root@"$NODE_IP" bash -s <<EOF
set -e

# Prévenir les vérifications interactives
echo "StrictHostKeyChecking accept-new" >> /root/.ssh/config

# Installer sshpass si besoin
if ! command -v sshpass >/dev/null; then
  apt update && apt install -y sshpass
fi

# Ajouter la clé du nœud au master
cat /root/.ssh/id_rsa.pub | sshpass -p "$ROOT_PASS" ssh -o StrictHostKeyChecking=accept-new root@$MASTER_IP 'cat >> /root/.ssh/authorized_keys'

# Ajouter au cluster
pvecm add $MASTER_IP --use_ssh 1
EOF
