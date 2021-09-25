---
title: "Bare Metal Register Access API"
date: 2021-09-25T20:26:21+02:00
draft: true
---

## Introduction to memory-mapping

**Note:** This is introductory material for those who are not yet familiar with the concept of memory-mapping. If you are already experienced with memory-mapping feel free to jump to the next section. Most likely you won't miss anything new.

One of the most common ways of accessing peripherals from a CPU is `memory-mapping`. In short, this means that the address space of the CPU has some addresses that when accessed read/write peripheral's registers. In order to access such peripherals from our code there are multiple strategies that could be used. This post will explore multiple alternatives and discuss their differences and fitness for their unique task.

As an example of `memory-mapping` we will have a look at a `STM32F030` microcontroller. This is one of the simplest 32-bit ARM Cortex-M MCUs from ST Microelectronics. The architectural information we need is normally described in a [`Reference Manual`](https://www.st.com/resource/en/reference_manual/rm0360-stm32f030x4x6x8xc-and-stm32f070x6xb-advanced-armbased-32bit-mcus-stmicroelectronics.pdf) document. This MCU contains an `ARM Cortex-M0` core that interfaces via a `Bus Matrix` with multiple peripherals. The bus matrix provides access to multiple components of the MCU. Amongst them, we have the following:

  * Internal `RAM` memory.
  * Internal `Flash` memory.
  * A connexion to an `AHB1` bus, which bridges to an `APB` bus.
     * `AHB` is a bus designed by ARM part of the `AMBA` standard. It is a de-facto standard for MCU buses in the ARM Cortex-M world and normally interfaces to high speed peripherals.
     * `APB` is another bus also part of the `AMBA` standard. It is a lower-speed bus dedicated to peripheral accesses, which normally do not require a large throughput.
  * A second `AHB2` bus dedicated to `GPIO` ports.
     * Notice how GPIO ports have a dedicated `AHB2` bus. This makes sense if we would ever need to perform bitbanging of some protocol using direct GPIO control. In this case, having fast access to the GPIO ports is a definitive advantage.

This architecture already hints that almost all peripherals are accessed via the `APB` bus. But, how do we access this bus from the CPU? In order to answer this question, we need to clarify how these buses work. When a bus is connected (interfaced) to another it has associated address ranges. If the address belongs to the target bus, then it is responsible of forwarding the request over this bus and reaching the peripheral located at the requested address.

For instance, accessing any address in the range of `0x48000000` and `0x48001800` will be forward the request through the `AHB2` bus into the corresponding peripheral. The address range reserved for this bus is subdivided into address ranges reserved for peripherals. Therefore, to access `GPIOA`, which is mapped via the AHB2 bus, we can access any address between `0x48000000` and `0x48000400`. The `0x48000000` address is also known as the `base address` of the peripheral, meaning that it is the first address that actually reaches the peripheral. Peripheral registers are often defined with respect to the base address, just providing an offset.

Now that we know the address range of the GPIO peripheral, we need to make sense of what each of the addresses in this range mean to the `GPIOA` peripheral. Thankfully this is quite a simple peripheral, so it will be easy to describe. This block of addresses is subdivided into registers. Each of the registers has a single associated address and size. The size of the register is normally native to the bus size of the CPU, which in this case is 32 bits.

The image below shows some of the registers of the GPIO peripheral.

<p align="center">
<img src="/images/bare_metal_reg_access/gpio_map.png" alt="GPIO Registers for an STM32F030 MCU" width="600" style="align-content:center;"/>
</p>

Therefore, an access to the address `0x48000000` will modify the `GPIOA_MODER` register, used to change the operating mode of the GPIO. Each bit in this register has an associated meaning also defined in the reference manual. Notice that some of these bits have a reset value different than 0. That is, when the peripheral is reset, this bit will have this reset value.

Even though it is not shown in the previous picture, some bits in some registers might not be writable. For example, the `GPIOA_IDR`, which stands for __Input Data Register__, is a read-only register. The bits in this register cannot be written, as they would have no meaning (we cannot change an input value, after all).

## Raw pointer access

The simplest way we can use to access a peripheral register is casting its address into a word pointer. By dereferencing this pointer we can then read or write the peripheral register. This can look something like the following:

```c++
uint32_t *gpioa_moder_ptr = reinterpret_cast<uint32_t*>(0x4800'0000);
```

With this, we can write all 32 bits of the registers in a single go:

```c++
*gpioa_moder_ptr = new_desired_value;
```

Or read them also in a single access:

```c++
auto gpioa_moder_value = *gpioa_moder_ptr;
```

### Volatile access

There is a catch here, though. Registers often can change in HW without software interaction. This causes a potential issue with the compiler optimizer, as some accesses that might seem redundant to the compiler might actually be critical. For example, let's say we need to wait until some HW FIFO is not full. We could write the following code:

```c++
uint32_t* fifo_status = reinterpret_cast<uint32_t*>(...);

// Wait until the status is not full
while ((*fifo_status & FIFO_STATUS_FULL_MASK) != 0) { }
```

But the previous code has a fatal flaw. Given that nowhere in this code we change the address pointed by `fifo_status`, the compiler is able to optimize the code in the following way:

```c++
uint32_t* fifo_status = reinterpret_cast<uint32_t*>(...);

// Wait until the status is not full
auto fifo_full = *fifo_status & FIFO_STATUS_FULL_MASK;
while (fifo_full != 0) { }
```

And with this, we can basically wait forever if the fifo was full. Since that is not what we wanted, as this register can change at any point in time, we need to mark the register access as `volatile`. One way of doing this would be:

```c++
volatile uint32_t* fifo_status = reinterpret_cast<volatile uint32_t*>(...);

// Wait until the status is not full
while ((*fifo_status & FIFO_STATUS_FULL_MASK) != 0) { }
```

Now the compiler cannot optimize out the access in every iteration of the loop, therefore, our code is correct now.

Advantages of the Raw pointer access:
  - No infrastructure required other than knowing the addresses of registers and their bits.
  - Easy to understand and comprehend.
  - Register access is quite explicit.

Disadvantages of the raw pointer access:
  - Manually writing the addresses can be very tiresome and errorprone.
  - Accessing individual bits in the register can be complicated (requiring building masks and performing bitwise operations manually).
  - Easy to forget the `volatile` qualifier when declaring the pointer. Normally this isn't such a problem for people that have been bitten by `volatile` access before, but otherwise it is bound to happen.
  - There is no real type safety. We can write anything into any register, even if the peripherals don't match.
  - Basically no abstraction over the bare register concept.
  - Pretty close to writing assembly at this point.
  - Difficult to unit test any code on non-target platforms. Mocking register accesses is not possible with this model.

Given all the drawbacks in the previous list, it seems clear that we should really look for a safer register access abstraction that tries to improve our concerns in the list of disadvantages. Let's examine different approaches.

## Union and Bitfield access

  - Advantages:
    - It's pretty great to be able to access bits without manipulating bit offsets.
    - Volatile access is guaranteed by the struct definition.

  - Drawbacks:
    - C++ disallows using unions for type punning, yet that's exactly what we are doing here. Normally this would be fine, as most compilers would choose C compatibily in this scenario, making the problem irrelevant. However, this cannot be guaranteed.
    - The code is not portable. Bitfields are not portable because the bitfield order implementation defined.
    - Can only safely use primitive types in unions. Mostly ok for register access.
    - No control over what is writable and what is not.
    - Little control over when the register is actually read/written. Bit access results in multiple read-writes, which may not be efficient or desired (What if we need to ensure all bits are modified in a single write?).
    - No safety over what fields can be changed.
    - No proper type safety, as bits are still primitive types.

## A safer object oriented API and strongly-typed fields

 - Advantages:
    - Great control over field types and access.
    - Explicit access is managed by explicit methods.
    - Functional approach to register writes and register modification actions.
    - Register access is guaranteed to be volatile
    - No extra overhead by unnecessary volatile qualifiers.
 - Drawbacks:
    - Usage of lambdas can mean that the developer might be paying a large cost in runtime if they are not used wisely.
      In reality, most of the time, the function will be inlined, so this will not constitute a problem in practice.
    - More code is needed to define the API, as it is not purely declarative as with the union example.
    - Large overhead if optimization level is -O0`.

## Automating the job with SVD

We can automate the generation of the register access code by using svd files.

