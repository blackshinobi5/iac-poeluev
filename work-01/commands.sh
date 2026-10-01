#!/usr/bin/env bash
# work-01/commands.sh
# Команды, которыми создавались и удалялись ресурсы в практике 1

export PREFIX=poeluev-05
export ZONE=ru-central1-b
export CIDR=10.15.1.0/24
export DISK_SIZE=20

# Сервисный аккаунт
yc iam service-account create --name "$PREFIX-sa"

export FOLDER_ID=$(yc config get folder-id)
export SA_ID=$(yc iam service-account get --name "$PREFIX-sa" --format json | jq -r .id)

yc resource-manager folder add-access-binding "$FOLDER_ID" \
  --role editor \
  --subject "serviceAccount:$SA_ID"

mkdir -p ~/.yc-keys
yc iam key create --service-account-name "$PREFIX-sa" \
  --output ~/.yc-keys/"$PREFIX"-key.json

# Своя сеть и подсеть
yc vpc network create --name "$PREFIX-net"

yc vpc subnet create \
  --name "$PREFIX-subnet" \
  --network-name "$PREFIX-net" \
  --zone "$ZONE" \
  --range "$CIDR"

# Вторая машина
yc compute instance create \
  --name "$PREFIX-web-1" \
  --zone "$ZONE" \
  --platform standard-v3 \
  --cores=2 \
  --core-fraction=20 \
  --memory=2 \
  --preemptible \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2404-lts,type=network-hdd,size="$DISK_SIZE" \
  --network-interface subnet-name="$PREFIX-subnet",nat-ip-version=ipv4 \
  --hostname "$PREFIX-web-1" \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --labels created-by=cli

# Привязка группы безопасности к интерфейсу
yc compute instance update-network-interface "$PREFIX-web-1" \
  --network-interface-index 0 \
  --security-group-id enpe86jt22no1ihecu5g

# Удаление ресурсов
yc compute instance delete "$PREFIX-web-1"
yc compute instance delete "$PREFIX-web-manual"
yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"
