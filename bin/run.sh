#!/usr/bin/env bash

set -euo pipefail

rm -f zig-out/bin/*
zig build -Dtarget=aarch64-linux.5.10.93...5.10.93-gnu.2.26 -Dcpu=neoverse_n1

ssh ec2-user@3.144.255.82 bash -c "pkill -q zig-scratch &> /dev/null || true && rm -f ./zig-scratch"
scp zig-out/bin/*  ec2-user@3.144.255.82:
ssh ec2-user@3.144.255.82 bash -c "./zig-scratch"
