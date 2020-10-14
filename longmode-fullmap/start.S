; detecting available physical memory and identity mapping it all. displays mapped mem in textmode
; nasm start.S && qemu-system-x86_64 -hda start
; add -m 10G or whatever to test mapping different amt's of ram

[BITS 16]
[ORG 0x7C00]
start:
mov ah,0x00 ; set mode
mov al,0x03 ; text mode 80x25
int 0x10

; query available physical memory
; we have 2 bios calls that give us various memory regions
; we are not going to handle non-contiguous memory so we're just taking the max out of all these
; regions and identity mapping up to that
; we keep track of the max in MEM_TOTAL

; E801 bios call gives
; - DX = amount of memory starting at 16 MiB in number of 64 KiB blocks
; - CX = amount of memory between 1MiB and 16MiB in KiB
; - carry flag set on error
; this only handles up to 64 * 64 KiB = 4 GiB of memory, but it works even on very old machines
; we don't really care about the lower 16 MiB other than the stuff that's already mapped

mov ax,0xE801
int 0x15
xor dh,dh ; just in case something is in the upper bits
shl edx,16 ; multiply by 64 KiB because it's 64 KiB blocks
add edx,0x1000000 ; add 16 MiB because it's above the 16 MiB mark
mov [MEM_TOTAL],edx

; E820 bios call queries available memory regions. this is for when we have > 4 GiB of ram
; - ebx = continuation value, starts at zero. resets to zero at end of list
; - region struct will be stored at es:di
; - ecx = size to which we truncate the struct. minimum 20 bytes
; - edx = the signature 'SMAP' encoded as a 32-bit integer
;
; returns:
; - eax = 'SMAP' for sanity checking
; - ecx = num of bytes actually written
; - carry flag set on error
;
; the smallest struct is:
;   uint64 base
;   uint64 length
;   uint32 type

mov ax,cs
mov es,ax ; make sure es segment is set up
mov ds,ax

mov di,0x7E00 ; buffer for region struct. save a few bytes by not storing this in our boot sector
xor ebx,ebx ; continuation value starts at zero

query_mem_loop:
mov ecx,20 ; 20 bytes, minimum struct size
mov edx,'PAMS' ; SMAP reversed because of integer endian-ness
mov eax,0xE820
int 0x15
jc query_mem_done ; error
cmp eax,'PAMS'
jne query_mem_done ; invalid map
; check type. 1 is available. if we don't ignore reserved regions we will map too much ram on
; < 4GiB systems because bios reports some reserved stuff up to 4 GiB
cmp byte [di+16],1
jne query_mem_next

; check if base + length is higher than MEM_TOTAL
; since we're still in 32-bit mode we need to do 2 32-bit cascade subtractions and check for carry
mov ecx,[di]          ; ecx:edx = base
mov edx,[di+4]
add ecx,[di+8]        ; ecx:edx += length
adc edx,[di+12]
mov eax,[MEM_TOTAL]   ; eax:ebp = MEM_TOTAL
mov ebp,[MEM_TOTAL+4]
sub eax,ecx           ; eax:ebp (MEM_TOTAL) -= ecx:edx (base + length)
sbb ebp,edx
jnc query_mem_next
; carry means that eax:ebp (MEM_TOTAL) > ecx:edx (base + len) so we save the new max size
mov [MEM_TOTAL],ecx
mov [MEM_TOTAL+4],edx

query_mem_next:
; if ebx resets to zero, we're at the end of the list
test ebx,ebx
jnz query_mem_loop
query_mem_done:

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
mov esp,0x97000 ; tmp stack. this is just some memory that doesn't bother the bios

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

mov ecx,[MEM_TOTAL]
mov edx,[MEM_TOTAL+4]

; num of 2MiB pages, rounded up
add ecx,0x1FFFFF ; round up by adding 2MiB - 1
adc edx,0
mov cl,21        ; divide by 2MiB by shifting right by 21 bits (2<<21 = 2 MiB)
shrd ecx,edx,cl  ; this is used to do a 64-bit shift. it shift cl bits into ecx from edx

; we could also shift edx here, however we know for sure that this number will be 32-bits because
; the biggest address we can have is 48-bits and at 2MiB pages that's a max of 2^28 pages

; ecx = number of pages that will actually be mapped (not rounded). rest is zeroed
; edx = number of pages, rounded to 512 entries
mov edx,ecx

; round up to chunks of 512 entries to maintain the 4KiB alignment
add edx,0x1FF
and edx,~0x1FF

; PD: 2MiB pages identity-mapped to actual memory. eax:ebx used to track address
mov ebp,edi ; store PD pointer for later
push ecx
push edx
mov eax,0x87 ; R/W, U/S, P, PS
xor ebx,ebx
pdloop:
stosd
xchg eax,ebx
stosd
xchg eax,ebx
add eax,0x200000
adc ebx,0
dec edx
loop pdloop
mov ecx,edx
call zerorest
pop edx
pop ecx

xor ebx,ebx ; using ebx as a zero value register to write zeros in do_pages
call do_pages ; PDP: 1GiB pages
mov cr3,edi   ; set PML4 pointer
call do_pages ; PML4: 512GiB pages

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

; write ecx*2 zero dwords at edi
zerorest:
xor eax,eax
shl ecx,1
rep stosd
ret

; set up page table entries that point to the next table
; inputs:
;   edi = pointer to 4KiB aligned memory where the table will be written
;   ebp = pointer to the start of the previous table. will be the starting address for the entries
;   ecx = number of entries in the prev table (not rounded up). other entries are zeroed out
;   edx = number of entries in the prev table (rounded up to 512)
;   ebx = must be zero
; outputs:
;   ebp = pointer to the start of this table
;   edi = pointer to 4Kib aligned memory after the table
;   ecx = number of entries in this table (not rounded up)
;   edx = number of entries in this table (rounded up to 512)
do_pages:
; num of pages in this table, rounded up
; this is equivalent to rounding up to 512 entries, dividing by 512 and rounding up again
add edx,0x3FFFF
and edx,~0x3FFFF
shr edx,9

; num of pages in this table, not rounded
add ecx,0x1FF
shr ecx,9

push ecx
push edx
mov eax,ebp ; start at last table
mov ebp,edi ; save address of this table for later
or eax,7 ; R/W, U/S, P
pages_loop:
stosd
xchg eax,ebx
stosd ; zero
xchg eax,ebx
add eax,0x1000 ; step by 512*8 bytes (one table)
dec edx
loop pages_loop
mov ecx,edx
call zerorest
pop edx
pop ecx
ret

[BITS 64]
haha_long_boi:
; we are now in 64-bit long b o i mode

; print MEM_TOTAL as a 16 digit 64-bit hex number
mov rdi,0xb8000 ; color text mode buf
mov rdx,[MEM_TOTAL]
mov rcx,16
printloop:
mov rax,rdx
rol rax,4 ; most significant digits first
and rax,0xF
add rax,HEXCHARS
mov rax,[rax]
stosb ; character
mov rax,0x1F
stosb ; colors
shl rdx,4
loop printloop

hang:
pause
jmp hang

; -------------------------------------------------------------------------------------------------

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

MEM_TOTAL: dq 0
HEXCHARS: db '0123456789ABCDEF'

times 510-$+start db 0 ; pad to 512 bytes and add MBR bootable signature
db 0x55
db 0xAA
