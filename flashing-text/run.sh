#!/bin/sh
echo "BPM EQU ${1:-180}" > config.inc
shift
echo '  forkexec' > text
printf "${*:-thanks\nfor\nwatching!}" | figlet -c -w 80 >> text
nasm start.S && qemu-system-x86_64 -enable-kvm -hda start
