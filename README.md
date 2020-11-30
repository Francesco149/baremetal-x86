heavily commented bare-metal x86 examples I wrote while learning

I am also making videos explaining what I have learned:
* [E1 - switching to long mode](https://www.youtube.com/watch?v=FzvDGDdtzws)

I have tested all of them on real hardware and they should work on anything that can boot in legacy
(MBR) mode.

to test on qemu:

    nasm start.S
    qemu-system-x86_64 -enable-kvm -hda start

to test on real hardware:

    nasm start.S
    sudo dd if=start of=/dev/your/usb/stick bs=512 count=1
    sync

then plug the usb into the machine and boot to it
