# Out-of-tree build for the patched ov5693 sensor driver.
#
# Used both by DKMS (which passes -C <kernel_source_dir> M=<dkms_source_tree>
# itself, so only the obj-m line matters there) and by a plain `make` for a
# quick local build against the running kernel.

obj-m += ov5693.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
PWD  := $(CURDIR)

.PHONY: all modules clean

all: modules

modules:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
