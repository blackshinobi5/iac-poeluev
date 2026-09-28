#!/usr/bin/env bash
set -e

PREFIX=poeluev-05
ZONE=ru-central1-b
CIDR=10.15.1.0/24
DISK_SIZE=20
PORT=8015
IMAGE_FAMILY=debian-12

yc vpc network create --name "$PREFIX-net2"
yc vpc subnet create --name "$PREFIX-subnet2" \
  --network-name "$PREFIX-net2" --zone "$ZONE" --range "$CIDR"

SG_ID=$(yc vpc security-group list --format json \
  | jq -r --arg net "$(yc vpc network get "$PREFIX-net2" --format json | jq -r .id)" \
    '.[] | select(.network_id == $net) | .id')

yc vpc security-group update-rules "$SG_ID" \
  --add-rule "direction=ingress,port=22,protocol=tcp,v4-cidrs=[0.0.0.0/0]" \
  --add-rule "direction=ingress,port=$PORT,protocol=tcp,v4-cidrs=[0.0.0.0/0]"

for i in 1 2; do
  yc compute instance create \
    --name "$PREFIX-app-$i" \
    --zone "$ZONE" \
    --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$DISK_SIZE" \
    --network-interface subnet-name="$PREFIX-subnet2",nat-ip-version=ipv4,security-group-ids="$SG_ID" \
    --hostname "$PREFIX-app-$i" \
    --ssh-key ~/.ssh/id_ed25519.pub \
    --labels created-by=script

  sleep 20

  IP=$(yc compute instance get "$PREFIX-app-$i" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')

  ssh -o StrictHostKeyChecking=accept-new yc-user@"$IP" bash -s <<EOF
    sudo apt update && sudo apt install -y nginx
    sudo sed -i "s/listen 80 default_server;/listen $PORT default_server;/" /etc/nginx/sites-enabled/default
    sudo sed -i "s/listen \\[::\\]:80 default_server;/listen [::]:$PORT default_server;/" /etc/nginx/sites-enabled/default
    echo "vmlab app-$i on \$(hostname)" | sudo tee /var/www/html/index.nginx-debian.html
    sudo nginx -t && sudo systemctl reload nginx
EOF
  echo "app-$i: http://$IP:$PORT"
done
