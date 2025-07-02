#!/bin/bash

# Fonction de parsing des ID (VM ou disques)
parse_ids() {
  input=$1
  result=""

  for part in $input; do
    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      start=$(echo "$part" | cut -d'-' -f1)
      end=$(echo "$part" | cut -d'-' -f2)
      result+=" $(seq $start $end)"
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      result+=" $part"
    else
      echo "Entrée invalide : $part"
      exit 1
    fi
  done

  echo $result
}

# Choix de l'action
echo "Que voulez-vous faire ?"
echo "1) Ajouter un disque"
echo "2) Supprimer un disque"
read -p "Choix (1 ou 2) : " action

if [[ "$action" != "1" && "$action" != "2" ]]; then
  echo "Choix invalide. Veuillez entrer 1 pour ajouter ou 2 pour supprimer."
  exit 1
fi

# === AJOUT DE DISQUES ===
if [ "$action" -eq 1 ]; then
  read -p "Quel(s) ID de VM sont concernés ? (ex: 103-105 ou 103 104) : " vm_input
  vm_list=$(parse_ids "$vm_input")

  read -p "Quel(s) ID de disque SCSI voulez-vous utiliser ? (ex: 0-2 ou 0 1) : " disk_input
  disk_list=$(parse_ids "$disk_input")

  read -p "Nom du stockage (ex: stockage-vm) : " storage
  read -p "Nombre de disques à créer par VM : " disk_count

  if [ "$disk_count" -gt 1 ]; then
    read -p "Tous les disques auront-ils la même taille ? (o/n) : " same_size
  else
    same_size="o"
  fi

  declare -A size_map

  if [[ "$same_size" =~ ^[oO]$ ]]; then
    read -p "Taille (en GiB) commune à tous les disques : " size
    for diskid in $disk_list; do
      size_map[$diskid]=$size
    done
  else
    for diskid in $disk_list; do
      read -p "Taille du disque scsi$diskid (en GiB) : " size
      size_map[$diskid]=$size
    done
  fi

  for vmid in $vm_list; do
    for diskid in $disk_list; do
      current_size=${size_map[$diskid]}
      echo "Ajout de scsi$diskid à la VM $vmid : ${current_size}G sur $storage"
      qm set "$vmid" --scsi$diskid "${storage}:${current_size},discard=on,ssd=1"
    done
  done

# === SUPPRESSION DE DISQUES ===
elif [ "$action" -eq 2 ]; then
  read -p "Quel(s) ID de VM sont concernés ? (ex: 103-105 ou 103 104 105) : " vm_input
  vm_list=$(parse_ids "$vm_input")

  read -p "Quel(s) ID de disque SCSI sont concernés ? (ex: 0-4 ou 0 1 2 3 4) : " disk_input
  disk_list=$(parse_ids "$disk_input")

  for vmid in $vm_list; do
    for diskid in $disk_list; do
      echo "Suppression de scsi$diskid sur VM $vmid"
      qm set "$vmid" -delete "scsi$diskid" -force 1
    done
  done
fi


