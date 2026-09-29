#!/usr/bin/env bash
set -euo pipefail
PREFIX=poeluev-05

# удалить ресурс, только если он есть: $1 — команда yc, $2 — имя
del() {
  if yc $1 get "$2" >/dev/null 2>&1; then
    echo "удаляю: $2"
    yc $1 delete "$2"
  else
    echo "пропуск (нет): $2"
  fi
}

del "load-balancer network-load-balancer" "$PREFIX-lb"
del "load-balancer target-group" "$PREFIX-tg"
for name in $(yc compute instance list --format json \
    | jq -r --arg p "$PREFIX-app-" '.[].name | select(startswith($p))'); do
  del "compute instance" "$name"
done
del "compute disk" "$PREFIX-data"
del "vpc subnet" "$PREFIX-subnet-a"
del "vpc subnet" "$PREFIX-subnet-b"
del "vpc network" "$PREFIX-net"
