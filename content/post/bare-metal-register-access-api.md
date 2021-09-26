---
title: "Bare Metal C++ Register Access API"
date: 2021-09-25T20:26:21+02:00
draft: true
---

## Introduction to memory-mapping

**Note:** This section is introductory material for those who are not yet familiar with the concept of memory-mapping. If you are already experienced with memory-mapping feel free to jump to the next section. Most likely you won't miss anything new.

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

Note that the use of `reinterpret_cast` in the previous examples can actually violate the `strict aliasing rules`. Therefore, care must be taken when using `reinterpret_cast` in this context to ensure that no other object is using this memory as a different type or the result will be `undefined behavior`. If you are interested in this topic, have a look at [this](https://gist.github.com/shafik/848ae25ee209f698763cffee272a58f8) post from Shafik Yaghmour.


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

**Advantages** of the Raw pointer access:
  - No infrastructure required other than knowing the addresses of registers and their bits.
  - Easy to understand and comprehend.
  - Register access is quite explicit.

**Disadvantages** of the raw pointer access:
  - Manually writing the addresses can be very tiresome and errorprone.
  - Accessing individual bits in the register can be complicated (requiring building masks and performing bitwise operations manually).
  - Easy to forget the `volatile` qualifier when declaring the pointer. Normally this isn't such a problem for people that have been bitten by `volatile` access before, but otherwise it is bound to happen.
  - There is no real type safety. We can write anything into any register, even if the peripherals don't match.
  - Basically no abstraction over the bare register concept.
  - Pretty close to writing assembly at this point.
  - Difficult to unit test any code on non-target platforms. Mocking register accesses is not possible with this model.

Given all the drawbacks in the previous list, it seems clear that we should really look for a safer register access abstraction that tries to improve our concerns in the list of disadvantages. Let's examine different approaches.

## Getting help from unions and bitfields

For this section we will explore an alternative that ARM uses in its CMSIS libraries. This alternative consists on using bitfields to separate bit accesses and work with regsiters and bits in a more declarative way instead of procedural. So, for instance, let's say that we have a register with the following fields:

```c++
/// Status register :
///   * Offset = 0x10
///   * Size = 32 bits
///
///             |   Bit 0   |   Bit 1   |   Bit 2   |   Bit 3   |   Bit 4   |   Bit 5   |   Bit 6    |   Bit 7     |
/// Field name  |   busy    |  state[0] |  state[1] |   -       |   -       |   -       | ovfl_error | frame_error |
/// Reset value |   0       |   X       |   X       |   X       |   X       |   X       |   0        |   1         |
/// Type        |   RO      |   RO      |   RO      |   -       |   -       |   -       |   RCW      |   RCW       |
///
/// RO: Read only register. Writes are ignored.
/// RCW: Read is valid and sticky. The register is clear-on-write, write a 1 to reset this bit back to 0.
```

With this in mind, we could define a bitfield that represents this register:

```c++
struct StatusRegister {
    volatile uint32_t busy : 1;
    volatile uint32_t state: 2;
    volatile uint32_t : 3;
    volatile uint32_t ovfl_error : 1;
    volatile uint32_t frame_error : 1;
};
```

There are a couple of potential issues we should be aware of though:
  * The __bit order__ in a bitfield is `implementation defined`, therefore, we __need__ to know our compiler behavior to ensure that this code will behave as expected. This also means that __this code is not portable__. In most common compilers, the order of bits in the bitfield starts from the least significant bit first, so buiding with `arm-none-eabi-gcc` or `armclang` will produce correct results for this particular case.
  * The __types__ a bitfield can hold are limited to __integral types and booleans__. Compilers can augment the number of supported types, but yet again, this is `implementation defined` and varies from compiler to compiler. 

Now, assumming we are not concerned with the portability of this code, we can continue building on this solution. The next obvious thing we want to do is access the whole register in one go (without needing to read bits individually). To do so, maybe we could use a union type?

Turns out that, while in C using a union for type punning (accessing the bits of one object as another type) is valid, C++ disallows type punning using unions and explicitly makes it `undefined behavior`. At this point things are really getting hairy, aren't they? Well, in practice, the `ARM CMSIS libraries` use unions for type punning in an `extern "C"` block (see [here](https://github.com/ARM-software/CMSIS_5/blob/d5d9f6dea35a97e08bfff0b3fe1e41d9ab303e3c/CMSIS/Core/Include/core_cm4.h#L321)), so that should still be a valid alternative. Let's see an example of how that would look like:

```c++
#ifdef __cplusplus
extern "C" {
#endif  // __cplusplus

union StatusRegister {
    struct {
        volatile uint32_t busy : 1;
        volatile uint32_t state: 2;
        volatile uint32_t : 3;
        volatile uint32_t ovfl_error : 1;
        volatile uint32_t frame_error : 1;
    } bits;
    volatile uint32_t reg;
};

#ifdef __cplusplus
}
#endif  // __cplusplus
```

Phew! Ok, we have arrived to a potentially decent solution, but how do we handle all the registers of a given peripheral? Probably the easiest is to make sure that they are part of a single structure of data. Let's see an example:

```c++
struct UartRegisters {
    StatusRegister status_reg;
    uint32_t [7]; // Sometimes we need to introduce padding to make sure the register offsets are correct!
    DataRegister data_reg;
    ControlRegister control_reg;
    InterruptRegister interrupt_reg;
};
```

The only missing piece of the puzzle now is to put it all together and instantiate the registers. We could use `reinterpret_cast` as in the previous section:

```c++
UartRegisters* uart_regs = reinterpret_cast<UartRegisters*>(UART_BASE_ADDRESS);
```

This is ok, but testing a uart driver may become a bit problematic, since the `UART_BASE_ADDRESS` will not be valid in unit tests. An easy solution to this is use some help from our friend the `Linker Script`.

```c++
MEMORY
{
  UART : ORIGIN = 0x40014000, LENGTH = 1K
}

SECTIONS {
  .uart_regs (NOLOAD) : {
    *(.bss.uart_regs)
  } > UART
} INSERT BEFORE .bss;
```

With this `Linker Script` we can now declare a static instance of our registers and map it to the correct section like:

```c++
static UartRegisters __attribute__((section(".bss.uart_regs"))) uart_regs;
```

In a unit test, the `.uart_regs` output section will not be defined and therfore the input section `.bss.uart_regs` will form part of the output `.bss` section, making it just part of the program's global unitinialized variables.

Now that we have achieved a viable solution using bitfields and unions let's look at how it compares against the previous solution

  - **Advantages**:
    - It's pretty great to be able to access bits without manipulating bit offsets.
    - Volatile access is guaranteed by the struct definition. No need to worry about it when accessing the peripheral struct.

  - **Drawbacks**:
    - Significant amount of non-portable `implementation-defined` code and potentially containing `undefined behavior`. In particular:
        - Bitfields are not portable because the bitfield order is `implementation defined`.
        - Type punning via unions in C++ is undefined behavior. Actually, the only safe way to perform type punning in C++ is using `memcpy`.
        - Limited type safety, as the bits in a bitfield can only contain integral types or booleans. Using other types is `implementation-defined` as defined by the compiler you are using.
    - No control over what is writable and what is not. We cannot make certain bits in a bitfield read-only, but registers may have read-only bits in any given register.
    - Little control over when the register is actually read/written. Bit access results in multiple read-writes, which may not be efficient or desired (What if we need to ensure all bits are modified in a single write?).
    - No proper type safety, as bits are still integral types or booleans.

Let me demonstrate the register access drawback of wanting to do atomic register changes of multiple bits:

```c++
// The following results in 2 read-modify-write sequences of the UART Status register:
uart_regs.status_reg.bits.ovfl_error = 1;
uart_regs.status_reg.bits.frame_error = 1;

// If we wanted to clear multiple bits in a single register write we need to create a temporary variable

// Read the status register
StatusRegister status_reg = uart_regs.status_reg;

// Modify desired bits in the temporary variable
status_reg.bits.ovfl_error = 1;
status_reg.bits.frame_error = 1;

// Write result to the UART Status register
uart_regs.status_reg.reg = status_reg.reg;
```

Even in the second case, the situation is not ideal. Remember that the bitfields of the `StatusRegister` are `volatile`, so we are removing access optimization even to the temporary variable. Surely we could do better than that!

## A safer API with strongly-typed fields

Well, given that we are using `C++` and the language has largely evolved over primitive `C` types, there must be a better alternative to handle register accesses. So far all the code could be compiled in `C` as well and with no `undefined behavior`!. The following alternative will make used of functional programming features as well as object oriented features. Let's start with creating an abstraction for a `memory-mapped` register:

```c
class Register {
 public:
  Register(volatile uint32_t* addr) : m_addr(addr) {}

  /**
   *  @brief Reads the value of the register returning it.
   */
  inline uint32_t read() {
    return *m_addr;
  }

  /**
   *  @brief Writes the register with the passed value.
   */
  inline void write(uint32_t value) {
    *m_addr = value;
  }

  /**
   *  @brief Modifies the value of the register by running a read-modify-write cycle. 
   *         The mod_functor is called with the read register value as an argument and 
   *         should return the desired value to be written to the register.
   */
  inline void modify(auto mod_functor) {
    *m_addr = mod_functor(*m_addr);
  }

 private:
  volatile uint32_t* const m_addr;
};
```

With this piece of code we can now use this class for any randon 32-bit register. Notice that we take advantage of function pointers or closures in order to modify a register value and abstract the `read-write-modify` cycle. We don't know how the register will be modified, as that should depends on the user code, but we know for sure that the register needs to be read first and later written after all modifications are done. That is a handy functional approach to this problem that we will keep using later.

However, you may ask what is the impact of using a closure as a function parameter, isn't that too costly in runtime? Well, no! Given that the function is marked `inline` the compiler should be clever enough to figure it out. In fact you can see GCC does it [here](https://godbolt.org/#g:!((g:!((g:!((h:codeEditor,i:(filename:'1',fontScale:14,fontUsePx:'0',j:1,lang:c%2B%2B,selection:(endColumn:1,endLineNumber:37,positionColumn:1,positionLineNumber:37,selectionStartColumn:1,selectionStartLineNumber:37,startColumn:1,startLineNumber:37),source:'%0A%23include+%3Ccstdint%3E%0A%0Aclass+Register+%7B%0A+public:%0A++Register(volatile+uint32_t*+addr)+:+m_addr(addr)+%7B%7D%0A%0A++uint32_t+read()+%7B%0A++++return+*m_addr%3B%0A++%7D%0A%0A++void+write(uint32_t+value)+%7B%0A++++*m_addr+%3D+value%3B%0A++%7D%0A%0A++void+modify(auto+mod_functor)+%7B%0A++++*m_addr+%3D+mod_functor(*m_addr)%3B%0A++%7D%0A%0A+private:%0A++volatile+uint32_t*+const+m_addr%3B%0A%7D%3B%0A%0Avoid+modify_reg()+%7B%0A++uint32_t+status_reg_mem%3B%0A++Register+status_reg+%7B%26status_reg_mem%7D%3B%0A++%0A++status_reg.modify(%5B%3D%5D(uint32_t+r)+%7B%0A++++uint32_t+w+%3D+r%3B%0A++++if+(r+%26+1)+%7B%0A++++++w+%7C%3D+2%3B%0A++++%7D%0A++++return+w%3B%0A++%7D)%3B%0A%7D%0A%0A'),l:'5',n:'0',o:'C%2B%2B+source+%231',t:'0')),k:49.99999999999999,l:'4',n:'0',o:'',s:0,t:'0'),(g:!((h:compiler,i:(compiler:arm1021,filters:(b:'0',binary:'1',commentOnly:'0',demangle:'0',directives:'0',execute:'1',intel:'0',libraryCode:'0',trim:'1'),flagsViewOpen:'1',fontScale:14,fontUsePx:'0',j:1,lang:c%2B%2B,libs:!(),options:'-Os+-std%3Dgnu%2B%2B20+-mcpu%3Dcortex-m0plus',selection:(endColumn:1,endLineNumber:1,positionColumn:1,positionLineNumber:1,selectionStartColumn:1,selectionStartLineNumber:1,startColumn:1,startLineNumber:1),source:1,tree:'1'),l:'5',n:'0',o:'ARM+gcc+10.2.1+(none)+(C%2B%2B,+Editor+%231,+Compiler+%231)',t:'0')),k:49.99999999999999,l:'4',n:'0',o:'',s:0,t:'0')),l:'2',n:'0',o:'',t:'0')),version:4).

Now, for the next step, let's create an abstraction for a specific register. We will use the same status register as defined in the previous section for the example.

```c++
/**
 * @brief Implements an abstraction for a StatusRegister for a hypothetical UART peripheral.
 */
class StatusRegister : Register {
 public:
  /**
   * @brief States of the Uart
   */
  enum class State {
    Active,
    Idle,
    Fault
  };

  /**
   * @brief Abstraction for the fields of a register.
   */
  class Fields {
   public:
    Fields() { 
      // Set the register temporary variable to the reset value of the register
      memset(&m_bits, 0, sizeof(m_bits));
    }
    explicit Fields(uint32_t value) { 
      // Type punning via memcpy is allowed in C++
      memcpy(&m_bits, &value, sizeof(value));
    }

    inline bool busy() const { return m_bits.busy; }
    inline State state() const { return static_cast<State>(m_bits.busy); }
    inline bool frame_error() const { return m_bits.frame_error; }
    inline bool overflow_error() const { return m_bits.ovfl_error; }

    inline void clear_overflow_error() { m_bits.ovfl_error = 1; }
    inline void clear_frame_error() { m_bits.frame_error = 1; }

    inline uint32_t reg_value() const { 
      uint32_t value = 0;
      memcpy(&value, &m_bits, sizeof(value));
      return value;
    }

   private:
    struct {
      uint32_t busy: 1;
      uint32_t state: 2;
      uint32_t : 3;
      uint32_t ovfl_error: 1;
      uint32_t frame_error: 1;
      uint32_t : 24; // Pad bitfield to 32 bits
    } m_bits;
  };

  StatusRegister(volatile uint32_t* addr): Register(addr) {}

  Fields read() { return Fields {Register::read()}; }

  void write(auto callable) { 
    Fields f;
    callable(f);
    Register::write(f.reg_value());
  }

  void modify(auto callable) { 
    Register::modify([=](uint32_t r_val) {
        Fields r {r_val};
        Fields w;
        callable(r, w);
        return w.reg_value();
    });
  }
};

void example_reg_access() {
  uint32_t status_reg_mem;
  StatusRegister status_reg {&status_reg_mem};
  
  status_reg.modify([=](const auto& r, auto& w) {
    if (r.frame_error()) {
      w.clear_overflow_error();
    }
    w.clear_frame_error();
  });
}
```

The `StatusRegister` class clearly states how to read, write or modify the register, using instances of type `Fields` to interact with these functions. `Fields` can either be instantiated with the value of the register or with the reset value of the register (default constructor). 

The `StatusRegister::Read` method simply returns a `Fields` instance from which we can read the state of the regsiter.

In order to write the register, one can use `StatusRegister::Write`, which takes a closure that accepts a `Fields` as an argument. This `Fields` instance is default constructed, but the user can later override any fields they desire inside the closure.

Similarly, to modify a register, one can use `StatusRegister::Modify`. This function also takes a closure that takes 2 arguments. The first argument is a read-only `Fields` instance with the current contents of the register. The second argument is another `Fields` instance which one must populate with the settings desired to be written.

The `Fields` class also takes care of providing the correct encapsulation for the register fields. Read-only fields are not writable and special fields like `clear-on-write` can be safely handled with specific functions that cleraly state what they do.

`Fields` also provides a type-safe interface. For example, the `Fields::state` mehtod returns a `State` instance, something which was simply not possible with the previous version.

Let's have a look at the tradeoffs of this new implementation.
 
 - **Advantages**:
    - Great control over field types and encapsulation.
    - Functional approach to register writes and register modification actions.
    - Register access is guaranteed to be volatile
    - No extra overhead by unnecessary volatile qualifiers.
    - Specific methods that clarify the operation of special registers like `clear-on-write` registers.
    - No `undefined behavior` due to strict aliasing, as the bitfield is initialized from the register / read from the register using memcpy instead of an union type.
 - **Drawbacks**:
    - More code is needed to define the API, as it is not purely declarative as with the union example.
    - Large overhead if optimization level is `-O0`. Honestly, we should never be building code with `-O0`, so I personally don't see this as an issue.
    - We are still keeping the bitfield, which is `implementation-defined`. In most cases this is good enough as virtually all compilers use the same ordering for their fields. If desired, the bitfield could be replaced, as now it is only an implementation detail of the `Fields` class.

So we have achieved a pretty great solution, but it implies a very significant amount of code we need to write for every single register. This makes it rather errorprone so we must find a way to get around the new issue. The answer lays in code autogeneration. Given that the structure of the code is now known, it only needs to be specialized for each register. We will explore this in the next section.

## Automating the job with SVD

Generating register code is something that we **should** be doing no matter what the chosen API is. But of course, to autogenerate such register API's requires first having access to the peripherals and register definitions in a convenient format. In the case of ARM microcontrollers we are in luck.

ARM created a CMSIS System View Description (SVD) specification that although initially designed to be used with debuggers and other host programs, it is also quite useful for autogenerating peripheral access code. I won't get into the details of how to build the code autogeneration program, but suffice it to say that you can find the SVD format specification [here](https://arm-software.github.io/CMSIS_5/SVD/html/index.html).

If you want to find the SVD files for common microcontrollers you can also refer to the [CMSIS-Packs](https://developer.arm.com/tools-and-software/embedded/cmsis/cmsis-packs), a standardize way to deliver software components from ARM. SVD files will be contained inside the `.pack` files (which are essentially zip files).

## Conclusion
 
In this post we have examined how to control `memory-mapped peripherals` of a CPU in an embedded context by designing an API that allows to control them in a type-safe, performant, free of `undefined behavior` and autogenerated manner. The result was an API that, although quite verbose, can be easily autogenerated and is safe and easy to use in the following regards:

  * Easy to identify when the register is being read/written.
  * Volatile access is guaranteed by design.
  * Volatile qualifiers are only applied to actual HW registers, even when we deal with the same data type in normal RAM, these accesses can be optimized by the compiler.
  * Fields provide encapsulation.
  * Fields provide type safety.
  * Fields that have specific meaning (like `clear-on-write`) can be adapted and included in the API clarifying the uses' expectation.
  * Zero overhead, as all code is seen by the compiler and can be reduced to a sequence of register accesses.
  * No `undefined behavior` or `implementation-defined behavior`.

**Note**: In this post we have seen quite a few examples of `undefined behavior` and `implementation-defined` behavior. I probably even missed some, but please, do not dismiss the importance of `undefined behavior`. Code that seems to work today might not work tomorrow or even worse, code that __seems__ to work today actually doesn't in some subtle and perverse way. If possible, I would encourage you to look into other safer language alternatives like `Rust`, but of course this is not an option for every body for multiple reasons (legacy code, language familiarity for the team, compiler support or other factors). That's why I think as C++ developers we need to take an active role in the safety of the code we write and actively work with the best static/dynamic analisys tools at our disposal, as well as learning the intricacies of the language and being remarkably careful about safety.
 
## Acknowledgements

The API presented here is inspired from the [`svd2rust`](https://github.com/rust-embedded/svd2rust) project, which uses vendor SVD files to autogenerate rust code for register access known as `peripheral access crates` or `PAC`. The API defined in this article is, after all, an adapted version of the Rust code  generated by the `svd2rust` project. Unfortunately, safety is not often the first concern when designing code in C++, but hopefully this article will inspire you to design safer API's, free of the `undefined behavior` which so easily creeps into C++ or C code.

I personally hope Rust will become the next language for embedded development and I see a great wave of developers already pushing for more modern and safer programming practices. For now, many of us still live in C or C++ land, but that should not mean that we cannot benefit from some of the ideas around safety and modern development that are being brought into the embedded community but the new and vibrant embedded rust community.

