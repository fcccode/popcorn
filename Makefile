ARCH           ?= x86_64

include src/arch/$(ARCH)/config.mk

BUILD_D        := build
ARCH_D         := src/arch/$(ARCH)
VERSION        ?= $(shell git describe --dirty --always)
GITSHA         ?= $(shell git rev-parse --short HEAD)

KERNEL_FILENAME:= popcorn.bin

MODULES        := main


EFI_DIR        := external/gnu-efi
EFI_DATA       := $(EFI_DIR)/gnuefi
EFI_LDS        := $(EFI_DATA)/elf_$(ARCH)_efi.lds
EFI_ARCH_DIR   := $(EFI_DIR)/$(ARCH)
EFI_ARCH_DATA  := $(EFI_ARCH_DIR)/gnuefi
EFI_CRT_OBJ    := $(EFI_ARCH_DATA)/crt0-efi-$(ARCH).o
EFI_LIB        := $(EFI_ARCH_DIR)/lib/libefi.a
EFI_INCLUDES   := $(EFI_DIR)/inc

DEPENDFLAGS    := -MMD

INCLUDES       := -I $(ARCH_D)
INCLUDES       += -I src/modules
INCLUDES       += -isystem $(EFI_INCLUDES)
INCLUDES       += -isystem $(EFI_INCLUDES)/$(ARCH)
INCLUDES       += -isystem $(EFI_INCLUDES)/protocol

BASEFLAGS      := -ggdb -nostdlib
BASEFLAGS      += -ffreestanding -nodefaultlibs
BASEFLAGS      += -fno-builtin -fomit-frame-pointer

ifdef CPU
BASEFLAGS      += -mcpu=$(CPU)
endif

# Removed Flags:: -Wcast-align
WARNFLAGS      += -Wformat=2 -Winit-self -Wfloat-equal -Winline 
WARNFLAGS      += -Winvalid-pch -Wmissing-format-attribute
WARNFLAGS      += -Wmissing-include-dirs -Wswitch -Wundef
WARNFLAGS      += -Wdisabled-optimization -Wpointer-arith

WARNFLAGS      += -Wno-attributes -Wno-sign-compare -Wno-multichar
WARNFLAGS      += -Wno-div-by-zero -Wno-endif-labels -Wno-pragmas
WARNFLAGS      += -Wno-format-extra-args -Wno-unused-result
WARNFLAGS      += -Wno-deprecated-declarations -Wno-unused-function
WARNFLAGS      += -Wno-unused-but-set-parameter

ASFLAGS        ?=
ASFLAGS        += -p $(BUILD_D)/versions.s

CFLAGS         := $(INCLUDES) $(DEPENDFLAGS) $(BASEFLAGS) $(WARNFLAGS)
CFLAGS         += -std=c11 -fshort-wchar
CFLAGS         += -mno-red-zone -fno-stack-protector 
CFLAGS         += -DGIT_VERSION="L\"$(VERSION)\""
CFLAGS         += -DKERNEL_FILENAME="L\"$(KERNEL_FILENAME)\""
CFLAGS         += -DEFI_DEBUG=0 -DEFI_DEBUG_CLEAR_MEMORY=0
CFLAGS         += -DGNU_EFI_USE_MS_ABI -DHAVE_USE_MS_ABI
#CFLAGS        += -DEFI_FUNCTION_WRAPPER 

BOOT_CFLAGS	   := -I src/boot $(CFLAGS)
ifdef MAX_HRES
BOOT_CFLAGS    += -DMAX_HRES=$(MAX_HRES)
endif

LDFLAGS        := -L $(BUILD_D) -ggdb
LDFLAGS        += -nostdlib -znocombreloc -Bsymbolic -nostartfiles 

BOOT_LDFLAGS   := $(LDFLAGS) -shared
BOOT_LDFLAGS   += -L $(EFI_ARCH_DIR)/lib -L $(EFI_ARCH_DIR)/gnuefi

AS             ?= $(CROSS)nasm
AR             ?= $(CROSS)ar
CC             ?= $(CROSS)gcc
CXX            ?= $(CROSS)g++
LD             ?= $(CROSS)ld
OBJC           := $(CROSS)objcopy
OBJD           := $(CROSS)objdump

INIT_DEP       := $(BUILD_D)/.builddir

