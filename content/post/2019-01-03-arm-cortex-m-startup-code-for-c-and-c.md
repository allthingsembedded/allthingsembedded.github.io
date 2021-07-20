---
id: 152
title: ARM Cortex-M Startup code (for C and C++)
date: 2019-01-03T09:00:50+00:00
author: Javier Alvarez
layout: post
tags:
  - ARM
  - C
  - Cortex-M
  - Embedded
  - Firmware
  - Linker Script
  - NVIC
  - startup code
  - uC
---
When developing bare metal applications it is required to supply some functions that we normally take for granted when developing code for mainstream OS's. Setting the startup code is not inherently difficult but beware: some of the nastiest bugs you will ever see on bare metal can come from the startup code.

What is actually needed to start the execution of the main function? Well, there are a few things that the C and C++ language specifications assume when starting a new program. Some of them are:

  * All uninitialized variables are zero. These are stored in the `.bss`section of the final elf file.
  * All initialized variables are actually initialized. These are stored in the `.data` section of the final elf file.
  * All static objects are initialized (they may need to get their constructors called if they are not trivial). Function pointers to these static initialization routines are stored in the `.init_array` section.
  * The **stack pointer** is correctly set during startup. It actually necessary to set it up before even reaching the C or C++ code, since function definitions may store local variables, parameters and the return address on the stack. Depending on the ABI some of these may end up on processor registers for optimization purposes.
  * Some **other machine dependent features** like enabling access to the floating point coprocessor (VFP coprocessor on most ARM microcontroller architectures).

For this article, we will examine the startup code needed when your code section (`.text`) is placed into Flash memory, while the data (`.data` and `.bss` sections) is placed in SRAM, which is the most common scenario. Other memory layouts will need specific changes to make sure that the application can be run properly.

In the case of the arm-none-eabi-gcc toolchain, there are some sample startup codes for each processor located in the following directory (relative to the directory of the toolchain):

`share/gcc-arm-none-eabi/samples/startup/startup_ARMCMX.S`

Default startup code is given in the assembly language for the target processor. It makes sense, however, reimplementing this code in C or C++, for the purposes of creating a more generic code that can be used for multiple devices. The sample code provided by ARM does the following tasks:

  * Define the **vector table for the NVIC** (`__isr_vector`). The NVIC is the interrupt controller. Upon an exception or interrupt it looks up the address of the corresponding ISR. This table contains the stack initialization value, the reset vector, all exception vectors, and external interrupt vectors. The code provides weak definitions that link the `default_handler` (an endless loop) with all exceptions and interrupts. This serves as a trap for all undefined ISR's by the application. When a system reset occurs, execution starts from the reset vector and the processor loads the value of the MSP (main stack pointer) with the highest ram address (defined by the linker as `__StackTop`).
  * **Initialize the `.bss` section to zero.** It uses the symbols `__bss_start__` and `__bss_end__` to obtain the address range that should be set to zero. These symbols are defined in the linker script.
  * **Initialize the `.data` section**. This section is defined in the linker script with different VMA (Virtual address) and LMA (Load address) since it has to be loaded to Flash, but used from RAM when the execution starts. To make sure that all C code can use the initialized data within the `.data` section, it has to be copied over from Flash to RAM by the startup code. To accomplish this it uses the following symbols defined by the linker: `__data_start__`, `__data_end__` and `__etext` (this last symbol describes the end of the `.text` section, which is assumed to be the start address of the LMA of the `.data` section).

**At the time of this writing (gcc-arm-none-eabi-7-2018-q2-update) the sample startup code doesn't directly support C++**. We will write the missing code so that C++ can be used with these processors without fear of running into trouble.

## Adding support for C++ in the startup code (written in C++!)

In this section we will rewrite the startup code for an ARM Cortex-m core with added support for C++. First, let's start with the NVIC Vector table. It can be defined as follows:

```c++
#define DEFINE_DEFAULT_ISR(name) \
    extern "C" \
    __attribute__((interrupt)) \
    __attribute__((weak)) \
    __attribute__((noreturn)) \
    void name() { \
        while(true); \
    }

DEFINE_DEFAULT_ISR(defaultISR)
DEFINE_DEFAULT_ISR(NMI_Handler)
DEFINE_DEFAULT_ISR(HardFault_Handler)
DEFINE_DEFAULT_ISR(MemManage_Handler)
DEFINE_DEFAULT_ISR(BusFault_Handler)
DEFINE_DEFAULT_ISR(UsageFault_Handler)
DEFINE_DEFAULT_ISR(SVC_Handler)
DEFINE_DEFAULT_ISR(DebugMon_Handler)
DEFINE_DEFAULT_ISR(PendSV_Handler)
DEFINE_DEFAULT_ISR(SysTick_Handler)
DEFINE_DEFAULT_ISR(USART1_IRQHandler)

extern std::uint32_t __StackTop;
extern "C" void ResetHandler();

const volatile std::uintptr_t g_pfnVectors[]
__attribute__((section(".isr_vector"))) {
    // Stack Ptr initialization
    reinterpret_cast<std::uintptr_t>(&__StackTop),
    // Entry point
    reinterpret_cast<std::uintptr_t>(ResetHandler),
    // Exceptions
    reinterpret_cast<std::uintptr_t>(NMI_Handler),              /* NMI_Handler */
    reinterpret_cast<std::uintptr_t>(HardFault_Handler),        /* HardFault_Handler */
    reinterpret_cast<std::uintptr_t>(MemManage_Handler),        /* MemManage_Handler */
    reinterpret_cast<std::uintptr_t>(BusFault_Handler),         /* BusFault_Handler */
    reinterpret_cast<std::uintptr_t>(UsageFault_Handler),       /* UsageFault_Handler */
    reinterpret_cast<std::uintptr_t>(nullptr),                  /* 0 */
    reinterpret_cast<std::uintptr_t>(nullptr),                  /* 0 */
    reinterpret_cast<std::uintptr_t>(nullptr),                  /* 0 */
    reinterpret_cast<std::uintptr_t>(nullptr),                  /* 0 */
    reinterpret_cast<std::uintptr_t>(SVC_Handler),              /* SVC_Handler */
    reinterpret_cast<std::uintptr_t>(DebugMon_Handler),         /* DebugMon_Handler */
    reinterpret_cast<std::uintptr_t>(nullptr),                  /* 0 */
    reinterpret_cast<std::uintptr_t>(PendSV_Handler),           /* PendSV_Handler */
    reinterpret_cast<std::uintptr_t>(SysTick_Handler),          /* SysTick_Handler */
    // External Interrupts
};
```

