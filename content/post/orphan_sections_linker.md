---
title: "Linkers and orphaned sections"
date: 2025-02-25T21:13:08+01:00
author: Javier Alvarez
layout: post
tags:
  - ARM
  - Binutils
  - GNU
  - ld
  - lld
  - Linker Script
  - Microcontroller
---

## Problem statement

I recently came across a situation in a project where I had the following code:

```cpp
struct FaultInfo final {
    uint32_t r0;
    uint32_t r1;
    // And all the other register state of a Cortex-M0+ processor
    // ...

    uint32_t crc;
};

[[gnu::section(".uninit")]] volatile FaultInfo fault_data;
```

I was using this static region of data to persist some fault information across 
reboots, to log it on the next boot after recovering from the fault.

After an MCU fault, it can be challenging to determine which hardware and software components are 
still functioning correctly. Thus, it's best to rely on a minimal set of hardware until the MCU is 
rebooted, after which fault logging can be performed to persistent storage or a communication 
interface once the system is stable.

Of course, this code went along with the following output section declaration 
in the linker script:

```
    .uninit ALIGN(4) (NOLOAD) : {
        KEEP(*(.uninit))
    } > RAM : uninit
```

This worked well until one day, a refactor affected the linker script, and the `.uninit` output section
was mistakenly removed. 

You would think that now this fault data would be placed in `.bss` or `.data`, 
or maybe the linker would error out, right? Well, the answer is, it is complicated.

## Where did my uninitialized data go?

When the linker processes an input section in an object file that does not match any 
of the input section matchers defined in the linker script, the section becomes orphaned.

Orphaned sections are copied to the target ELF executable. So far, so good, because it
looks like it keeps the same behavior we had with the linker script above. However,
where in memory does this section go? 

This is where things break down. Multiple linkers exhibit different behavior, 
and the rules seem to be pretty complex, depending on whether any PHDRS have 
been explicitly declared, and whether any MEMORY nodes are present in the linker 
script.[^1]

For a long time, the issue went unnoticed since the section was placed in RAM, which was the 
intended behavior. However, at some point, the section was placed in FLASH instead, causing the 
application to fail. That's how I realized this was an issue.

### Figuring out where the section is being placed

I used `readelf` to figure out where the section was being placed, as well as the corresponding segment 
in which the section was placed. To figure out the placement of the section you can run:

```
$ arm-none-eabi-readelf -S $MY_ELF
There are 26 section headers, starting at offset 0x488bc:

Section Headers:
  [Nr] Name              Type            Addr     Off    Size   ES Flg Lk Inf Al
  [ 0]                   NULL            00000000 000000 000000 00      0   0  0
  [ 1] .root_section     PROGBITS        08000000 010000 000040 00   A  0   0  4
  [ 2] .text             PROGBITS        08000040 010040 00078a 00  AX  0   0  4
  [ 3] .rodata           PROGBITS        080007cc 0107cc 0000d2 00 AMS  0   0  4
  [ 4] .data             PROGBITS        20000000 020000 000010 00  WA  0   0  4
  [ 5] .uninit           PROGBITS        20000010 020010 000020 00  WA  0   0  4
  [ 6] .bss              NOBITS          20000030 020030 00047c 00  WA  0   0  4
  [ 7] .comment          PROGBITS        00000000 020030 000029 01  MS  0   0  1
  [ 8] .symtab           SYMTAB          00000000 02005c 000730 10      9  59  4
  [ 9] .strtab           STRTAB          00000000 02078c 000907 00      0   0  1
  [10] .shstrtab         STRTAB          00000000 021093 00012d 00      0   0  1
  [11] .debug_loclists   PROGBITS        00000000 0211c0 0000b8 00      0   0  1
  [12] .debug_abbrev     PROGBITS        00000000 021278 00177e 00      0   0  1
  [13] .debug_info       PROGBITS        00000000 0229f6 013182 00      0   0  1
  [14] .debug_str_offset PROGBITS        00000000 035b78 0000a4 00      0   0  1
  [15] .debug_str        PROGBITS        00000000 035c1c 00c3ab 01  MS  0   0  1
  [16] .debug_addr       PROGBITS        00000000 041fc7 000028 00      0   0  1
  [17] .debug_frame      PROGBITS        00000000 041ff0 000490 00      0   0  4
  [18] .debug_line       PROGBITS        00000000 042480 0042b9 00      0   0  1
  [19] .debug_line_str   PROGBITS        00000000 046739 0002af 01  MS  0   0  1
  [20] .debug_loc        PROGBITS        00000000 0469e8 00172a 00      0   0  1
  [21] .debug_ranges     PROGBITS        00000000 048112 000478 00      0   0  1
  [22] .debug_aranges    PROGBITS        00000000 04858a 000020 00      0   0  1
  [23] .interned_strings PROGBITS        00000000 0485aa 0002f8 00      0   0  1
  [24] .postform_config  PROGBITS        00000000 0488a4 000004 00      0   0  4
  [25] .postform_version PROGBITS        00000000 0488a8 000011 00      0   0  1
Key to Flags:
  W (write), A (alloc), X (execute), M (merge), S (strings), I (info),
  L (link order), O (extra OS processing required), G (group), T (TLS),
  C (compressed), x (unknown), o (OS specific), E (exclude),
  y (purecode), p (processor specific)
```

