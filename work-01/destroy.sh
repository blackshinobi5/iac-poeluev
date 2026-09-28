#!/usr/bin/env bash
PREFIX=poeluev-05

yc compute instance delete "$PREFIX-app-1" || true
yc compute instance delete "$PREFIX-app-2" || true
yc vpc subnet delete "$PREFIX-subnet2" || true
yc vpc network delete "$PREFIX-net2" || true

yc compute instance list
yc vpc network list
