; simple pulsating circle to practice sse programming. see the fpu version for legacy fpu.
; uses the pit as a timer for the animation.
; nasm start.S && qemu-system-x86_64 -enable-kvm -hda start

[BITS 16]
[ORG 0x7C00]
start:
; enable sse (copied from osdev)
mov eax, cr0
and ax, 0xfffb  ; clear coprocessor emulation CR0.EM
or ax,2         ; set coprocessor monitoring  CR0.MP
mov cr0,eax
mov eax,cr4
or ax,3<<9      ; set CR4.OSFXSR and CR4.OSXMMEXCPT at the same time
mov cr4,eax

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
; SSE greatly simplifies float operations by not having to deal with the FPU stack.
; much more readable.
; not to mention it's much faster and can do multiple packed values at once for batch operations.
; one downside is that you have to implement sin yourself or use the legacy fpu for that,
; but the legacy sin is slow anyway.
cvtsi2ss xmm0,dword [timer]
mov eax,1000
cvtsi2ss xmm1,eax
divss xmm0,xmm1
movaps xmm2,xmm0
call ssesin
movaps xmm2,xmm0
mov ax,50
cvtsi2ss xmm2,eax
mulss xmm2,xmm0
; xmm2 (pulsating_offset) = sin(timer/1000.0) * 50.0

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
; with the radius 100+pulsating_offset
sub dx,320
sub bx,240
movsx edx,dx ; need to sign extend, cvtsi only takes 32+bit regs
movsx ebx,bx
cvtsi2ss xmm0,edx
cvtsi2ss xmm1,ebx
mulss xmm0,xmm0
mulss xmm1,xmm1
addss xmm0,xmm1
rsqrtss xmm1,xmm0 ; inverse sqrt is faster but less accurate than sqrtss
mulss xmm1,xmm0   ; 1/sqrt(x) * x = sqrt(x) because 1/sqrt(x) = x^-0.5 * x^1 = x^0.5 = sqrt(x)
addss xmm1,xmm2   ; add/subtract the pulsating offset we calculated earlier to the distance
cvtss2si ebx,xmm1

cmp ebx,100 ; are we inside the circle? (distance + offset <= radius)
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

; fast sine approximation https://stackoverflow.com/posts/23839191/revisions
; returns sin of xmm2 in xmm0
sin_a: dd -0.16612511580269618
sin_b: dd 8.0394356072977748e-3
sin_c: dd -1.49414020045938777495e-4
pi2: dd 6.283185307179586
ssesin:
; xmm2 %= 2*PI
divss xmm2,dword [pi2]
cvtss2si eax,xmm2
cvtsi2ss xmm1,eax
subss xmm2,xmm1
mulss xmm2,dword [pi2]
; xmm0 = sin(xmm0)
movaps xmm3,xmm2
mulss xmm3,xmm3
movss xmm0,dword [sin_c]
mulss xmm0,xmm3
addss xmm0,dword [sin_b]
mulss xmm0,xmm3
addss xmm0,dword [sin_a]
mulss xmm0,xmm2
mulss xmm0,xmm3
addss xmm0,xmm2
ret

timer: dd 0

times 510-$+start db 0 ; pad to 512 bytes and add MBR bootable signature
db 0x55
db 0xAA
