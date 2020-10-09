; bare metal ray marcher demo that fits in the mbr (512 bytes)
; requires SSE 4.1 (~2006 and later CPUs should all have it).
; note: this is not an example of good code, the goal here was to be as small as possible.
;       therefore the code is very fragile and many corners were cut. I used pretty much every
;       register I could to avoid referencing full addresses and such.
;       more bytes could be saved by not ussing SSE but that would be slow and ugly.
;
; nasm start.S && qemu-system-x86_64 -enable-kvm -hda start

[BITS 16]
[ORG 0x7C00]
start:
; enable sse (copied from osdev)
mov eax,cr0
and ax,0xfffb   ; clear coprocessor emulation CR0.EM
or ax,2         ; set coprocessor monitoring  CR0.MP
mov cr0,eax
mov eax,cr4
or ax,3<<9      ; set CR4.OSFXSR and CR4.OSXMMEXCPT at the same time
mov cr4,eax

; stack at 0x97000-0x90000
mov ax,0x9000
mov ss,ax
mov sp,0x7000

; initialize data segment (its contents are undefined on real hardware)
xor ax,ax
mov ds,ax

fninit ; init fpu

; make space on the stack for constants
sub esp,16*8
mov ebp,esp

; load some sse constants
; the reason I synthesize them like this is that it takes up significantly less bytes than having
; 16-byte constants embedded in the code and mostly zeroed out
; basically I have a bitmask that says where to put ones and where to put zero's and it builds the
; values %define 'd below
mov ecx,0x3F800000 ; 1.0
xor edi,edi
mov ebx,11101000010000101100001100100000b
synth:
shl ebx,1
jnc synth_next
mov dword [esp+edi*4],ecx
synth_next:
inc di
test ebx,ebx
jnz synth

%define xyz ebp
%define x ebp+16
%define y ebp+16*2
%define z ebp+16*3
%define xy ebp+16*4
; some other stuff used to be here and I cant be bothered to change the bitmask back

%define sphere1 ebp+16*6
mov dword [sphere1+12],0x3E99999A ; .3 (radius)

%define znear ebp+16*7+4
mov dword [znear],0x3A83126F ; .001

xor ah,ah
mov al,0x12 ; 640x480 16 colors
int 0x10

mov dx,0x03C4
mov al,0x02 ; planes mask register bit
out dx,al

inc dx
mov al,0xF ; planes mask (all of them = white)
out dx,al

%define framesz (640*480/8)
%define framebuf 0x7E0 ; some memory region that is known to be free

render:
mov ax,framebuf
;mov ax,0xA000
mov es,ax

; scale the cpu cycle counter to some reasonable value
; this is less bytes than setting up a PIT interrupt to count time accurately
rdtsc
mov ebx,1000000
div ebx
cvtsi2ss xmm2,eax
mov eax,3000
cvtsi2ss xmm1,eax
divss xmm2,xmm1

; using the legacy fpu is a lot less bytes than approximating sin with sse
push eax
movss [esp],xmm2
fld dword [esp]
fsin
fstp dword [esp]
movss xmm7,[esp]
pop eax

xorps xmm4,xmm4 ; current x/y
xor di,di ; index into frame buf
mov cx,480
screenloop:
mov esi,ecx ; store y in esi for later use
push cx
mov cx,640/32 ; we write pixels in blocks of 32-bit integers (1 bit per pixel)
mulps xmm4,[y] ; x = 0 by doing xy *= { x = 0, y = 1 }
rowloop:
xor eax,eax ; 32 pixel block
push cx
mov cx,32
pixloop:

; I use the carry flag to signal whether or not this pixel is empty
; I had to pull this out into a call because otherwise the screenloop jmp would be out of range
call march_pixel
jc skp

; we are inside the shape set the bit for this pixel
; cx goes from 32 to 1 so we do -1
mov bx,cx
dec bx
bts eax,ebx

skp:
addps xmm4,[x]
loop pixloop

; write the 32-pixel block to vga memory.
; the vga buffer is basically big endian. the most significant bits are the leftmost and the bytes
; are from left to right. so to do multiple bytes at once as an integer we need to byte swap
bswap eax
stosd
pop cx
loop rowloop

addps xmm4,[y]
pop cx
loop screenloop

; wait until we're out of vsync
mov dx,0x3DA
waitsync:
in al,dx
test al,8
jz waitsync

; swap buffer, aka copy everything to actual vga memory
; es = vga memory segment
push ds
mov ax,0xA000
mov es,ax
mov ax,framebuf
mov ds,ax
xor edi,edi
xor esi,esi
mov cx,framesz/4
rep movsd
pop ds

jmp render

; -------------------------------------------------------------------------------------------------

; inputs: x y z w in xmm0
; outputs: vector length of xmm0 in xmm0
; can be used for lower dimensional vectors by zeroing out unused components
len4:
dpps xmm0,xmm0,0xFF; dot(xmm0,xmm0)
movaps xmm1,xmm0
rsqrtss xmm0,xmm1  ; inverse sqrt is faster but less accurate than sqrtss
mulss xmm0,xmm1    ; 1/sqrt(x) * x = sqrt(x) because 1/sqrt(x) = x^-0.5 * x^1 = x^0.5 = sqrt(x)
ret

march_pixel:
; convert xy to uv
movaps xmm0,xmm4
movss xmm1,[halfscreensz]
shufps xmm1,xmm1,0
divps xmm0,xmm1
subps xmm0,[xy]

; normalize({ x, y, 1 })
addps xmm0,[z]
movaps xmm6,xmm0
call len4
shufps xmm0,xmm0,0
divps xmm6,xmm0 ; we don't need to check for division by zero. ray is always non-zero

xorps xmm5,xmm5 ; pos = {0, 0, 0}

mov bx,10 ; max steps, tweak for performance vs accuracy
march:
movaps xmm0,xmm5
movaps xmm1,[sphere1]
addss xmm1,xmm7

; sphere sdf
movaps xmm2,xmm1
shufps xmm2,xmm2,0xFF
mulps xmm1,[xyz]
subps xmm0,xmm1
call len4
subss xmm0,xmm2

; stop marching if we are close enough to the surf
ucomiss xmm0,[znear]
shufps xmm0,xmm0,0
movaps xmm3,xmm6
mulps xmm3,xmm0
addps xmm5,xmm3 ; pos += ray * distance
jb march_fill
dec bx
jnz march
march_empty:
stc
ret
march_fill:
movaps xmm0,[sphere1] ; xmm5 is the hit point. dist between the center and this pt is the normal
addss xmm0,xmm7
subps xmm0,xmm5 ; intentionally not normalizing to save instructions
dpps xmm0,[xy],01110001b ; dot product between light source direction and normal

push eax
; transform dot product value to index into the dithering table
addss xmm0,[x]
mulss xmm0,[shademul] ; adjust this to change shading treshold
cvtss2si eax,xmm0

; int(x) % 8 is the index into the dither pattern
cvtss2si edx,xmm4
bt esi,0 ; we shift the pattern on every other row to make it look better
adc dx,0
and dx,7

mov al,byte [dither+eax]
bt ax,dx ; dither patterns are inverted because we don't draw if carry flag is set
pop eax
ret

shademul: dd 4.5
halfscreensz: dd 320.0
modulo_scale: dd 65535.0

dither:
db 11111111b
db 11101110b
db 01101101b
db 01010101b
db 10010010b
db 00010001b
db 00000000b
; assuming rest is padded with zeros for out of range vals

times 510-$+start db 0 ; pad to 512 bytes and add MBR bootable signature
db 0x55
db 0xAA
