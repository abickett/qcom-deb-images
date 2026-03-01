# DEBOS_OPTS can be overridden with:
#     make DEBOS_OPTS=... all
# USE_CONTAINER can be set to yes/no/auto (default: auto)
#     make USE_CONTAINER=yes all    # Force container use
#     make USE_CONTAINER=no all     # Force native debos
# DEBOS_ARGS can be used to pass additional arguments to debos:
#     make DEBOS_ARGS="..." disk-ufs.img.gz
# KERNEL_REPO/KERNEL_REF can be set to build a specific kernel:
#     make kernel-deb KERNEL_REPO=https://github.com/qualcomm-linux/kernel \
#                     KERNEL_REF=qcom-next
# KERNEL_PACKAGE can be set to use a kernel from the local APT repo:
#     make rootfs.tar KERNEL_PACKAGE=linux-image-6.19.0-rc8-qcom-next-20260210

# To build large images, the debos resource defaults are not sufficient. These
# provide defaults that work for us as universally as we can manage.
FAKEMACHINE_BACKEND = $(shell [ -c /dev/kvm ] && echo kvm || echo qemu)
DEBOS_OPTS := --fakemachine-backend $(FAKEMACHINE_BACKEND) --memory 1GiB --scratchsize 4GiB
DEBOS_ARGS ?=

# Container support: auto-detect if debos is available, otherwise use container
USE_CONTAINER ?= auto
CONTAINER_IMAGE ?= ghcr.io/go-debos/debos:latest

ifeq ($(USE_CONTAINER),auto)
    USE_CONTAINER := $(shell command -v debos >/dev/null 2>&1 && echo no || echo yes)
endif

ifeq ($(USE_CONTAINER),yes)
    # Only pass --device /dev/kvm if KVM is available on the host,
    # consistent with FAKEMACHINE_BACKEND detection above
    KVM_DEVICE := $(shell [ -c /dev/kvm ] && echo "--device /dev/kvm" || echo "")
    # Working directory as seen from inside the container
    DEBOS_WORKDIR := /recipes
    DEBOS_CMD := docker run --rm --interactive --tty \
        $(KVM_DEVICE) \
        --user $(shell id -u) --workdir $(DEBOS_WORKDIR) \
        --mount "type=bind,source=$(CURDIR),destination=$(DEBOS_WORKDIR)" \
        --security-opt label=disable \
        $(CONTAINER_IMAGE) \
        $(DEBOS_OPTS)
else
    # Working directory for native debos
    DEBOS_WORKDIR := $(CURDIR)
    DEBOS_CMD := debos $(DEBOS_OPTS)
endif

# Use http_proxy from the environment, or apt's http_proxy if set, to speed up
# builds.
http_proxy ?= $(shell apt-config dump --format '%v%n' Acquire::http::Proxy)
export http_proxy

all: disk-ufs.img.gz disk-sdcard.img.gz

rootfs.tar: debos-recipes/qualcomm-linux-debian-rootfs.yaml
	$(DEBOS_CMD) $(DEBOS_ARGS) $<

disk-ufs.img disk-ufs.img.gz: debos-recipes/qualcomm-linux-debian-image.yaml rootfs.tar
	$(DEBOS_CMD) $(DEBOS_ARGS) $<

disk-sdcard.img.gz: debos-recipes/qualcomm-linux-debian-image.yaml rootfs.tar
	$(DEBOS_CMD) $(DEBOS_ARGS) -t imagetype:sdcard $<

# Kernel build variables - override to build a specific kernel
KERNEL_REPO ?= https://github.com/torvalds/linux
KERNEL_REF ?= master
KERNEL_DIR ?=
# Set to 'yes' to use qcom-next defaults (auto-finds latest dated tag)
USE_QCOM_NEXT ?= no
# Set to 'yes' to use linux-next defaults (auto-finds latest dated tag)
USE_LINUX_NEXT ?= no
KERNEL_DEB_EXTRA_ARGS ?=

# Local APT repo directory - mirrors what CI sets up via aptlocalrepo
LOCAL_APT_REPO ?= local-apt-repo

