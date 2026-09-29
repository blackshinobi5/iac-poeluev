#!/usr/bin/env bash
# Поднимает стенд целиком. Повторный запуск безопасен.
set -euo pipefail

# --- параметры: аргумент > переменная окружения > умолчание из варианта ---
PREFIX="${PREFIX:-poeluev-05}"
ZONE_A="${ZONE_A:-ru-central1-b}"
ZONE_B="${ZONE_B:-ru-central1-d}"
CIDR_A="${CIDR_A:-10.15.1.0/24}"
CIDR_B="${CIDR_B:-10.15.2.0/24}"
SVC_PORT="${SVC_PORT:-8015}"
WORD="${WORD:-vmlab}"
WEB_COUNT="${WEB_COUNT:-2}"
SSH_PUB="${SSH_PUB:-$HOME/.ssh/id_ed25519.pub}"

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)    PREFIX="$2";    shift 2 ;;
    --zone-a)    ZONE_A="$2";    shift 2 ;;
    --zone-b)    ZONE_B="$2";    shift 2 ;;
    --cidr-a)    CIDR_A="$2";    shift 2 ;;
    --cidr-b)    CIDR_B="$2";    shift 2 ;;
    --port)      SVC_PORT="$2";  shift 2 ;;
    --word)      WORD="$2";      shift 2 ;;
    --web-count) WEB_COUNT="$2"; shift 2 ;;
    --ssh-pub)   SSH_PUB="$2";   shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done
export PREFIX SVC_PORT SSH_PUB

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exists() { "$@" >/dev/null 2>&1; }
log() { echo "[$(date +%T)] $*"; }
[ -f "$SSH_PUB" ] || { echo "нет ключа $SSH_PUB" >&2; exit 1; }
log "параметры: prefix=$PREFIX web=$WEB_COUNT port=$SVC_PORT зоны=$ZONE_A,$ZONE_B"

# --- сеть и подсети ---
if exists yc vpc network get "$PREFIX-net"; then
  log "сеть: есть, пропускаю"
else
  log "сеть: создаю"
  yc vpc network create --name "$PREFIX-net" >/dev/null
fi

if exists yc vpc subnet get "$PREFIX-subnet-a"; then
  log "подсеть a: есть, пропускаю"
else
  log "подсеть a: создаю"
  yc vpc subnet create --name "$PREFIX-subnet-a" --network-name "$PREFIX-net" \
    --zone "$ZONE_A" --range "$CIDR_A" >/dev/null
fi

if exists yc vpc subnet get "$PREFIX-subnet-b"; then
  log "подсеть b: есть, пропускаю"
else
  log "подсеть b: создаю"
  yc vpc subnet create --name "$PREFIX-subnet-b" --network-name "$PREFIX-net" \
    --zone "$ZONE_B" --range "$CIDR_B" >/dev/null
fi

# --- NAT-шлюз, таблица маршрутизации, привязка к подсети A ---
if exists yc vpc gateway get "$PREFIX-nat"; then
  log "NAT-шлюз: есть, пропускаю"
else
  log "NAT-шлюз: создаю"
  yc vpc gateway create --name "$PREFIX-nat" >/dev/null
fi
GW_ID=$(yc vpc gateway get "$PREFIX-nat" --format json | jq -r .id)

if exists yc vpc route-table get "$PREFIX-rt"; then
  log "таблица маршрутов: есть, пропускаю"
else
  log "таблица маршрутов: создаю"
  yc vpc route-table create --name "$PREFIX-rt" --network-name "$PREFIX-net" \
    --route "destination=0.0.0.0/0,gateway-id=$GW_ID" >/dev/null
fi
RT_ID=$(yc vpc route-table get "$PREFIX-rt" --format json | jq -r .id)

if [ "$(yc vpc subnet get "$PREFIX-subnet-a" --format json | jq -r '.route_table_id // ""')" = "$RT_ID" ]; then
  log "таблица привязана к подсети a, пропускаю"
else
  log "привязываю таблицу к подсети a"
  yc vpc subnet update --name "$PREFIX-subnet-a" --route-table-name "$PREFIX-rt" >/dev/null
fi

# --- группа безопасности ---
if exists yc vpc security-group get "$PREFIX-sg"; then
  log "группа безопасности: есть, пропускаю"
