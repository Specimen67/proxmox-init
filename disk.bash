set -euo pipefail

disk1="/dev/nvme0n1"
disk2="/dev/nvme1n1"

format_size() {
  numfmt --to=iec "$1"
}

size1=$(blockdev --getsize64 "$disk1")
size2=$(blockdev --getsize64 "$disk2")

# Le disque OS est le plus petit
if (( size1 > size2 )); then
  disk_os=$disk2
  disk_data=$disk1
else
  disk_os=$disk1
  disk_data=$disk2
fi

echo "Disque OS détecté : $disk_os ($(format_size $(blockdev --getsize64 "$disk_os")))"
echo "Disque Data détecté : $disk_data ($(format_size $(blockdev --getsize64 "$disk_data")))"

echo "Création d'une nouvelle partition LVM sur $disk_os avec fdisk..."

# Création partition primaire avec type Linux LVM (8e)
(
  echo n    # nouvelle partition
  echo      # primaire
  echo      # numéro de partition par défaut (prochain libre)
  echo      # premier secteur (défaut = premier libre)
  echo      # dernier secteur (défaut = fin disque)
  echo w    # écrire la table et quitter
) | fdisk "$disk_os"

sleep 2  # attendre que partition apparaisse

wipefs -a /dev/$disk_data
# Trouver la partition créée (numéro max)
partition_lvm=4
echo "Partition LVM créée : $partition_lvm"

echo "Création du Volume Group stockage-vm..."
vgcreate stockage-vm "$disk_os""p""$partition_lvm" "$disk_data"

echo "VG 'stockage-vm' créé avec succès."
vgdisplay stockage-vm
