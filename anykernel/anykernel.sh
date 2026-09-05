### AnyKernel3 Ramdisk Mod Script
## chiron (Xiaomi Mi MIX 2) - LineageOS 22.2 + ReSukiSU

### AnyKernel setup
properties() { '
kernel.string=Chiron-ReSukiSU 0b5efe9e (35114) 4.4.302-perf-resukisu for LineageOS 22.2
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=chiron
supported.versions=15
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
## boot shell variables
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching
. tools/ak3-core.sh;

# boot install
dump_boot;
write_boot;
## end boot install