Here you can see the exact location of the section in memory, at `0x20000010`. The `PROGBITS` type 
indicates that the section does have initial data, which should not be the case, considering we do not
plan on initializing the data, so there's also no point in storing it.

```
$ arm-none-eabi-readelf -l $MY_ELF

Elf file type is EXEC (Executable file)
Entry point 0x8000495
There are 5 program headers, starting at offset 52

Program Headers:
  Type           Offset   VirtAddr   PhysAddr   FileSiz MemSiz  Flg Align
  LOAD           0x010000 0x08000000 0x08000000 0x00040 0x00040 R E 0x10000
  LOAD           0x010040 0x08000040 0x08000040 0x0078a 0x0078a R E 0x10000
  LOAD           0x0107cc 0x080007cc 0x080007cc 0x000d2 0x000d2 R   0x10000
  LOAD           0x020000 0x20000000 0x080008a0 0x00030 0x00030 RW  0x10000
  LOAD           0x020030 0x20000030 0x20000030 0x00000 0x0047c RW  0x10000

 Section to Segment mapping:
  Segment Sections...
   00     .root_section
   01     .text
   02     .rodata
   03     .data .uninit
   04     .bss
```

And here we see that the `.uninit` data section is just being bundled in the same data segment as 
the `.data` section. This is incorrect because an ELF loader will attempt to load .uninit from the 
ELF file into memory, which contradicts the intent of keeping it uninitialized. Fortunately, this 
isn't a problem in our case since this is a bare-metal application that doesn't use an ELF loader.
But regardless of this, we are storing more data than we need into the ELF file, bloating its initial 
size. Ideally we want this section to be placed in a segment with `FileSiz` of 0, like the segment 
number 4, corresponding to the `.bss` section.

Now let's look at the fixed ELF, after the section is declared:

```
$ arm-none-eabi-readelf -S $MY_ELF
There are 26 section headers, starting at offset 0x48d18:

Section Headers:
  [Nr] Name              Type            Addr     Off    Size   ES Flg Lk Inf Al
  [ 0]                   NULL            00000000 000000 000000 00      0   0  0
  [ 1] .root_section     PROGBITS        08000000 010000 000040 00   A  0   0  4
  [ 2] .text             PROGBITS        08000040 010040 00078a 00  AX  0   0  4
  [ 3] .rodata           PROGBITS        080007cc 0107cc 0000d2 00 AMS  0   0  4
  [ 4] .data             PROGBITS        20000000 020000 000010 00  WA  0   0  4
  [ 5] .bss              NOBITS          20000010 020010 00047c 00  WA  0   0  4
  [ 6] .uninit           NOBITS          2000048c 02048c 000020 00  WA  0   0  4
  [ 7] .comment          PROGBITS        00000000 02048c 000029 01  MS  0   0  1
  [ 8] .symtab           SYMTAB          00000000 0204b8 000730 10      9  59  4
  [ 9] .strtab           STRTAB          00000000 020be8 000907 00      0   0  1
  [10] .shstrtab         STRTAB          00000000 0214ef 00012d 00      0   0  1
  [11] .debug_loclists   PROGBITS        00000000 02161c 0000b8 00      0   0  1
  [12] .debug_abbrev     PROGBITS        00000000 0216d4 00177e 00      0   0  1
  [13] .debug_info       PROGBITS        00000000 022e52 013182 00      0   0  1
  [14] .debug_str_offset PROGBITS        00000000 035fd4 0000a4 00      0   0  1
  [15] .debug_str        PROGBITS        00000000 036078 00c3ab 01  MS  0   0  1
  [16] .debug_addr       PROGBITS        00000000 042423 000028 00      0   0  1
  [17] .debug_frame      PROGBITS        00000000 04244c 000490 00      0   0  4
  [18] .debug_line       PROGBITS        00000000 0428dc 0042b9 00      0   0  1
  [19] .debug_line_str   PROGBITS        00000000 046b95 0002af 01  MS  0   0  1
  [20] .debug_loc        PROGBITS        00000000 046e44 00172a 00      0   0  1
  [21] .debug_ranges     PROGBITS        00000000 04856e 000478 00      0   0  1
  [22] .debug_aranges    PROGBITS        00000000 0489e6 000020 00      0   0  1
  [23] .interned_strings PROGBITS        00000000 048a06 0002f8 00      0   0  1
  [24] .postform_config  PROGBITS        00000000 048d00 000004 00      0   0  4
  [25] .postform_version PROGBITS        00000000 048d04 000011 00      0   0  1
Key to Flags:
  W (write), A (alloc), X (execute), M (merge), S (strings), I (info),
  L (link order), O (extra OS processing required), G (group), T (TLS),
  C (compressed), x (unknown), o (OS specific), E (exclude),
  y (purecode), p (processor specific)
```

