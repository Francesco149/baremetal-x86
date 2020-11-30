; example of using the PIT interrupt as a timer in real mode.
; note that this only works in real mode, using interrupts in protected is a bit more complicated.
; nasm start.S && qemu-system-x86_64 -hda start

[BITS 16]
[ORG 0x7C00]
start:
; set up some segments
xor ax,ax
mov es,ax
mov ds,ax

; load rest from disk
mov ah,0x42
mov si,DISK_ACCESS_PACKET
int 0x13

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

cld
mov ax,0xb800
mov es,ax
mov cx,END_OF_TEXT-TEXT
mov si,TEXT
xor di,di

copytext:
cmp byte [ds:si],10
jne nolf

; move to next line
xor dx,dx
mov bx,80*2
mov ax,di
div bx
inc ax
mul bx
mov di,ax
inc si
jmp copytext

nolf:
movsb
inc di
loop copytext

xor ax,ax
mov ds,ax

xor edx,edx
mov bx,0x06
xor cx,cx

draw:
mov eax,[timer]
cmp eax,edx
jb draw

%include "config.inc"
add edx,(60000/BPM)
push cx
call fillbg
xor bx,0x01
pop cx

inc cx
and cx,3
push ds
mov si,spinner
add si,cx
xor di,di
movsb
pop ds
jmp draw

fillbg:
mov ax,0xb800
mov es,ax
xor di,di
mov cx,80*2*25
mov ax,bx
fillbg_loop:
inc di
stosb
loop fillbg_loop
ret

; -------------------------------------------------------------------------------------------------

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
spinner: db "|/-\"

DISK_ACCESS_PACKET:
dw 16 ; size of packet
dw (END_OF_CODE-start)/512 ; num of sectors
dd 0x7E00 ; offset:segment
dq 1 ; starting blk

times 510-$+start db 0 ; pad to 512 bytes and add MBR bootable signature
db 0x55
db 0xAA

TEXT:
incbin "text"
END_OF_TEXT:

END_OF_CODE:
