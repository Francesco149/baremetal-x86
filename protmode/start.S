; switching to protected 32-bit mode
; nasm start.S && qemu-system-x86_64 -hda start

[BITS 16]
[ORG 0x7C00]
start:
mov ah,0x00 ; set mode
mov al,0x03 ; text mode 80x25
int 0x10

; disable interrupts
; when we switch to protected, the default interrupt handlers change. if we leave interrupts
; enabled it will instantly fault when the timer interrupt fires because it will be set to an
; invalid handler.
cli

; enable A20 line, this enables the 21th address bit
in al,0x92
or al,2
out 0x92,al

; ds is uninitialized. lgdt uses ds as its segment so let's init it
xor ax,ax
mov ds,ax

; load global descriptor table with the various segments.
; in real mode, segments are an offset into the gdt entries
lgdt [GDT_PTR]

mov eax,0x11 ; paging disabled, protection bit enabled. bit4, the extension type is always 1
mov cr0,eax

jmp GDT_BOOT_CS-GDT:protmode ; segment 0x16 is the code segment in our gdt. we jump to change CS

[BITS 32]
protmode:
; we are now in 32-bit protected mode
mov ax,GDT_BOOT_DS-GDT
mov ds,ax
mov ss,ax
mov esp,0x90000 ; tmp stack

mov edi,0xb8000
mov eax,'P R '
stosd
mov eax,'O T '
stosd
mov eax,'E C '
stosd

hang:
pause
jmp hang

; global descriptor table. this describes the various memory regions in protected mode

align 4
GDT_PTR:
dw GDT_END-GDT-1 ; size-1
dd GDT ; offset

; 8 bytes per entry
; base bits 24:31
; flags (4 bits)
;   granularity for limit (0=1B, 1=4KB page)
;   size (0=16bit, 1=32bit)
;   L bit (indicates x86_64 code descriptor). if this is set then size should be 0
; limit bits 16:19 (4 bits)
; access byte (8 bits)
;   present
;   privilege (2b)
;   descriptor type (1=code/data segments, 0=system segments)
;   executable
;   direction/conforming
;   readable
;   accessed
; base bits 16:23
; base bits 0:15
; limit bits 0:15

align 16
GDT:

; base = 0x00000000
; limit = 0xFFFFF * 4KB granularity = full 4GB address space
; flags = 0xC = 0b1100 (4KB granularity, 32bit)
; access byte = 0x92 = 10010010 (present, ring 0, code/data segment, writable)
GDT_NULL: dq 0 ; required on some platforms, disallow use of segment 0
GDT_BOOT_DS: dq 0x00CF92000000FFFF
GDT_BOOT_CS: dq 0x00CF9A000000FFFF ; same as DS but with executable set in access byte
;GDT_CS64: dq 0x00209A0000000000 ; same as above but 64-bit

GDT_END:

times 510-$+start db 0 ; pad to 512 bytes and add MBR bootable signature
db 0x55
db 0xAA
