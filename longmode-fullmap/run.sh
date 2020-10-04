#!/bin/sh
nasm start.S && qemu-system-x86_64 -m 1G -hda start
