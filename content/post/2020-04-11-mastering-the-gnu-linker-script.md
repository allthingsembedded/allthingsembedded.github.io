---
id: 457
title: Mastering the GNU linker script
date: 2020-04-11T21:25:34+00:00
author: Javier Alvarez
layout: post
tags:
  - ARM
  - Binutils
  - Cortex-M
  - GNU
  - Linker Script
  - Microcontroller
---
Most people getting started with embedded development seem to find linker scripts just another piece of magic required to get up and running with their system. Even when they might already be familiar with memory-mapped peripherals and basic embedded concepts, the linker script and how it interacts with the GNU linker (ld) is still pretty mysterious.

Today we will go through the main functions of a linker script to try to shed some light onto their operation. We covered the basic of cross compilation in a previous post. We mentioned that the linker would be the last step in the compilation process. The job of the linker is to take all input object files and libraries (both shared and static) and generate a single executable file. Let's start with some terminology.

## Object files and symbols

Object files are the generated output produced by the assembly. They contain the machine code as translated by the assembler. As part of an object file, they also contain references to symbols used in the code. These references may be defined in the object file itself (think of a local variable in the source of the object file) or undefined (like a function from a standard library, that is not provided by your object file). Symbols refer to both code and data and they serve to identify where a function starts and where a variable is located in an object file.

## Sections

