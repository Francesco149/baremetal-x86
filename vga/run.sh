#!/bin/sh
nasm start.S && qemu-system-x86_64 -hda start
