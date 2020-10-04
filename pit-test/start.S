; example of using the PIT interrupt as a timer in real mode.
; note that this only works in real mode, using interrupts in protected is a bit more complicated.
; nasm start.S && qemu-system-x86_64 -hda start

[BITS 16]
[ORG 0x7C00]
start:
mov ah,0x00
mov al,0x03 ; text mode
int 0x10

; set up PIT (Programmable Interval Timer) to fire every ~1ms

cli ; temporarily disable interrupts in case we disturb something
mov al,0x34 ; channel 0, lobyte/hibyte, rate generator
out 0x43,al
mov ax,1193 ; this divides the PIT frequency. 1193 is roughly 1ms tick rate (1.193182 MHz / 1193)
out 0x40,al ; lobyte
mov al,ah
out 0x40,al ; hibyte

; at 0x0000 is a table of the default bios interrupt handlers.
; here I'm overriding the one for the PIT
mov ax,0
mov ds,ax
mov ax,timer_handler
mov word [0x20],ax
mov word [0x22],cs ; need to provide code segment as well
sti ; re-enable interrupts

; print timer in a loop
mov ax,0xb800
mov es,ax
print:
mov edx,[timer]
mov cx,8
xor di,di
printloop:
mov eax,edx
rol eax,4 ; most significant digits first
and eax,0x0F
add eax,hexchars
mov al,[eax]
stosb ; character
mov al,0x1F
stosb ; colors
shl edx,4
loop printloop
pause
jmp print

; execution jumps here when the interrupt fires
timer_handler:
inc dword [timer]

; send end-of-interrupt signal
push eax
mov al,0x20
out 0x20,al
pop eax
iret

timer: dd 0
hexchars: db '0123456789ABCDEF'

times 510-$+start db 0 ; pad to 512 bytes and add MBR bootable signature
db 0x55
db 0xAA
