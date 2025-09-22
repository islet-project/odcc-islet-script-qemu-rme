#!/bin/bash

set -e

ROOT=$(git rev-parse --show-toplevel)

ISLET_DIR=$1
TF_A_IMAGE_PATH=$ISLET_DIR/out/bin/flash.bin
QEMU_DIR=$ISLET_DIR/third-party/qemu/build

HES_APP=$ISLET_DIR/hes/islet-hes-host-app
HES_PID=/tmp/hes.pid
HES_ADDR="127.0.0.1:54321"

AOSP_VER="aosp-15.0.0_r8"
AOSP_DIR="$ROOT/$AOSP_VER"

HOST_ANDROID_KERNEL_VER="android16-6.12"
HOST_ANDROID_KERNEL_DIR="$ROOT/${HOST_ANDROID_KERNEL_VER}-host"
HOST_ANDROID_KERNEL_OUT="$HOST_ANDROID_KERNEL_DIR/out/virtual_device_aarch64/dist"
KERNEL_PATH=$HOST_ANDROID_KERNEL_OUT/Image
INITRAMFS_PATH=$HOST_ANDROID_KERNEL_OUT/initramfs.img

# NOTE: if using islet-rmm, add kvm-rme.save_host_context=1.
KERNEL_CMDLINE="androidboot.hypervisor.vm.supported=1 vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size=16384 stack_depot_disable=on cgroup_disable=pressure kasan.stacktrace=off bootconfig  printk.devkmsg=on audit=1 panic=-1 8250.nr_uarts=1 cma=0 firmware_class.path=/vendor/etc/ loop.max_part=7 init=/init bootconfig  console=hvc0 earlycon=pl011,mmio32,0x9000000 kvm-rme.save_host_context=1 "

# NOTE:
# The contents of bootconfig is added by the launch_cvd based on the bootconfig
# in the vendor_boot.img. Then the u-boot adds another during the device boot.
# Since there's no way to get it in advance, use the generated one instead.
BOOTCONFIG_TOOL=$ROOT/out/bin/bootconfig
CF_BOOTCONFIG=$ROOT/scripts/bootconfig_cf
# NOTE:
# Strictly speaking, we should use ~/cuttlefish/assembly/vendor_ramdisk_repacked.
# However, it's created after successful execution of `launch_cvd`.
# Since it's in the chicken-and-egg relation, use an alternative, vendor_ramdisk.img.
# If below file doesn't work for you, use vendor_ramdisk_repacked instead.
VENDOR_RAMDISK_PATH=$AOSP_DIR/out/target/product/vsoc_arm64_only/vendor_ramdisk.img
CONCATENATED_RAMDISK_PATH=$ROOT/out/aosp_rme_ramdisk.img

function run_qemu()
{
	if [ ! -f "$TF_A_IMAGE_PATH" ]; then
		echo "goto your islet and build cca firmware"
		echo "qemu-cca -nw acs -rmm islet -bo"
		exit 1
	fi
	# Go to the aosp source directory which you were built before
	echo "> cd $AOSP_DIR"
	cd $AOSP_DIR || exit 1

	# Setup environment & select the target again
	echo "[!] Setting up build environment..."
	. build/envsetup.sh
	lunch aosp_cf_arm64_only_phone-trunk_staging-userdebug

	# Run cuttlefish with cca support linux -> after start kernel, there is no logs..
	echo ""
	echo "[!] Running Cuttlefish based by QEMU..."
	echo ""

    # cpu_feature is added to the qemu's default option, '-cpu max'.
	# In case of tf-rmm, use:
	#	-cpu_feature "x-rme=on,pauth-impdef=on,sme=off" \
	# In case of islet-rmm, use below until features are supported:
	#	-cpu_feature "x-rme=on,pauth-impdef=on,sme=off,lpa2=off" \
	# If you don't want to use SVE, add sve=off to the cpu_features.
	# qemu_initrd is added to the qemu's '-initrd' option
	launch_cvd -vm_manager qemu_cli -console=true \
		-cpu_feature "x-rme=on,pauth-impdef=on,sme=off,lpa2=off" \
		-hes_serial_port 54321 \
		-qemu_initrd $CONCATENATED_RAMDISK_PATH \
		-cpus 8 \
		-qemu_binary_dir $QEMU_DIR \
		--memory_mb 8192 \
		-enable_host_bluetooth false -report_anonymous_usage_stats=n \
		-kernel_path $KERNEL_PATH \
		-initramfs_path $INITRAMFS_PATH \
		-extra_kernel_cmdline "$KERNEL_CMDLINE" \
		-bootloader $TF_A_IMAGE_PATH
}

function build_bootconfig()
{
	cd $HOST_ANDROID_KERNEL_DIR/common/tools/bootconfig
	make
	mkdir -p $ROOT/out/bin
	cp bootconfig $ROOT/out/bin
}

function prepare_ramdisk()
{

	if [ ! -f "$BOOTCONFIG_TOOL" ]; then
		build_bootconfig
	fi
	mkdir -p $ROOT/out
	echo > $CONCATENATED_RAMDISK_PATH
	cat $VENDOR_RAMDISK_PATH  $INITRAMFS_PATH > $CONCATENATED_RAMDISK_PATH
	$BOOTCONFIG_TOOL -a $CF_BOOTCONFIG $CONCATENATED_RAMDISK_PATH
}

function start_hes_daemon() {
    if [ -f "$HES_PID" ]; then
        kill $(cat $HES_PID) 2>/dev/null || true
        rm -f $HES_PID
    fi
    echo "[!] Starting HES daemon on $HES_ADDR..."
    cd $HES_APP
    cargo run --release -- \
        --daemonize --persistent \
        --addr $HES_ADDR \
        --daemonize-root /tmp
}

function stop_hes_daemon() {
    if [ -f "$HES_PID" ]; then
        kill $(cat $HES_PID) 2>/dev/null || true
        rm -f $HES_PID
    fi
}

if [ $# -ne 1 ]; then
	echo "Usage ./scripts/run_cuttlefish.sh {path-to-islet-repo}"
	exit 1
fi

trap stop_hes_daemon EXIT INT TERM

prepare_ramdisk
start_hes_daemon
run_qemu
