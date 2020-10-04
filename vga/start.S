; this is the fast way to use vga. set the drawing color and write pixels as a bitmask in memory.
; nasm start.S && qemu-system-x86_64 -hda start

start:
;mov ax,0x4F02 ; set vbe mode
;mov bx,0x12 ; 640x480 16 colors
;int 0x10

; non-vbe mode encodes to 2 less bytes and appears to be the same as vbe for my purposes
mov ah,0x00 ; set mode
mov al,0x12 ; 640x480 16 colors
int 0x10

xor bx,bx ; current color
mov cx,0xA000 ; vga memory starts at 0xA0000, so we set the segment to 0xA000
mov ds,cx
mov cx,479*640/8 ; line start offset

; in 16-colors, we are combining 4 color planes: red, green, blue, white (makes color lighter).
; each plane is 1 bit per pixel. a color number is just the mask for the planes that should be on.
; these i/o commands select which color planes we are drawing on through a bitmask.
; if we make the bitmask the color we are just setting that pixel to that color.

mov dx,0x03C4
mov al,0x02 ; planes mask register bit
out dx,al

drawloop:

mov dx,0x03C5
mov al,bl ; planes mask
out dx,al

mov dx,bx ; save color in dx temporarily (can't use other regs for mov [mem])
shl bx,1
add bx,cx ; color * 2 + line_start
mov word [bx],0xFFFF ; draw 16 pixels (it's a bitmask), note: it's implicitly using ds as segment
mov bx,dx ; restore color

inc bl
cmp bl,16
jle drawloop

xor bl,bl    ; reset color
sub cx,640/8 ; next line
jnc drawloop

hang:
pause
jmp hang

times 510-$+start db 0 ; pad to 512 bytes and add MBR bootable signature
db 0x55
db 0xAA
