#!/usr/bin/env bash
# Проверка стенда. Код возврата: 0 — все проверки прошли, 1 — хотя бы одна нет.
set -u
PREFIX="${PREFIX:-poeluev-05}"
SVC_PORT="${SVC_PORT:-8015}"
SSH_PUB="${SSH_PUB:-$HOME/.ssh/id_ed25519.pub}"
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2";   shift 2 ;;
    --port)   SVC_PORT="$2"; shift 2 ;;
    --ssh-pub) SSH_PUB="$2"; shift 2 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

rc=0
pass() { echo "✓ $*"; }
fail() { echo "✗ $*"; rc=1; }
ip_of() { # $1 имя, $2 jq-путь
  yc compute instance get "$1" --format json 2>/dev/null | jq -r "$2 // empty" 2>/dev/null
}

LB_IP=$(yc load-balancer network-load-balancer get "$PREFIX-lb" --format json 2>/dev/null \
  | jq -r '.listeners[0].address // empty' 2>/dev/null)

# 1. балансировщик отвечает 200
if [ -z "$LB_IP" ]; then
  fail "балансировщика $PREFIX-lb нет"
else
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$LB_IP/")
  if [ "$code" = 200 ]; then pass "балансировщик отвечает: $code"; else fail "балансировщик отвечает: $code"; fi
fi

# 2. ответы приходят больше чем с одной машины
if [ -z "$LB_IP" ]; then
  fail "распределение проверить нельзя: нет балансировщика"
else
  NAMES=$(for _ in $(seq 1 12); do curl -s --max-time 3 "http://$LB_IP/" | awk '{print $2}'; done \
    | sort -u | grep . | sed "s/^$PREFIX-//")
  N=$(printf '%s\n' "$NAMES" | grep -c .)
  LIST=$(printf '%s\n' "$NAMES" | paste -sd, - | sed 's/,/, /g')
  if [ "$N" -gt 1 ]; then pass "ответили машины: $LIST"; else fail "ответила одна машина: ${LIST:-никто}"; fi
fi

# 3. сервер приложения доступен с web-1 по внутреннему адресу
WEB1=$(ip_of "$PREFIX-web-1" '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')
APP=$(ip_of "$PREFIX-app-1" '.network_interfaces[0].primary_v4_address.address')
if [ -z "$WEB1" ] || [ -z "$APP" ]; then
  fail "сервер приложения недоступен: машин стенда нет"
else
  code=$(ssh -i "${SSH_PUB%.pub}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR "iac@$WEB1" \
    "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://$APP:$SVC_PORT/" 2>/dev/null)
  if [ "$code" = 200 ]; then pass "сервер приложения $APP доступен с web-1"; else fail "сервер приложения $APP недоступен с web-1"; fi
fi

exit $rc
