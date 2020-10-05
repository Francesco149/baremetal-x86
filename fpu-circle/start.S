; simple pulsating circle to practice fpu programming.
; uses the pit as a timer for the animation.
; nasm start.S && qemu-system-x86_64 -enable-kvm -hda start

[BITS 16]
[ORG 0x7C00]
start:
mov ah,0x00
mov al,0x12 ; 640x480 16 colors
int 0x10

; stack at 0x97000-0x90000
mov ax,0x9000
mov ss,ax
mov esp,0x7000

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

fninit ; init fpu

mov dx,0x03C4
mov al,0x02 ; planes mask register bit
out dx,al

mov dx,0x03C5
mov al,0xF ; planes mask (all of them = white)
out dx,al

; es = vga memory segment
mov ax,0xA000
mov es,ax

render:

; the FPU has its own stack to which we push values with fild and similar instructions.
; the top of the stack is accessed through the st0 register, next element is st1, and so on.
; the FPU always works off memory. so to push immediate values we just push them onto the stack
; and load from [esp]. similarly, to get back results we store them at the top of the stack and pop

; this code puts int16(sin(timer/1000.0) * 50.0) on top of the stack

fild dword [timer]  ; fpu_stack--, st0 = [timer]
push word 1000
fidiv word [ss:esp] ; st0 /= 1000
fsin                ; st0 = sin(st0)
push word 50
fimul word [ss:esp] ; st0 *= 50
pop ax ; dummy pop to remove 50 from the stack
fistp word [ss:esp] ; [ss:esp] = st0, fpu_stack++
mov bp,sp ; pointer to stack frame with the result

; the top of the stack is now the result, overwriting the 1000 we pushed earlier
; we keep it there for access through bp

xor di,di ; index into vga buf
mov cx,480
screenloop: ; this loop draws entire screen
mov bx,cx ; bx = y

push cx
mov cx,640/32 ; we write pixels in blocks of 32-bit integers (1 bit per pixel)
xor dx,dx     ; dx = x
rowloop:      ; this loop draws one row
xor eax,eax   ; 32 pixel block

push cx
mov cx,32
pixloop:
push dx ; back up x/y as we're going to do calculations with them
push bx

; calculate distance from the edge of the circle located at 320,240
; with the radius 100+int16(sin(timer/1000.0) * 50.0)
sub dx,320
sub bx,240
push dx
fild word [ss:esp]   ; fpu_stack--, st0 = dx
fmul st0             ; st0 = st0*st0
mov word [ss:esp],bx
fild word [ss:esp]
fmul st0
faddp                ; fpu_stack++, st0 += st1
fsqrt                ; st0 = sqrt(st0)
fistp word [ss:esp]  ; [ss:esp] = st0, fpu_stack++
mov bx,[ss:esp]      ; bx = sqrt((x-320)^2 + (y-240)^2) which is the distance to the center
pop dx ; clear stack

add bx,[ss:bp] ; add/subtract the pulsating offset to the distance
cmp bx,100     ; are we inside the circle? (distance + offset <= radius)
jg skp

; we are inside the circle. set the bit for this pixel
; cx goes from 32 to 1 so we do -1
mov bx,cx
dec bx
bts eax,ebx

skp:
pop bx
pop dx
inc dx
loop pixloop

; write the 32-pixel block to vga memory.
; the vga buffer is basically big endian. the most significant bits are the leftmost and the bytes
; are from left to right. so to do multiple bytes at once as an integer we need to byte swap
bswap eax
stosd
pop cx
loop rowloop

pop cx
loop screenloop

pop ax ; dummy pop to remove the fpu result from stack
pause
jmp render

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

times 510-$+start db 0 ; pad to 512 bytes and add MBR bootable signature
db 0x55
db 0xAA
