#!/bin/sh
nasm start.S && qemu-system-x86_64 -enable-kvm -m 1G -hda start