# KERNEL_PACKAGE: when set, automatically passes aptlocalrepo and kernelpackage
# to debos with the correct path for the current build mode (container or native).
# Set this to the package name printed by 'make kernel-deb'.
# Example:
#   make rootfs.tar KERNEL_PACKAGE=linux-image-6.19.0-rc8-qcom-next-20260210
KERNEL_PACKAGE ?=
ifneq ($(KERNEL_PACKAGE),)
    override DEBOS_ARGS += -t aptlocalrepo:$(DEBOS_WORKDIR)/$(LOCAL_APT_REPO) \
                           -t kernelpackage:$(KERNEL_PACKAGE)
endif

# Build a kernel deb package and set up a local APT repo for use by debos.
# This mirrors the CI workflow: kernel deb is placed in a local APT repo so
# debos can install it by package name (no duplicate kernel installation).
# Requires: apt-utils (apt-ftparchive)
#
# Example (qcom-next kernel with auto-tag detection):
#   make kernel-deb USE_QCOM_NEXT=yes
#
# Example (linux-next with auto-tag detection):
#   make kernel-deb USE_LINUX_NEXT=yes
#
# Example (manual repo/ref):
#   make kernel-deb \
#       KERNEL_REPO=https://github.com/qualcomm-linux/kernel \
#       KERNEL_REF=qcom-next
#
# Use existing kernel source (skips cloning):
#   make kernel-deb KERNEL_DIR=/path/to/linux
#
# Then build rootfs with the kernel package name printed above:
#   make rootfs.tar KERNEL_PACKAGE=<package-name> DEBOS_ARGS="-t dtb:qcom/qcs6490-rb3gen2.dtb"
kernel-deb:
	@# Validate conflicting options
	@if [ "$(USE_QCOM_NEXT)" = "yes" ] && [ "$(USE_LINUX_NEXT)" = "yes" ]; then \
	    echo "Error: Cannot use both USE_QCOM_NEXT=yes and USE_LINUX_NEXT=yes"; \
	    exit 1; \
	fi
	$(if $(filter yes,$(USE_QCOM_NEXT)), \
	    scripts/build-linux-deb.py \
	        --qcom-next \
	        $(if $(KERNEL_DIR),--kernel-dir $(KERNEL_DIR)) \
	        $(KERNEL_DEB_EXTRA_ARGS) \
	        $(sort $(wildcard kernel-configs/*.config)), \
	    $(if $(filter yes,$(USE_LINUX_NEXT)), \
	        scripts/build-linux-deb.py \
	            --linux-next \
	            $(if $(KERNEL_DIR),--kernel-dir $(KERNEL_DIR)) \
	            $(KERNEL_DEB_EXTRA_ARGS) \
	            $(sort $(wildcard kernel-configs/*.config)), \
	        scripts/build-linux-deb.py \
	            $(if $(KERNEL_DIR),--kernel-dir $(KERNEL_DIR)) \
	            --repo $(KERNEL_REPO) \
	            --ref $(KERNEL_REF) \
	            $(KERNEL_DEB_EXTRA_ARGS) \
	            $(sort $(wildcard kernel-configs/*.config))))
	mkdir -p $(LOCAL_APT_REPO)/kernel
	@# Kernel debs are created in parent dir of kernel source
	@if [ -n "$(KERNEL_DIR)" ]; then \
	    mv -v $(dir $(abspath $(KERNEL_DIR)))*.deb $(LOCAL_APT_REPO)/kernel/ 2>/dev/null || \
	    mv -v $(abspath $(KERNEL_DIR))/../*.deb $(LOCAL_APT_REPO)/kernel/; \
	else \
	    mv -v *.deb $(LOCAL_APT_REPO)/kernel/; \
	fi
	cd $(LOCAL_APT_REPO) && apt-ftparchive packages . > Packages && apt-ftparchive release . > Release
	@echo ""
	@echo "Local APT repo ready at: $(LOCAL_APT_REPO)/"
	@echo ""
	@echo "To build rootfs with this kernel:"
	@echo "  make rootfs.tar KERNEL_PACKAGE=$$(find $(LOCAL_APT_REPO)/kernel -type f -name 'linux-image-*' -not -name '*-dbg_*' | xargs -n1 basename | cut -f1 -d_)"

test: disk-ufs.img
	# rootfs/ is a build artifact, so should not be scanned for tests
	py.test-3 --ignore=rootfs

clean:
	rm -f rootfs.tar
	rm -f dtbs.tar.gz
	rm -f disk-*.img disk-*.img.gz disk-*.img[0-9]
	rm -rf rootfs/
	rm -rf linux/
	rm -rf $(LOCAL_APT_REPO)/

.PHONY: all kernel-deb test clean