Object files usually contain multiple sections. Each section contains either code or data that is needed for the target application. Usually the following sections are common in a C program:

  * `.text`: This section contains the code. This is, the machine language instructions that will be executed by the processor. In here we will find symbols that reference the functions in your object file.
  * `.rodata`: This contains any data that is marked as read only. It is not unusual to find this data interleaved with the text section.
  * `.data`: This section contains initialized global and static variables. Any global object that has been explicitly initialized to a value different than zero.
  * `.bss`: Contains all uninitialized global and static variables. These are usually zeroed out by the startup code before we reach the main function. However, In an embedded system we usually provide our own startup code, which means we need to remember to do this ourselves. I wrote a nice article about the startup code a while back [here](/post/2019-01-03-arm-cortex-m-startup-code-for-c-and-c/).
  * `.isr_vector`: Contains the addresses of every Interrupt Service Routine. This is architecture specific and therefore not common to every microcontroller. It is, however, required for [Cortex-M microcontrollers](https://developer.arm.com/docs/dui0552/latest/the-cortex-m3-processor/exception-model/vector-table).

## The role of the linker in detail

The job of the linker is to take all object files and libraries to be linked and create an executable. In order to do this, it must take all symbols from the object files, resolve unknown symbols on each input object file (this is, finding out which object file provides each missing symbol) and create a single output file with no unresolved symbols (except of those of dynamically linked libraries, which are resolved during runtime).

Multiple input sections in object files map to different output sections in the output file of the linker. The linker script takes care of specifying the memory layout of each output section. We define all output sections inside the SECTION command:

```c++
/* Define output sections */
SECTIONS
{
  .isr_vector : { /* This is the output section .isr_vector */
    exceptions.o (.isr_vector) /* This matches all .isr_vector sections in the exceptions.o input file */
  }
  .text : { /* This is the output section .text */
    *(.text) /* This matches all .text sections in all input files */
    *(.text*) /* This matches all .text* sections in all input files */
  }
}
```

The above `SECTIONS` command specifies two output sections in our output file. The `.isr_vector` output section will contain the input section `.isr_vector` of the exceptions.o input file. This can be used, for example, to place a vector table at a specific position in memory. In this case, this would be placed before the `.text` section in our output file.

In contrast, the `.text` output section will contain all `.text` sections in all input files. Notice the use of the wildcard to match any input files. Notice that two lines are present inside the `.text` output section. It is possible to take multiple input sections and merge them into a single output section. In fact, the second line in the `.text` output section `*(.text*)` matches all sections that begin with `.text` into the output section `.text`, meaning that if we had an input section named `.text.mysection` it would also be matched. This second line is specially useful when used in conjunction with the gcc option `-ffunction-sections`. Let's see an example of this in the following code snippet:

```c++
// test.c file
void MyFunction() {
    // Do something here
}

int MySecondFunction() {
    // Do something here too
    return 0;
}
```

If we compile this code into an object file without using `-ffunction-sections` we should expect to see only one .text section containing the both symbols `MyFunction` and `MySecondFunctions`. We can build the object file with `gcc -c -o test.o test.c` . Now we check the symbols with `objdump -S test.o` and obtain:

```c++
test.o:     file format elf64-x86-64

Disassembly of section .text:

0000000000000000 <MyFunction>:
   0:   55                      push   %rbp
   1:   48 89 e5                mov    %rsp,%rbp
   4:   90                      nop
   5:   5d                      pop    %rbp
   6:   c3                      retq

0000000000000007 <MySecondFunction>:
   7:   55                      push   %rbp
   8:   48 89 e5                mov    %rsp,%rbp
   b:   b8 00 00 00 00          mov    $0x0,%eax
  10:   5d                      pop    %rbp
  11:   c3                      retq
```

However, if we build with `gcc -c -o test.o test.c -ffunction-sections` we will see the following output:

```c++
test.o:     file format elf64-x86-64

Disassembly of section .text.MyFunction:

0000000000000000 <MyFunction>:
   0:   55                      push   %rbp
   1:   48 89 e5                mov    %rsp,%rbp
   4:   90                      nop
   5:   5d                      pop    %rbp
   6:   c3                      retq

Disassembly of section .text.MySecondFunction:

0000000000000000 <MySecondFunction>:
   0:   55                      push   %rbp
   1:   48 89 e5                mov    %rsp,%rbp
   4:   b8 00 00 00 00          mov    $0x0,%eax
   9:   5d                      pop    %rbp
   a:   c3                      retq
```

Now each function has it's own section. This is useful if we want to control exact placement of some functions in the output file, as we can now specify the section of the function we want to place. It is also useful when used in conjunction with the`--gc-sections` option of the GNU linker, which will remove any unused input sections from the output file, thus optimizing the size of the target binary.

We must, however, be careful about `--gc-sections`. Some microcontrollers (like the architecture ARMv6m and ARMv7m) require the presence of a table containing the reset and exception vector in some pre-established memory location. This table may be written as a C array and it is usually not referenced by the code itself. This means that it will be an unused symbol and the linker may remove it if we specify `--gc-sections`. It is possible to tell the linker to not remove a specific input section by wrapping it with the command `KEEP`. Here is an example:

```c++
KEEP(exceptions.o (.isr_vector))
```

As well as `-ffunction-sections` separates functions into sections, there is also `-fdata-sections`, which will place each data symbol in multiple sections.

## Controlling the placement of output sections

So far we have seen how to control output sections and what they will contain mapping input sections to them. However, we had no control on where they will be placed on memory. There are a few ways we can specify this. Let's start by defining two types of addresses where symbols can be placed:

  * **LMA** or Load Memory Address. Specifies where the section and associated data shall be loaded into memory.
  * **VMA** or Virtual Memory Address. Specifies the virtual address for the section, which will be used during runtime by the program to access the symbols in it.

Normally, these two addresses are the same, but there are a few cases where they may differ. Think about the case of the output .data section. We need to load this somewhere in persistent memory in our microcontroller, but during runtime, we shall access this section from random access memory. The job of the startup code is to copy the data from the LMA to the VMA to make sure it will be accessible from our program in RAM.

## Implicit placement of output sections

The linker script keeps an internal variable `.` called the **location counter**. This will hold the current memory address. It starts with a value of zero at the top of the file. As we add new sections, it will increment by the size of each section. If we simply don't specify any addresses at all, the placement of each section will be implicitly given by the value of the location counter when the linker gets to that section. In the example above, section `.isr_vector` will be placed at address 0, as we didn't set the location counter before defining it. If we assume that the isr vector takes 1023 bytes, then the `.text` output section will be placed at address 1023, as it is the value of the location counter when the .text section is defined.

Many architectures require code to be aligned to a certain number of bytes. In the case of ARM, it should be aligned to 2 bytes at least. We could ensure alignment of the text section to 4 bytes by explicitly modifying the location counter with the ALIGN function. The align function will introduce the required padding in order to align the location counter.

```c++
SECTIONS
{
  .isr_vector : {
    exceptions.o (.isr_vector) /* We assume this takes 1023 bytes */
  }

  .text : {
    . = ALIGN(4);
    *(.text)
    *(.text*)
  }
}
```

The previous example shows how to align properly the .text output section. It is also possible to explicitly set a value of the location counter before the start of the output section. Let's say we want to place the isr vector at address 0x08000000 and the code at 0x08000400. We could write the following:

```c++
SECTIONS
{
  . = 0x08000000;
  .isr_vector : {
    exceptions.o (.isr_vector) /* We assume this takes 1023 bytes */
  }

  . = 0x08000400;
  .text : {
    . = ALIGN(4);
    *(.text)
    *(.text*)
  }
}
```

These examples, however, set both the LMA and VMA to the same address and therefore cannot be relocated during runtime.

## Placement of output sections using explicit addresses

In order to specify the VMA of an output section, we can simply use the address where we wish to place the output section, like the following example:

```c++
.isr_vector 0x08000000 : {
  exceptions.o (.isr_vector)
}
```

In the previous example, we place the output section `.isr_vector` at address `0x08000000`. This will set both the VMA and LMA. If we wish to load a section somewhere else in memory we could do the following:

```c++
.data 0x20000000 : AT(0x08004000) {
  *(.data)
  *(.data*)
}
```

This will assign output section `.data` with VMA `0x20000000` and LMA `0x08004000`. The AT function is required by the syntax of the linker. It simply indicates the linker that the address is the LMA instead of the VMA. In short, this linker script snippet will load the section into memory at address 0x08004000, but the code will access this section during runtime at address 0x20000000.

## Placement of output sections using regions

The last and preferred option for placing output sections is to use regions. Instead of directly assigning a specific set of addresses to the target section we could define an array of memory regions that details the available memories in our system. An example is provided in the following snippet.

```c++
MEMORY
{
  FLASH (rx)      : ORIGIN = 0x08000000, LENGTH = 1024K
  SRAM (xrw)      : ORIGIN = 0x20000000, LENGTH = 256K
  SDRAM (xrw)     : ORIGIN = 0x90000000, LENGTH = 8M
}
```

Each memory region can have a list of attributes that specify the permissions for each memory region. Possible attributes are:

  * `r`: read attribute
  * `w`: write attribute
  * `x`: execute attribute
  * `a`: allocate attribute
  * `l`: load attribute

These attributes will be matched against the attributes of each section. For instance, .rodata and .text would be placed in Flash because they are not writable. However, things are a bit more complex when two regions have the same attributes. In order to place the output in a specific region we could indicate it using the following syntax:

```c++
.isr_vector : {
  exceptions.o (.isr_vector)
} > FLASH
```

This will place the isr vector section in the FLASH region. Both LMA amd VMA will be the same. How about loading the section to FLASH but setting the virtual memory address to SRAM? We could use this syntax:

```c++
.data {
  *(.data)
  *(.data*)
} > RAM AT> FLASH
```

An advantage of using regions is that, since they have maximum sizes, the linker can issue an error when a region is not large enough to fit all the data. If this happens we may get an error message like this:

```c++
section `.text' will not fit in region `FLASH'
region `FLASH' overflowed by 125 bytes
```

## Specifying symbols in the linker script

It is possible to create new symbols in the linker script and lint to them in our code. This is particularly useful for the startup code, where we need to provide the LMA and VMA of the .data section, as well as the size. Thankfully we can perform symbol assignments directly in the linker script. Let's see an example:

```c++
  .data :
  {
    _data_start = .;
    *(.data)
    *(.data*)
    _data_end = .;
  } >RAM AT>FLASH

  _data_size = _data_end - _data_start;

  /* Obtain the load address (LMA) of the data section */
  _data_loadaddr = LOADADDR(.data);
```

The `_data_start` symbol is placed at the beginning of the output data section (this is, the VMA address of .data). Similarly, the `_data_end` symbol is placed at the end of the data section symbol. We can perform some arithmetic in order to calculate the size of the data section and store it in `_data_size`. Finally, the `LOADADDR` function can be used to obtain the LMA of `.data`.

Now we can access these symbols from our startup code in a similar fashion to what we did in our previous article about [startup code](/post/2019-01-03-arm-cortex-m-startup-code-for-c-and-c/).

```c++
extern std::uint8_t _data_start;
extern std::uint8_t _data_size;
extern std::uint8_t _data_loadaddr;
std::copy(&_data_loadaddr, &_data_loadaddr + (uint32_t)&_data_size, &_data_start);
```

Notice that we declare these variables as external. The linker will provide proper addresses for them. Symbols defined by the linker do not have any allocated memory, but rather reside at a specific memory address. Since we care about the address of these symbols, the proper way to access them is to dereference the variable. Yes, this is the proper syntax.

## Some final thoughts

I hope this article gave you enough confidence to face the linker and maybe even write your own linker script next time you start a project. Even though most of the time we can get away with just using the default linker script, this is particularly useful when we have multiple types of memory (maybe some are tightly coupled to the core and others are larger and maybe are cached). Having the ability to control the exact placement of code and data for your program will allow optimizations to take place and avoid accessing the data only via pointers to the specific memory addresses.

We could even access the hardware in a completely memory mapped fashion with the linker. Think about having the following definition:

```c++
/* define structure of Port Pin*/
typedef struct {
    volatile unsigned int Bit0:1;
    volatile unsigned int Bit1:1;
    volatile unsigned int Bit2:1;
    volatile unsigned int Bit3:1;
    ...
    volatile unsigned int Bit31:1;
} S_GPIO_REG;

S_GPIO_REG gpio_reg __attribute__((section(".bss.gpio_reg")));
```

This would declare a 32 bit register and we would be able to map it at the specific address where the hardware register is located (let's say address 0x40002000) with the following linker definition:

```c++
.gpio_reg 0x40002000 {
  *(.bss.gpio_reg)
}
```