else
  log "группа безопасности: создаю"
  yc vpc security-group create --name "$PREFIX-sg" --network-name "$PREFIX-net" \
    --rule "direction=ingress,port=22,protocol=tcp,v4-cidrs=[0.0.0.0/0]" \
    --rule "direction=ingress,port=$SVC_PORT,protocol=tcp,v4-cidrs=[0.0.0.0/0]" \
    --rule "direction=ingress,port=any,protocol=any,v4-cidrs=[$CIDR_A,$CIDR_B]" \
    --rule "direction=egress,port=any,protocol=any,v4-cidrs=[0.0.0.0/0]" >/dev/null
fi
SG_ID=$(yc vpc security-group get "$PREFIX-sg" --format json | jq -r .id)

# --- cloud-init из шаблона ---
USERDATA=$(mktemp); trap 'rm -f "$USERDATA"' EXIT
sed -e "s|__SSH_KEY__|$(cat "$SSH_PUB")|" -e "s|__PORT__|$SVC_PORT|g" \
    -e "s|__WORD__|$WORD|g" "$DIR/cloud-init.tpl.yaml" > "$USERDATA"

# --- машины: create_vm имя зона подсеть yes|no (публичный адрес) ---
create_vm() {
  local name="$1" zone="$2" subnet="$3" pub="$4" nat=""
  if exists yc compute instance get "$name"; then
    log "$name: есть, пропускаю"; return 0
  fi
  if [ "$pub" = yes ]; then nat=",nat-ip-version=ipv4"; fi
  log "$name: создаю"
  yc compute instance create --name "$name" --hostname "$name" --zone "$zone" \
    --platform standard-v2 --cores 2 --core-fraction 20 --memory 2 \
    --create-boot-disk "image-family=debian-12,image-folder-id=standard-images,size=10,type=network-hdd,auto-delete=true" \
    --network-interface "subnet-name=$subnet,security-group-ids=$SG_ID$nat" \
    --metadata-from-file user-data="$USERDATA" >/dev/null
}

for i in $(seq 1 "$WEB_COUNT"); do
  if [ $((i % 2)) -eq 1 ]; then Z="$ZONE_A"; S="$PREFIX-subnet-a"; else Z="$ZONE_B"; S="$PREFIX-subnet-b"; fi
  create_vm "$PREFIX-web-$i" "$Z" "$S" yes
done
create_vm "$PREFIX-app-1" "$ZONE_A" "$PREFIX-subnet-a" no

# --- целевая группа и балансировщик ---
if exists yc load-balancer target-group get "$PREFIX-tg"; then
  log "целевая группа: есть, пропускаю"
else
  log "целевая группа: создаю"
  TARGETS=()
  for i in $(seq 1 "$WEB_COUNT"); do
    J=$(yc compute instance get "$PREFIX-web-$i" --format json)
    IP=$(echo "$J"  | jq -r '.network_interfaces[0].primary_v4_address.address')
    SUB=$(echo "$J" | jq -r '.network_interfaces[0].subnet_id')
    TARGETS+=(--target "subnet-id=$SUB,address=$IP")
  done
  yc load-balancer target-group create --name "$PREFIX-tg" "${TARGETS[@]}" >/dev/null
fi

if exists yc load-balancer network-load-balancer get "$PREFIX-lb"; then
  log "балансировщик: есть, пропускаю"
else
  log "балансировщик: создаю"
  TG_ID=$(yc load-balancer target-group get "$PREFIX-tg" --format json | jq -r .id)
  yc load-balancer network-load-balancer create --name "$PREFIX-lb" \
    --listener "name=http,port=80,target-port=$SVC_PORT,external-ip-version=ipv4" \
    --target-group "target-group-id=$TG_ID,healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port=$SVC_PORT,healthcheck-http-path=/" >/dev/null
fi

# --- ждём готовности: пока check.sh не пройдёт (до 7,5 минут) ---
log "жду готовности стенда..."
END=$((SECONDS + 420))
while [ "$SECONDS" -lt "$END" ]; do
  if bash "$DIR/check.sh" >/dev/null 2>&1; then break; fi
  sleep 5
done
bash "$DIR/check.sh"