BOOT_SRCS      := $(wildcard src/boot/*.c)
BOBJS          += $(patsubst src/boot/%,$(BUILD_D)/boot/%,$(patsubst %,%.o,$(BOOT_SRCS)))
BDEPS          := $(patsubst src/boot/%,$(BUILD_D)/boot/%,$(patsubst %,%.d,$(BOOT_SRCS)))

ARCH_SRCS      := $(wildcard $(ARCH_D)/*.s)
ARCH_SRCS      += $(wildcard $(ARCH_D)/*.c)
KOBJS          += $(patsubst $(ARCH_D)/%,$(BUILD_D)/arch/%,$(patsubst %,%.o,$(ARCH_SRCS)))
DEPS           := $(patsubst $(ARCH_D)/%,$(BUILD_D)/arch/%,$(patsubst %,%.d,$(ARCH_SRCS)))
MOD_TARGETS    :=

PARTED         ?= /sbin/parted
QEMU           ?= qemu-system-x86_64
GDBPORT        ?= 27006
CPUS           ?= 1
OVMF           ?= assets/ovmf/x64/OVMF.fd 

QEMUOPTS       := -pflash $(BUILD_D)/flash.img
QEMUOPTS       += -drive file=$(BUILD_D)/fs.img,format=raw
QEMUOPTS       += -smp $(CPUS)
QEMUOPTS       += -m 512
QEMUOPTS       += -d guest_errors
QEMUOPTS       += $(QEMUEXTRA)


all: $(BUILD_D)/fs.img
init: $(INIT_DEP)

$(INIT_DEP):
	mkdir -p $(BUILD_D) $(patsubst %,$(BUILD_D)/d.%,$(MODULES))
	mkdir -p $(BUILD_D)/boot
	mkdir -p $(BUILD_D)/arch
	touch $(INIT_DEP)

clean:
	rm -rf $(BUILD_D)/* $(BUILD_D)/.version $(BUILD_D)/.builddir

dist-clean: clean
	make -C external/gnu-efi clean

dump: $(BUILD_D)/kernel.dump
	vim $<

.PHONY: all clean dist-clean init dump

$(BUILD_D)/.version:
	echo '$(VERSION)' | cmp -s - $@ || echo '$(VERSION)' > $@

$(BUILD_D)/versions.s:
	./parse_version.py "$(VERSION)" "$(GITSHA)" > $@

-include x $(patsubst %,src/modules/%/module.mk,$(MODULES))
-include x $(DEPS)

$(EFI_LIB):
	make -C external/gnu-efi all

$(BUILD_D)/boot.elf: $(BOBJS) $(EFI_LIB)
	$(LD) $(BOOT_LDFLAGS) -T $(EFI_LDS) -o $@ \
		$(EFI_CRT_OBJ) $(BOBJS) -lefi -lgnuefi

$(BUILD_D)/boot.efi: $(BUILD_D)/boot.elf
	$(OBJC) -j .text -j .sdata -j .data -j .dynamic \
	-j .dynsym  -j .rel -j .rela -j .reloc \
	--target=efi-app-$(ARCH) $^ $@

$(BUILD_D)/boot.debug.efi: $(BUILD_D)/boot.elf
	$(OBJC) -j .text -j .sdata -j .data -j .dynamic \
	-j .dynsym  -j .rel -j .rela -j .reloc \
	-j .debug_info -j .debug_abbrev -j .debug_loc -j .debug_str \
	-j .debug_aranges -j .debug_line -j .debug_macinfo \
	--target=efi-app-$(ARCH) $^ $@

$(BUILD_D)/%.bin: $(BUILD_D)/%.elf
	$(OBJC) $< -O binary $@

$(BUILD_D)/boot.dump: $(BUILD_D)/boot.efi
	$(OBJD) -D -S $< > $@

$(BUILD_D)/boot/%.s.o: src/boot/%.s $(BUILD_D)/versions.s $(INIT_DEP)
	$(AS) $(ASFLAGS) -o $@ $<

$(BUILD_D)/boot/%.c.o: src/boot/%.c $(INIT_DEP)
	$(CC) $(BOOT_CFLAGS) -c -o $@ $<

$(BUILD_D)/kernel.elf: $(KOBJS) $(MOD_TARGETS) $(ARCH_D)/kernel.ld
	$(LD) $(LDFLAGS) -u _header -T $(ARCH_D)/kernel.ld -o $@ $(patsubst %,-l%,$(MODULES)) $(KOBJS)
	$(OBJC) --only-keep-debug $@ $@.sym

$(BUILD_D)/kernel.dump: $(BUILD_D)/kernel.elf
	$(OBJD) -D -S $< > $@

$(BUILD_D)/arch/%.s.o: $(ARCH_D)/%.s $(BUILD_D)/versions.s $(INIT_DEP)
	$(AS) $(ASFLAGS) -o $@ $<

$(BUILD_D)/arch/%.c.o: $(ARCH_D)/%.c $(INIT_DEP)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD_D)/flash.img: $(OVMF)
	cp $^ $@

$(BUILD_D)/fs.img: $(BUILD_D)/boot.efi $(BUILD_D)/kernel.bin
	$(eval TEMPFILE := $(shell mktemp --suffix=.img))
	dd if=/dev/zero of=$@.tmp bs=512 count=93750
	$(PARTED) $@.tmp -s -a minimal mklabel gpt
	$(PARTED) $@.tmp -s -a minimal mkpart EFI FAT16 2048s 93716s
	$(PARTED) $@.tmp -s -a minimal toggle 1 boot
	dd if=/dev/zero of=$(TEMPFILE) bs=512 count=91669
	mformat -i $(TEMPFILE) -h 32 -t 32 -n 64 -c 1
	mmd -i $(TEMPFILE) ::/EFI
	mmd -i $(TEMPFILE) ::/EFI/BOOT
	mcopy -i $(TEMPFILE) $(BUILD_D)/boot.efi ::/EFI/BOOT/BOOTX64.efi
	mcopy -i $(TEMPFILE) $(BUILD_D)/kernel.bin ::$(KERNEL_FILENAME)
	mlabel -i $(TEMPFILE) ::Popcorn_OS
	dd if=$(TEMPFILE) of=$@.tmp bs=512 count=91669 seek=2048 conv=notrunc
	rm $(TEMPFILE)
	mv $@.tmp $@

$(BUILD_D)/fs.iso: $(BUILD_D)/fs.img
	mkdir -p $(BUILD_D)/iso
	cp $< $(BUILD_D)/iso/
	xorriso -as mkisofs -R -f -e fs.img -no-emul-boot -o $@ $(BUILD_D)/iso

qemu: $(BUILD_D)/fs.img $(BUILD_D)/flash.img
	"$(QEMU)" $(QEMUOPTS) -nographic

qemu-window: $(BUILD_D)/fs.img $(BUILD_D)/flash.img
	"$(QEMU)" $(QEMUOPTS)

qemu-gdb: $(BUILD_D)/fs.img $(BUILD_D)/boot.debug.efi $(BUILD_D)/flash.img $(BUILD_D)/kernel.elf
	"$(QEMU)" $(QEMUOPTS) -d mmu,guest_errors,page -D popcorn.log -s -nographic

# vim: ft=make ts=4
