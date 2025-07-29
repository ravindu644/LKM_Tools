> [!CAUTION]
> AI Generated code, But `It Just Works™`

# Android GKI Vendor Module Preparation Scripts

This repository contains a set of scripts designed to simplify the process of preparing kernel modules for `vendor_boot` and `vendor_dlkm` partitions when building custom Android GKI (Generic Kernel Image) kernels.

The scripts intelligently handle dependency resolution, module pruning, load order optimization, and optional integration of NetHunter modules.

## Workflow

The process is designed to be run in a specific order:

1.  **`01.modules_dep.sh`**: First, extract a master list of all modules from your stock `vendor_boot` image.
2.  **`02.prepare_vendor_boot_modules.sh`**: Next, use the master list to prepare the modules required for the `vendor_boot` partition.
3.  **`03.prepare_vendor_dlkm.sh`**: Finally, prepare the `vendor_dlkm` modules, which can optionally include NetHunter modules and be pruned against the `vendor_boot` list.

## Prerequisites

Before you begin, you will need:
- A Linux environment with `bash` and standard core utilities.
- Your compiled kernel source, with the output available in a `staging` directory.
    - The `out/target/product/a16xm/obj/KERNEL_OBJ/staging/lib/modules/5.15.167-android13-8-ravindu644-nh+` like path.
- The `System.map` file from your kernel build.
- The AOSP `llvm-strip` tool, typically found in your toolchain directory.
- Extracted stock `vendor_boot.img` and `vendor_dlkm.img` to get the original `modules.dep` and `modules.load` files.

---

## 1. `01.module_dep.sh` - Extract Master Module List

This script reads a stock `modules.dep` file and creates a clean, sorted, and unique list of all `.ko` module filenames. This list serves as the master manifest for the next script.

### Usage

Each script can be run interactively (by providing no arguments) or non-interactively (by providing all arguments).

**Show Help Message**
```bash
./01.module_dep.sh --help
```

**Interactive Mode**
Simply run the script and follow the prompts.
```bash
./01.module_dep.sh
```

**Argument Mode**
Provide the path to the stock `modules.dep` and the desired output directory.
```bash
# Usage: ./01.module_dep.sh <path_to_modules.dep> <output_directory>
./01.module_dep.sh /path/to/stock/vendor_boot/lib/modules/modules.dep ./vendor_boot
```
This will create an `vendor_boot/modules_list.txt` file.

---

## 2. `02.prepare_vendor_boot_modules.sh` - Prepare Vendor Boot Modules

This script uses the `modules_list.txt` generated earlier to gather all necessary modules and their dependencies from your kernel build's staging directory. It then strips them and prepares the final `vendor_boot` module set.

### Usage

**Show Help Message**
```bash
./02.prepare_vendor_boot_modules.sh --help
```

**Interactive Mode**
```bash
./02.prepare_vendor_boot_modules.sh
```

**Argument Mode**
Provide all required paths as arguments.
```bash
# Usage: ./02.prepare_vendor_boot_modules.sh <modules_list> <staging_dir> <oem_load_file> <system_map> <strip_tool> <output_dir>

./02.prepare_vendor_boot_modules.sh \
  ./vendor_boot/modules_list.txt \
  /path/to/kernel_build/out/msm-kernel/staging \
  /path/to/stock/vendor_boot/lib/modules/modules.load \
  /path/to/kernel_build/out/System.map \
  /path/to/toolchain/bin/llvm-strip \
  ./vendor_boot/vendor_boot_modules
```

---

## 3. `03.prepare_vendor_dlkm.sh` - Prepare Vendor DLKM Modules

This is the final and most comprehensive script. It prepares the `vendor_dlkm` modules, resolves all dependencies, and intelligently handles the module load order. It can optionally integrate NetHunter modules and prune any modules that are already present in the `vendor_boot` partition to avoid duplication.

### Usage

**Show Help Message**
```bash
./03.prepare_vendor_dlkm.sh --help
```

**Interactive Mode**
Run the script and follow the prompts. You can press **Enter** to skip the optional paths for the `vendor_boot` list and the NetHunter directory.
```bash
./03.prepare_vendor_dlkm.sh
```

**Argument Mode**
Provide all paths as arguments. To skip an optional path (like the NetHunter directory or vendor_boot list), pass an empty string `""`.

**Example (without NetHunter or pruning):**
```bash
# Usage: ./03.prepare_vendor_dlkm.sh <modules_list> <staging_dir> <oem_load_file> <system_map> <strip_tool> <output_dir> <vendor_boot_list> <nh_dir>

./03.prepare_vendor_dlkm.sh \
  ./vendor_dlkm/modules_list.txt \
  /path/to/kernel_build/out/msm-kernel/staging \
  /path/to/stock/vendor_dlkm/lib/modules/modules.load \
  /path/to/kernel_build/out/System.map \
  /path/to/toolchain/bin/llvm-strip \
  ./vendor_dlkm/vendor_dlkm_modules \
  "" \
  ""
```

**Example (with NetHunter and vendor_boot pruning):**
```bash
./03.vendor_dlkm.sh \
  ./vendor_dlkm/modules_list.txt \
  /path/to/kernel_build/out/msm-kernel/staging \
  /path/to/stock/vendor_dlkm/lib/modules/modules.load \
  /path/to/kernel_build/out/System.map \
  /path/to/toolchain/bin/llvm-strip \
  ./vendor_dlkm/vendor_dlkm_modules_nh \
  ./vendor_boot/modules_list.txt \
  /path/to/nethunter_modules
```

**Note:** You should manually copy all the "suspected" modules that were generated but are not present in your OEM's module list to a separate folder (for example, `ath9k_htc.ko` might have been generated because you enabled an Atheros driver as an LKM, etc.).


Eg (Only needed for the first time of generating modules.dep and modules.load file):

```bash
ravindu644@ubuntu:~/Desktop/Kernels/android_kernel_a166p/nethunter (stable-connectivity)$ ls

ath6kl_core.ko  ath9k_common.ko  ath9k_hw.ko  carl9170.ko  mac80211.ko  rndis_host.ko  rt2500usb.ko  rt2800usb.ko  rt2x00usb.ko  rtl8187.ko   zd1201.ko
ath6kl_usb.ko   ath9k_htc.ko     ath.ko       cfg80211.ko  mt7601u.ko   rndis_wlan.ko  rt2800lib.ko  rt2x00lib.ko  rt73usb.ko    rtl8xxxu.ko  zd1211rw.ko
```
