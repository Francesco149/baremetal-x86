; minimal 16-bit real mode hello world
; nasm start.S && qemu-system-x86_64 -hda start

[BITS 16]
[ORG 0x7C00]
start:
mov ah,0x00 ; set mode
mov al,0x03 ; text mode 80x25
int 0x10

mov ax,0xb800
mov ds,ax               ; set data segment to the text mode buffer
mov dword [   0],'H I ' ; writes to 0xb8000
mov dword [80*2],': ) ' ; writes to 0xb8000 + 80*2 which is the 2nd line

hang:
jmp hang

times 510-$+start db 0 ; pad to 512 bytes and add MBR bootable signature
db 0x55
db 0xAA
