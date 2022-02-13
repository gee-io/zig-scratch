#!/usr/bin/env bash

set -euo pipefail

REMOTE_HOST="ec2-user@3.144.255.82"

cd $(git rev-parse --show-toplevel)
rm -f zig-out/bin/*
make build

scp zig-out/bin/*  "$REMOTE_HOST":/tmp/
ssh -q "$REMOTE_HOST" <<'EOF'
  pkill -e io_uring-tcp-hasher || true
  mv /tmp/io_uring-tcp-hasher .
  sleep 1

  set -m
  ./io_uring-tcp-hasher &
  seq 10 | nc localhost 3131
  sleep 1
  kill %1
EOF
