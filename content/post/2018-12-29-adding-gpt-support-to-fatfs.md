---
author: Javier Alvarez
date: 2018-12-29 11:27:30+00:00
guid: https://allthingsembedded.net/?p=138
id: 138
permalink: /2018/12/29/adding-gpt-support-to-fatfs/
title: Adding GPT support to FatFS
url: /2018/12/29/adding-gpt-support-to-fatfs/
---

[FatFs](http://elm-chan.org/fsw/ff/00index_e.html) is an open source library used in many embedded devices to interface with FAT file systems in Block devices such as SD cards, flash drives, etc. It can load a FAT or ExFAT filesystem found inside a partition in an MBR partition table. However, it doesn't provide support to find a FAT filesystem inside a GUID partition table.

This blog post will provide you with the knowledge required to load a FAT filesystem inside a GUID partition table using FatFS. For this purpose, I have chosen revision R0.10b, mainly because it is the currently supported version for Xilinx SDK Board Support Package for Zynq devices.

## Basic understanding of the GUID partition table

The GPT is a part of the UEFI standard and a successor of the old MBR. It overcomes many of the problems of the MBR, such as being able to store more than 4 partitions on a single disk and supporting much larger disks of up to 8 ZiB instead of 2 TiB maximum for the MBR. It also abandons the terms of cylinder, head, sector addressing of the MBR (inherited from physical disks) for a much simpler block addressing using logical block addresses.

At LBA 0 the GPT starts with a protective MBR. This is an MBR that contains only one partition (the GUID partition table) with type 0xEE which holds the whole disk. It is used as a protection mechanism to ensure that older systems don't just format the disk after finding a corrupt partition table.

After the protective MBR, LBA 1 contains the main GPT header, which is also found at the end of the disk (also known as the secondary GPT header). This header starts with the magic bytes `EFI PART`, which can be used to identify the header. It contains some useful stuff such as the backup LBA (location of the secondary header table), the single partition entry size (usually 128 bytes), the first LBA used for partition entries (Usually set to LBA 2), The first LBA that can be used for partitions (usually LBA 34), etc.

Now, since we can assume the LBA size to be 512 bytes, the partition entry size of 128 bytes and the total number of LBA's allocated for partitions is 34 - 2 = 32, we can calculate the maximum number of partition entries:

$$ 512 \frac{bytes}{LBA} \div 128 \frac{bytes}{partition} \times 32 LBA = 128 \frac{partitions}{GPT} $$

Lastly, we are going to talk about the structure of a partition table entry. A partition table entry contains the name of the partition, the GUID type (use to determine the type of the partition), the address of the first LBA and the last LBA and a series of attributes. These attributes might be used for specific purposes for a given GUID type. For example, Android uses these attributes to store A/B partition boot information that can be later retrieved by the bootctrl HAL during runtime (check this [link](https://android.googlesource.com/platform/hardware/qcom/bootctrl/+/master/boot_control.cpp) to find out more).

More information on this subject can be found [here](https://en.wikipedia.org/wiki/GUID_Partition_Table#Partition_entries_(LBA_2–33)).

## Adding GPT support to FatFS

Mounting a disk in FatFS means identifying the content of the disk (MBR and each partition) and then finding the correct volume to mount within the disk. This is done by the function `find_volume` in ff.c.

This function checks if there is a Master Boot Record on the disk and then iterates through each partition to find one with a valid FAT filesystem.

```c++
/* Find a FAT partition on the drive. Supports only generic partitioning, FDISK and SFD. */
bsect = 0U;
/* Load sector 0 and check if it is an FAT boot sector as SFD */
fmt = check_fs(fs, bsect);
/* Not an FAT boot sector or forced partition number */
if ((fmt == 1U) || (((!fmt) != (BYTE)0U) && ((LD2PT(vol)) != 0U))) {
    UINT i;
    DWORD br[4];
    /* Get partition offset */
     for (i = 0U; i < 4U; i++) {
        BYTE *pt = fs->win+MBR_Table + ((WORD)i * (WORD)SZ_PTE);
        br[i] = ((*(pt+4)) != (BYTE)0U) ? LD_DWORD((pt+8U)) : 0U;
    }
    /* Partition number: 0:auto, 1-4:forced */
    i = LD2PT(vol);
    if (i != 0U) {
        i--;
    }
    do {
        /* Find an FAT volume */
        bsect = br[i];
        /* Check the partition */
        fmt = (bsect!=(DWORD)0U) ? check_fs(fs, bsect) : 2U;
        i += (UINT)1;
    } while ((!LD2PT(vol)) && (fmt != (BYTE)0U)&& (i < 4U));
}
```

The `check_fs` function is in charge of finding a FAT partition inside an MBR partition table or at the start of the block determined by bsect. It returns 0 if it found an MBR partition table in the selected sector. Returns 1 if it found a valid partition but it is not FAT and it returns 2 if it doesn't find a valid boot sector. For our purposes, we expect here to get a 1 return value, since it will find a valid partition of type 0xEE that matches with the protective MBR first partition.

If this is the case it will try to iterate over all four available partitions (assuming that the user is not forcing any particular partition via the LD2PT macro). It will run the `check_fs` function for each partition entry offset until it finds one that is actually a FAT boot sector. When it finds it, it stores the bsect value for the corresponding FAT volume and continues loading the volume at the appropriate sector address.

We need to modify this section of the code to identify a Protective MBR in the case that the first `check_fs` calls returns 1 (Found valid partition but not FAT). We will do this using a `checkProtectiveMbr` function.

```c++
static
DWORD checkProtectiveMbr(FATFS *fs) {
    UINT i;
    /* Get partition offset */
    for (i = 0U; i < 4U; i++) {
        BYTE *pt = fs->win+MBR_Table + ((WORD)i * (WORD)SZ_PTE);
        BYTE partition_type = *(pt+4);
        xil_printf("Partition %d, type %02x\r\n", i, partition_type);
        if ( i == 0 ) {
            if (partition_type != 0xEE) return 0x00000000;
        } else {
            if (partition_type != 0x00) return 0x00000000;
        }
    }
    xil_printf("Found protective MBR\r\n");
    DWORD LBA_EFI_PART = LD_DWORD((fs->win+MBR_Table+8U));
    xil_printf("EFI Partition at LBA %04x\r\n", LBA_EFI_PART);
    return LBA_EFI_PART;
}
```

This function returns the address for the first LBA of the EFI Partition table or a nullptr if it didn't find one. If we find the protective MBR we should proceed loading the EFI partition table and checking if any partition inside it satisfies the requirements of a FAT volume. We will do this using the `loadGPT` function that takes the LBA obtained in the checkProtectiveMbr function.

```c++
static
DWORD loadGPT(FATFS *fs, DWORD LBA) {
    // Load EFI Part LBA into memory
    move_window(fs, LBA);

    BYTE is_efi_part = strncmp((char*)&fs->win[EFI_MAGIC_OFFSET],
            EFI_MAGIC, strlen(EFI_MAGIC)) == 0;
    if (!is_efi_part) {
        xil_printf("EFI magic not found\r\n");
        return 0;
    }
    xil_printf("EFI magic found\r\n");

    // get size of partition entry
    DWORD partition_entry_size = fs->win[GPT_PART_ENTRY_SIZE];
    DWORD partitions_per_lba = GPT_LBA_SIZE / partition_entry_size;

    xil_printf("partition_entry_size %d\r\n", partition_entry_size);
    xil_printf("partitions_per_lba %d\r\n", partitions_per_lba);

    for (BYTE part_lba = 2; part_lba < 34; part_lba++) {
        // Load LBA into memory
        move_window(fs, part_lba);

        for (BYTE part_entry_index = 0;
            part_entry_index < partitions_per_lba;
            part_entry_index++) {
            BYTE *partition_entry = &fs->win[part_entry_index * partition_entry_size];
            xil_printf("partition %d type %02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x\r\n",
                    (part_lba - 2) * partitions_per_lba + part_entry_index,
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+1],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+2],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+3],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+4],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+5],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+6],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+7],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+8],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+9],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+10],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+11],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+12],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+13],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+14],
                    partition_entry[GPT_PART_ENTRY_TYPE_OFFSET+15]
                    );

            // match expected guid type
            if (memcmp(gpt_expected_fat_guid,
                    &partition_entry[GPT_PART_ENTRY_TYPE_OFFSET],
                    sizeof(gpt_expected_fat_guid)) == 0) {
                // found a matching partition. Check if it contains a valid FAT filesystem.
                uint32_t matching_part_lba = *((uint32_t*)&partition_entry[GPT_PART_ENTRY_FIRST_LBA_OFFSET]);
                if (check_fs(fs, matching_part_lba) == 0) { // found matching FAT filesystem
                    xil_printf("matching partition at LBA 0x%x\r\n", matching_part_lba);
                    return matching_part_lba;
                }
            }
        }
    }

    return 0;
}
```

First of all, this functions checks the `EFI_MAGIC` bytes at the start of the main GUID partition table (which should match the string "EFI PART"). If it doesn't find the main GUID partition table inside the first partition of the protective MBR it simply returns with a nullptr to indicate that it didn't find a viable boot sector.

However, if we match the `EFI_MAGIC` bytes, we can continue to check all partition entries inside the newly found GUID partition table. For this, we will need to obtain the size for each partition entry (`partition_entry_size`) and the maximum number of partitions available per LBA (Assuming each LBA is 512 bytes). Since the `partition_entry_size` is usually 128, the number of partitions per LBA is usually 4.

Then, for all partition entries (ranging from LBA 2 to LBA 33) we search each partition and try to match the partition type found at offset `GPT_PART_ENTRY_TYPE_OFFSET`. Matching the partition type is not really required, but it is useful when you have multiple FAT partitions in the disk but you want to load one with a specific type UUID. For my use case  I generated the following UUID for the expected partition type:

```c++
BYTE gpt_expected_fat_guid[16] = {
        0x66, 0x9e, 0x4c, 0x36,
        0x3f, 0xd1, 0xdd, 0x49,
        0x83, 0x59, 0x09, 0x21,
        0xa3, 0x53, 0x9c, 0x1c
};
```

If it matches the type we check if it contains a valid FAT boot sector using the `check_fs` function and then return the first LBA of the FAT partition.

The only thing left to show is how to integrate both these functions inside the original `find_volume` function we first saw at the start of this section.

```c++
/* Find an FAT partition on the drive. Supports only generic partitioning, FDISK and SFD. */
    bsect = 0U;
    /* Load sector 0 and check if it is an FAT boot sector as SFD */
    fmt = check_fs(fs, bsect);    
    /* Not an FAT boot sector or forced partition number */                
    if ((fmt == 1U) || (((!fmt) != (BYTE)0U) && ((LD2PT(vol)) != 0U))) {    
        UINT i;
        DWORD br[4];

        for (i = 0U; i < 4U; i++) {
            /* Get partition offset */ 
            BYTE *pt = fs->win+MBR_Table + ((WORD)i * (WORD)SZ_PTE);
            br[i] = ((*(pt+4)) != (BYTE)0U) ? LD_DWORD((pt+8U)) : 0U;
        }
        if (fmt == 1) GPT_LBA = checkProtectiveMbr(fs);

        if (GPT_LBA != 0x00000000) {
            // Protective MBR identified. Search boot FAT partition.
            bsect = loadGPT(fs, GPT_LBA);
            fmt = (bsect != 0) ? 0 : 2;
        } else {
            /* Partition number: 0:auto, 1-4:forced */
            i = LD2PT(vol);    
            if (i != 0U) {
                i--;
            }
            do {    
                /* Find an FAT volume */                            
                bsect = br[i];
                /* Check the partition */
                fmt = (bsect!=(DWORD)0U) ? check_fs(fs, bsect) : 2U;
                i += (UINT)1;
            } while ((!LD2PT(vol)) && (fmt != (BYTE)0U)&& (i < 4U));
        }
    }
```

With this we have the final piece of the puzzle. Now the `find_volume` function will try to find a FAT volume inside the first partition. If it doesn't but finds an MBR it will check if it is a protective MBR. If it isn't it will check all 4 partitions in the MBR looking for a FAT partition. However, if it is a Protective MBR it will try to load the GPT table and match a FAT partition inside the GPT using both the partition format and the type GUID of the partition. If it does find these requirements then it loads the FAT partition inside the GPT, accomplishing our initial task of adding support for finding a FAT volume inside a GPT.

The complete code can be found on the following repository:

[Zynq BSP with support for GPT](https://bitbucket.org/javier_varez/zybobsp/commits/dc3600b21c472d82f27e8a4deeee701bb996a96a)
