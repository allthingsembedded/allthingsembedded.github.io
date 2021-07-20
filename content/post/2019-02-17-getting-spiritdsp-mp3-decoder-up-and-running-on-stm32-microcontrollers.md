---
id: 303
title: Getting SpiritDSP MP3 Decoder up and running on STM32 Microcontrollers
date: 2019-02-17T14:44:58+00:00
author: Javier Alvarez
layout: post
---
After researching some alternatives for mp3 decoding on STM32 microcontrollers, I found ST's X-CUBE-AUDIO, a set of libraries and components for audio processing. It turns out that SpiritDSP developed a version of their MP3 decoding libraries for STM microcontrollers.

You can download the software expansion kit following [this](https://www.st.com/en/embedded-software/x-cube-audio.html) link. It contains much more than just the SpiritDSP MP3 decoder, but this article will be focused just on how to get the MP3 decoder up and running. 

The decoder is provided as a closed source prebuilt component, and therefore we rely on the documentation to make it work properly. ST included a description of the API as part of the documentation.

It is actually pretty easy to use. You first need to initialize the decoder using the function `SpiritMP3DecoderInit`. It takes the decoder object, a callback used to receive mp3 data from the decoder in a pull fashion, another callback for processing the samples in the frequency domain before converting them back to the time domain and a void pointer for user data.

Then, whenever you need more PCM audio data, you can call `SpiritMP3Decode` specifying the pointer to the decoder, the buffer for the data and the length of the buffer. It also gives the MP3 data from the decoded frame, which is pretty useful to obtain the number of channels and information such as the sampling rate. This function internally takes care of calling the callbacks specified in the initialization function in order to read the data from the MP3 file and process the data on the frequency domain.

However, when I got around to actually running the code it didn't run successfully. It hang in an infinite loop for my example application (Using the Cortex-M4 version of the library for an STM32F411 microcontroller). After reviewing the code and making sure that is it compliant with the API of the library, I went ahead and checked where my application was hanging. It looks something like this:

![SpiritDSP Analysis in radare2](/spirit_mp3_radare.png)

This is the loop where my code was hanging. If you take a closer look, it reads data from a memory mapped register, adds one to that number and checks if it is not zero to continue inside the loop. Therefore, to exit the loop, the number read from the memory mapped register must be 0xFFFFFFFF (-1) and I was always reading 0 from this register while debugging the code. Since it doesn't look like we ever write to this register from inside the loop, this must be reading some memory-mapped peripheral that is expected to be in some defined state.

Let's check the addresses we are reading and writing within the loop. We are using the register r0 as the base address. This gets assigned the value `0x40023000`. This totally looks like the address of some memory-mapped peripheral given in which address range the value of r0 lies. I checked the datasheet of the STM32F411 microcontroller and sure enough, **this is the base address for the CRC Peripheral**.

Yes! This makes perfect sense. **MP3 uses CRC to provide error detection inside stored or transmitted MP3 frames.** After this, it was pretty easy to get it working. Looks like ST used the addresses of this peripheral, which is common to most microcontrollers of these series. However, the RCC peripheral is commonly very microcontroller specific and it is used to enable the clock for all peripherals depending on their bus. So, basically, **calling `__HAL_RCC_CRC_CLK_ENABLE()` right before initializing the decoder solved the problem and my example application started working!**

I honestly don't know why ST didn't record this step in their documentation, but it is quite an inconvenience and it takes a while to figure out what's going on here. Anyhow, I hope you can use this to get this library up and running on your devices. You can check the whole project [here](https://github.com/Javier-varez/MP3_PoC).
