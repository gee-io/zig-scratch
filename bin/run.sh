#!/usr/bin/env bash

set -euo pipefail

rm -f zig-out/bin/*
zig build -Dtarget=aarch64-linux.5.10.93...5.10.93-gnu.2.26 -Dcpu=neoverse_n1
scp zig-out/bin/*  ec2-user@3.144.255.82:
ssh ec2-user@3.144.255.82 ./zig-scratch