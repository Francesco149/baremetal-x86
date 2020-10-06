; simple pulsating circle to practice sse programming. see the fpu version for legacy fpu.
; see non-vectorized version for simpler code.
; this demonstrates how you can store entire vectors in the sse registers and do operations on all
; components at once with some mental gymnastics.
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

; make space for one xmm register on the stack to build consts
sub sp,16

; load some sse constants
; the reason I synthesize them like this is that it takes up significantly less bytes than having
; 16-byte constants embedded in the code and mostly zeroed out
xorps xmm4,xmm4   ; zero. will be used as current x/y
movaps [esp],xmm4 ; zero out stack memory
mov dword [esp],0x3F800000 ; 1.0
movaps xmm6,[esp] ; xmm6 = { x = 0, y = 1 }
movaps xmm7,xmm6
; each 2 bits of the immediate value for shufps is an index into the floats packed into the regs
; for example, if xmm0 contains 1, 2, 3, 4 and xmm4 contains 5, 6, 7, 8
;   shufps xmm0,xmm4,11100100b
; will set xmm0 to 1, 2, 7, 8
shufps xmm7,xmm7,11110011b
mov dword [esp+4],0x43A00000 ; 320.0
mov dword [esp],0x43700000 ; 240.0
movaps xmm5,[esp] ; xmm5 = { x = 320, y = 240 }

render:
; xmm2 (pulsating_offset) = sin(timer/1000.0) * 50.0
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

xorps xmm4,xmm4 ; current x/y
xor di,di ; index into vga buf
mov cx,480
screenloop:
push cx
mov cx,640/32 ; we write pixels in blocks of 32-bit integers (1 bit per pixel)
mulps xmm4,xmm6 ; x = 0 by doing xy *= { x = 0, y = 1 }
rowloop:
xor eax,eax ; 32 pixel block
push cx
mov cx,32
pixloop:

; calculate distance from the edge of the circle located at 320,240
; with the radius 100+pulsating_offset

movaps xmm0,xmm4
subps xmm0,xmm5 ; subtract center of circle
call len4
addss xmm0,xmm2 ; add/subtract the pulsating offset we calculated earlier to the distance
cvtss2si ebx,xmm0

cmp ebx,100 ; are we inside the circle? (distance + offset <= radius)
jg skp

; we are inside the circle. set the bit for this pixel
; cx goes from 32 to 1 so we do -1
mov bx,cx
dec bx
bts eax,ebx

skp:
addps xmm4,xmm7 ; x += 1
loop pixloop

; write the 32-pixel block to vga memory.
; the vga buffer is basically big endian. the most significant bits are the leftmost and the bytes
; are from left to right. so to do multiple bytes at once as an integer we need to byte swap
bswap eax
stosd
pop cx
loop rowloop

addps xmm4,xmm6 ; y += 1
pop cx
loop screenloop

pause
jmp render

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

; inputs: x y z w in xmm0
; outputs: vector length of xmm0 in xmm0
; can be used for lower dimensional vectors by zeroing out unused components
len4:
mulps xmm0,xmm0 ; easy part, xyzw*=xyzw

; hard part, we need to add xyzw together
movhlps xmm1,xmm0 ; first, extract the 2 high floats into xmm1
addps xmm1,xmm0   ; add the 2 low and 2 high floats together
movaps xmm0,xmm1
shufps xmm1,xmm0,1 ; put 2nd float in the lowest slot so we can add 2 lowest floats together
addps xmm1,xmm0    ; ^ other slots will contain 1st float but we ignore them
rsqrtss xmm0,xmm1  ; inverse sqrt is faster but less accurate than sqrtss
mulss xmm0,xmm1    ; 1/sqrt(x) * x = sqrt(x) because 1/sqrt(x) = x^-0.5 * x^1 = x^0.5 = sqrt(x)
ret

timer: dd 0

times 510-$+start db 0 ; pad to 512 bytes and add MBR bootable signature
db 0x55
db 0xAA