Now, the `.uninit` section has the type `NOBITS`, meaning it will be allocated in memory but not stored 
in the ELF file, ensuring that no unnecessary data is included in the binary. Let's see the segments:

```
$ arm-none-eabi-readelf -l $MY_ELF

Elf file type is EXEC (Executable file)
Entry point 0x8000495
There are 6 program headers, starting at offset 52

Program Headers:
  Type           Offset   VirtAddr   PhysAddr   FileSiz MemSiz  Flg Align
  LOAD           0x010000 0x08000000 0x08000000 0x00040 0x00040 R E 0x10000
  LOAD           0x010040 0x08000040 0x08000040 0x0078a 0x0078a R E 0x10000
  LOAD           0x0107cc 0x080007cc 0x080007cc 0x000d2 0x000d2 R   0x10000
  LOAD           0x020000 0x20000000 0x080008a0 0x00010 0x00010 RW  0x10000
  LOAD           0x020010 0x20000010 0x20000010 0x00000 0x0047c RW  0x10000
  LOAD           0x02048c 0x2000048c 0x2000048c 0x00000 0x00020 RW  0x10000

 Section to Segment mapping:
  Segment Sections...
   00     .root_section
   01     .text
   02     .rodata
   03     .data
   04     .bss
   05     .uninit
```

And now the ELF is fixed, and the `FileSiz` of section 5, in which the `.uninit` 
section is allocated, has the right size of 0.

## How can we make the linker script more robust?

After finding this issue, I looked for a way to detect this kind of problem, 
ideally at compile-time. I found the `--orphaned-handling` flag of the `ld` and `lld` linkers[^2].
This flag allows us to specify what should be the behavior when an orphaned 
section is encountered. You have the following options:

- `place`: silently ignores that this section is orphaned and places it somewhere in memory.
- `warn`: same as place, but it emits a warning when linking.
- `error`: triggers a link-time error when a section is orphaned.
- `discard`: drops the data in the orphaned section.

By setting `--orphan-handling=error`, we prevent silent misplacement of sections, 
ensuring a predictable memory layout. This serves as a safeguard against subtle 
and hard-to-diagnose issues in embedded applications.

However, setting the `--orphan-handling=error` flag means that the binary 
does no longer compile. The reason behind this is that I did NOT declare all 
output sections in the linker script, even after I added the `.uninit` 
section back. 

The problem is that there is a set of sections that are always required for 
any [ELF](https://en.wikipedia.org/wiki/Executable_and_Linkable_Format) executable 
to be valid. And similarly, if you intend to use [Dwarf](https://dwarfstd.org/) debugging 
information (e.g. using `-gdwarf-2`), you will need to append some more output sections 
to your linker script.

```
    /* ELF Sections */
    .comment 0 : { *(.comment) }
    .symtab 0 : { *(.symtab) }
    .strtab 0 : { *(.strtab) }
    .shstrtab 0 : { *(.shstrtab) }

    /* Dwarf Sections */
    .debug_loclists 0 : { *(.debug_loclists) }
    .debug_abbrev 0 : { *(.debug_abbrev) }
    .debug_info 0 : { *(.debug_info) }
    .debug_str_offsets 0 : { *(.debug_str_offsets) }
    .debug_str 0 : { *(.debug_str) }
    .debug_addr 0 : { *(.debug_addr) }
    .debug_frame 0 : { *(.debug_frame) }
    .debug_line 0 : { *(.debug_line) }
    .debug_line_str 0 : { *(.debug_line_str) }
    .debug_loc 0 : { *(.debug_loc) }
    .debug_ranges 0 : { *(.debug_ranges) }
    .debug_aranges 0 : { *(.debug_aranges) }

    /* Exceptions are disabled, we don't need these sections */
    /DISCARD/ : {
        *(.ARM.exidx);
        *(.ARM.attributes);
    }
```

[^1]: MaskRay has a great [article](https://maskray.me/blog/2024-06-02-understanding-orphan-sections) 
describing some of these placement rules for both ld and lld, if you would like to go deeper into 
this topic.

[^2]: You can find the ld documentation for orphaned sections 
[here](https://sourceware.org/binutils/docs/ld/Orphan-Sections.html).