The code adds a `g_pfnVectors` global vector table within the section `.isr_vector`. This guarantees that this table will be placed at the start of the Flash memory since it is declared as an input section in the linker script before any other `.text` section. This is where the processor will look for it right after booting. 

The `__StackTop` variable is actually defined in the linker script. We have simply declared its existence in our C++ code. Symbols defined in the linker script actually define the address of the variable matched by that symbol in C++, meaning that the variable `__StackTop` will be located at the address determined by the symbol in the linker script. Since we need the location of the top of the stack, we store the address of the `__StackTop` variable.

The ResetHandler is the function that will get executed right after a system reset. When a reset occurs it will start executing the code at the address indicated by the `ResetHandler` function pointer. `DEFINE_DEFAULT_ISR` defines ISR functions that contain an endless loop. Since they are defined with the `weak` attribute they can be easily overridden from the application code. Also, the interrupt attribute is used to indicate to the compiler that it needs to save the execution context before starting the execution of code within the ISR. It also restores the context before returning.

The next bit of code is the actual `ResetHandler`. It looks like this:

```c++
#include <algorithm>
#include <cstdint>
#include "core_cm7.h"

static void BoardInitialization() {
    SCB->CPACR |= ((3UL << 10*2)|(3UL << 11*2));  /* set CP10 and CP11 Full Access */
}

extern "C"
void ResetHandler() {
    // Initialize data section
    extern std::uint8_t __data_start__;
    extern std::uint8_t __data_end__;
    extern std::uint8_t __etext;
    std::size_t size = static_cast<size_t>(&__data_end__ - &__data_start__);
    std::copy(&__etext, &__etext + size, &__data_start__);

    // Initialize bss section
    extern std::uint8_t __bss_start__;
    extern std::uint8_t __bss_end__;
    std::fill(&__bss_start__, &__bss_end__, UINT8_C(0x00));

    // Initialize static objects by calling their constructors
    typedef void (*function_t)();
    extern function_t __init_array_start;
    extern function_t __init_array_end;
    std::for_each(&__init_array_start, &__init_array_end, [](const function_t pfn) {
        pfn();
    });

    BoardInitialization();

    // Jump to main
    asm ("bl main");
}
```

This is all the startup code required. Keep in mind that this code doesn't set the stack pointer. The stack pointer needs to hold a valid value before we can even begin to execute any C code. However, this is not necessary for these processors, since it gets set automatically by the processor using the value indicated in the NVIC vector table. We initialize the .data section using the `std::copy` function from the C++ STL (This copies all values from the LMA to the VMA). The next bit of code fills all `.bss` bytes with 0x00 by using the `std::fill` function.

Next is the initialization of static objects by calling their constructors. This step is only required for C++, since in C global variables can be initialized without calling any constructor and, as such, this step can be skipped (As the sample startup code provided within the arm-none-eabi-gcc toolchain does). However, keep in mind that if you forget to do this, static global objects will remain uninitialized and your program will not work as expected. For this, we are using the `std::for_each` function, which acts as a wrapper for a for loop, making use of iterators.

Then we jump to the board initialization. In this case we are simply giving access to the floating point coprocessor. This may not be required if you are not using the coprocessor or you don't have one.

The last step is to jump to the main function. Since the Gcc C++ compiler doesn't allow explicit function calls for the main function I wrote this last part using inline ASM.

**IMPORTANT NOTE**: Never initialize the stack pointer again at the start of the `ResetHandler` function if you write it in C or C++ (It must always be done before reaching any C code). Since `ResetHandler` is actually a function it reserves memory for the local variables by moving the stack pointer upon function entry. Setting the stack pointer again after this effectively frees the memory allocated by the function for its local variables and may result in memory corruption that will haunt you all through the code. For example, it is not difficult to imagine that if the initialization value of 0x00 for the `.bss` section was actually given through a local variable this variable would be freed after setting the stack pointer and subsequent calls to `std::copy` may overwrite the value of the variable so that when your code reaches the `std::fill` function the `.bss` will be filled with some garbage values instead of 0.
