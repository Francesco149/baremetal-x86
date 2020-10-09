; switching to 64-bit long mode and identity mapping the first 2MiB of ram
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
; in protected and long mode, segments are an offset into the gdt entries
lgdt [GDT_PTR]

mov eax,0x11 ; paging disabled, protection bit enabled. bit4, the extension type is always 1
mov cr0,eax

jmp GDT_BOOT_CS-GDT:protmode ; jump using our new code segment from the gdt to set cs

[BITS 32]
protmode:
; we are now in 32-bit protected mode
mov ax,GDT_BOOT_DS-GDT
mov ds,ax
mov ss,ax
mov es,ax
mov esp,0x90000 ; tmp stack.

; we want to use 4-level paging to support up to 1GiB pages
; this is achieved by:
;
; - enabling the PAE bit in cr4 (enables >32bit addresses through paging)
; - enabling the LME bit in the IA32_EFER (Extended Feature Enable Register) machine specific reg
; - enabling the PG bit in cr0
; - setting cr3 to point to the the 4th level page table

; set PAE (enables >32bit addresses through paging) and PGE (caches frequently used pages)
mov eax,0xA0
mov cr4,eax

; all the page tables are made up of 512 64-bit entries that must be 4KiB aligned in memory.
; the 4 KiB alignment matches the size of the 512 64-bit entries and makes it nicer to work with as
; the lower bits of the address will be zero at the beginning of the table.
;
; the lower bits of the entry are used for the address, up to 48 bits. however the 12 lower bits
; are always zero since we're 4KiB aligned, so those bits are actually used for flags or reserved.
; upper bits are also reserved or used for flags.
; we only care about these bits:
; - 0 P    Present          always 1 for valid pages
; - 1 R/W  Read/Write       allow writing
; - 2 U/S  User/Supervisor  if 0, user-mode code cannot use this memory
; - 7 PS   Page Size        if 1, entry points to memory, otherwise it points to a table
;
; there are up to 4 levels of page tables, each subdividing the address space into 512 entries.
; we start with 512 * 512 GiB entries that point to tables of 512 * 1 GiB entries that point to
; tables of 512 * 2 MiB entries that point to 512 * 4 KiB entries. depending on page size, we stop
; at the 1 GiB, 2 MiB or 4 KiB entries. for each table level we take the next most significant
; 9 bits from the address as the index
;
; page lookup starts from a pointer to the PML4 which is stored in register CR3.
;
; PML4 (page map level 4)
;   entries point to a PDP (page directory pointer).
;
;   PML4 entries are selected by taking bits 47:39 of the requested address as the index into the
;   table (so multiplied by 8) and then adding that to CR3, which has the lower 12 bits zeroed
;   because it's 4 KiB aligned. the two lower bits will be always zero because we are indexing
;   64-bit (8 byte) entries.
;
;   this means that the whole table covers 2^48 = 281474976710656 bytes = 256 TiB of memory and
;   each entry covers 256 / 512 TiB = 512 GiB of memory
;
; PDP (page directory pointer)
;   if we use 1 GiB pages, this points to actual memory.
;   we set the PS flag on the entry to indicate the use of 1 GiB pages.
;   otherwise, we need to go through another table and the entries point to a PD (page directory).
;
;   bits 38:30 of the address are the index into the table. higher bits are from the selected PML4
;   entry. again, lower 2 bits are zero because we index 8-byte entries.
;
;   the whole table covers 512 GiB of memory and each entry covers 1 GiB of memory
;
; PD (page directory)
;   if we use 2 MiB pages, this points to actual memory.
;   we set the PS flag on the entry to indicate the use of 2 MiB pages.
;   otherwise, we need to go through another table and the entries point to a PT (page table).
;
;   bits 29:21 of the address are the index into the table. higher bits are from the selected PDP.
;
;   the whole table covers 1 GiB of memory and each entry covers 2 MiB of memory
;
; PT (page table)
;   the entries point to actual memory.
;   bits 20:12 of the address are the index into the table. higher bits are from the selected PD.
;   the whole table covers 2 MiB of memory and each entry covers 4 KiB of memory
;
; finally, the lower bits of the address are an offset into the memory pointed by the page entry

mov edi,0x100000 ; first 1MiB of mem is mostly reserved for bios, so let's put tables after that

; as a test, just map 1 2 MiB page
; note: this repetitive code could be made much shorter, but it's left unrolled for clarity.
;       see longmode-fullmap for more compact code.

; PD: 2 MiB pages
mov eax,0x87
xor edx,edx
mov [edi],eax
mov [edi+4],edx
add edi,8

; zero rest of entries
mov ecx,511*2
xor eax,eax
rep stosd

; PDP: 1 GiB pages
mov eax,0x100007
mov [edi],eax
mov [edi+4],edx
add edi,8

mov ecx,511*2
xor eax,eax
rep stosd

; PML4: 512 GiB pages
mov eax,0x101007
mov [edi],eax
mov [edi+4],edx
add edi,8

mov ecx,511*2
xor eax,eax
rep stosd

; set PML4 pointer
mov eax,0x102000
mov cr3,eax

; set LME bit (long mode enable) in the IA32_EFER machine specific register
; MSRs are 64-bit wide and are written/read to/from eax:edx
mov ecx,0xC0000080 ; this is the register number for EFER
mov eax,0x00000100 ; LME bit set
xor edx,edx ; other bits zero
wrmsr

; enable paging
mov eax,cr0
bts eax,31
mov cr0,eax

jmp GDT_CS64-GDT:haha_long_boi ; as with the protected mode switch, we jmp using the new code segm

[BITS 64]
haha_long_boi:
; we are now in 64-bit long b o i mode

mov rdi,0xb8000
mov rax,'L O N G ' ; space happens to be color attributes for black on green
stosq
mov rax,'B O I ! '
stosq

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
GDT_NULL: dq 0 ; required on some platforms, disallow use of segment 0

; base = 0x00000000
; limit = 0xFFFFF * 4KB granularity = full 4GB address space
; flags = 0xC = 0b1100 (4KB granularity, 32bit)
; access byte = 0x92 = 10010010 (present, ring 0, code/data segment, writable)
GDT_BOOT_DS: dq 0x00CF92000000FFFF
GDT_BOOT_CS: dq 0x00CF9A000000FFFF ; same as DS but with executable set in access byte
GDT_CS64:    dq 0x00209A0000000000 ; same as above but 64-bit
; the 64-bit gdt entry doesn't have a limit because we use paging (I assume)

GDT_END:

times 510-$+start db 0 ; pad to 512 bytes and add MBR bootable signature
db 0x55
db 0xAA
