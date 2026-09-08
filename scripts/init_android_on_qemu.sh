#!/bin/bash

set -e

ROOT=$(git rev-parse --show-toplevel)

CUR_SCRIPT_DIR=$(dirname "$(realpath "$0")")

AOSP_VER="aosp-15.0.0_r8"
AOSP_DIR="$ROOT/$AOSP_VER"
AOSP_UPSTREAM_URL="https://android.googlesource.com/platform/manifest"
AOSP_UPSTREAM_BRANCH="android-15.0.0_r8"
AOSP_URL="https://github.com/islet-project/odcc-aosp-manifest.git"
AOSP_BRANCH="on-device-cc"
AOSP_MICRODROID_KERNEL_PATH="$AOSP_DIR/packages/modules/Virtualization/guest/kernel/android15-6.6/arm64/kernel-6.6"

# Common for Host and Guest Android Kernel
ANDROID_KERNEL_URL="https://github.com/islet-project/3rd-android-kernel.git"

# For Host Android Kernel
HOST_ANDROID_KERNEL_VER="android16-6.12"
HOST_ANDROID_KERNEL_DIR="$ROOT/${HOST_ANDROID_KERNEL_VER}-host"
HOST_ANDROID_KERNEL_MANIFEST_BRANCH="android16-6.12/cca-host/manifest/v5"
HOST_ANDROID_KERNEL_SOURCE_BRANCH="android16-6.12/cca-host/v5"
HOST_ANDROID_KERNEL_BUILD_TARGET="//common-modules/virtual-device:virtual_device_aarch64_dist"

HOST_ANDROID_INITRAMFS_PATH="$HOST_ANDROID_KERNEL_DIR/out/virtual_device_aarch64/dist/initramfs.img"
HOST_ANDROID_KERNEL_IMG_PATH="$HOST_ANDROID_KERNEL_DIR/out/virtual_device_aarch64/dist/Image"

# For Guest Android Kernel
GUEST_ANDROID_KERNEL_VER="android15-6.6"
GUEST_ANDROID_KERNEL_DIR="$ROOT/${GUEST_ANDROID_KERNEL_VER}-realm"
GUEST_ANDROID_KERNEL_MANIFEST_BRANCH="android15-6.6/cca-guest/manifest/v7"
GUEST_ANDROID_KERNEL_BUILD_TARGET="//common:kernel_aarch64_microdroid_dist"

GUEST_ANDROID_KERNEL_IMG_PATH="$GUEST_ANDROID_KERNEL_DIR/out/kernel_aarch64_microdroid/dist/Image"

# Configuration for Chrony NTP/NTS service taken from rkik-nts repository
RKIK_NTS_URL="https://github.com/islet-project/rkik-nts.git"
RKIK_NTS_BRANCH="master"
RKIK_NTS_DIR="chrony-conf"
RKIK_NTS_CHRONY_CONFIG_DIR="chrony"
CHRONY_SYS_CONFIG_DIR="/etc/chrony/"

# Exit codes
EXIT_CD_FAILED=1
EXIT_REPO_DOWNLOAD=10
EXIT_AOSP_BUILD=20
EXIT_KERNEL_BUILD=30
EXIT_OTHER=125

function install_required_packages()
{
	if [ -z "$(which repo)" ]; then
		sudo apt-get install repo
		sudo apt-get install make
		sudo apt-get install gcc
		sudo apt-get install git-lfs # For <aosp_root>/packages/modules/Virtualization
		sudo apt-get install adb


		# Support -vnc for qemu
		sudo apt-get install \
			libjpeg-dev \
			libpng-dev \
			libgnutls28-dev \
			zlib1g-dev \
			libpixman-1-dev \
			pkg-config
	fi


	if ! dpkg -s chrony &>/dev/null; then
		sudo apt-get install -y chrony
	fi
}

function prepare_chrony_configuration()
{
        echo " "
        echo "[!] Prepare Chrony configuration"

        if [ -d "$RKIK_NTS_DIR" ]; then
                echo "$RKIK_NTS_DIR already exist."
        else
                git clone --no-checkout --depth=1 --filter=tree:0 $RKIK_NTS_URL $RKIK_NTS_DIR
                pushd $RKIK_NTS_DIR > /dev/null
                git sparse-checkout set --no-cone /$RKIK_NTS_CHRONY_CONFIG_DIR
                git checkout
                popd > /dev/null
        fi

        if [ ! -d "$CHRONY_SYS_CONFIG_DIR" ]; then
                echo "Chrony is not installed!"
                exit $EXIT_OTHER
        fi

        echo "Copying chrony certificates and configuration file... "
        pushd $RKIK_NTS_DIR > /dev/null
        sudo cp chrony/chrony.conf /etc/chrony/
        sudo cp chrony/certs/nts-devel.key /etc/chrony/
        sudo cp chrony/certs/nts-devel.crt /etc/chrony/
        sudo chown _chrony:_chrony /etc/chrony/nts-devel.key
        sudo chown _chrony:_chrony /etc/chrony/nts-devel.crt
        sudo chmod 440 /etc/chrony/nts-devel.key
        sudo chmod 644 /etc/chrony/nts-devel.crt
        popd > /dev/null
        echo "DONE"
	echo "Restarting the chrony daemon"
	sudo systemctl restart chrony
}

function build_aosp()
{
	echo " "
		echo "[!] Prepare AOSP Source Code"

	if [ -d "$AOSP_DIR" ]; then
		echo "$AOSP_DIR already exists."
	else
		echo "> mkdir -p $AOSP_DIR"
		mkdir -p $AOSP_DIR
	fi

	echo "> cd $AOSP_DIR"
	cd $AOSP_DIR || exit $EXIT_CD_FAILED

	if [ ! -d ".repo" ]; then
		echo "> repo init -u $AOSP_UPSTREAM_URL -b $AOSP_UPSTREAM_BRANCH "
		if ! repo init -u $AOSP_UPSTREAM_URL -b $AOSP_UPSTREAM_BRANCH ; then
			echo "ERROR: repo init failed for upstream AOSP"
			exit $EXIT_REPO_DOWNLOAD
		fi
	else
		echo ".repo already exists. Skipping initializing upstream AOSP repos"
	fi

	if [ ! -d ".repo/local_manifests" ]; then
		echo "> git clone $AOSP_URL .repo/local_manifests -b $AOSP_BRANCH"
		if ! git clone $AOSP_URL .repo/local_manifests -b $AOSP_BRANCH; then
			echo "ERROR: git clone failed for ODCC AOSP"
			exit $EXIT_REPO_DOWNLOAD
		fi
	else
		echo ".repo/local_manifests already exists. Skipping initializing ODCC AOSP repos"
	fi

	echo "> repo sync -c --no-clone-bundle -j8"
	if ! repo sync -c --no-clone-bundle -j8; then
		echo "ERROR: repo sync failed for AOSP"
		exit $EXIT_REPO_DOWNLOAD
	fi

	if [ -f "out/host/linux-x86/bin/launch_cvd" ]; then
		echo "launch_cvd is exists. Skip building AOSP"
		return
	fi

	echo "> cp -f $GUEST_ANDROID_KERNEL_IMG_PATH  $AOSP_MICRODROID_KERNEL_PATH"
	cp -f $GUEST_ANDROID_KERNEL_IMG_PATH  $AOSP_MICRODROID_KERNEL_PATH

	echo " "
	echo "[!] Build AOSP"
	echo "> source build/envsetup.sh"
	source build/envsetup.sh

	echo "> lunch aosp_cf_arm64_only_phone-trunk_staging-userdebug"
	lunch aosp_cf_arm64_only_phone-trunk_staging-userdebug

	echo "Update ndk abi..."
	if ! development/tools/ndk/update_ndk_abi.sh; then
		echo "ERROR: updating ndk abi is failed"
		exit $EXIT_AOSP_BUILD
	fi

	echo "Building AOSP..."
	echo "> m"
	if ! m; then
		echo "ERROR: AOSP build failed"
		exit $EXIT_AOSP_BUILD
	fi
}

function _build_android_kernel() {
	local kernel_dir=$1
	local kernel_url=$2
	local manifest_branch=$3
	local build_target=$4

	echo " "
	echo "[!] Prepare Android Kernel Source Code"

	if [ ! -d "$kernel_dir" ]; then
		mkdir -p "$kernel_dir"
	fi

	echo "> cd $kernel_dir"
	cd "$kernel_dir" || exit $EXIT_CD_FAILED

	if [ ! -d ".repo" ]; then
		echo "> repo init -b $manifest_branch -u $kernel_url"
		if ! repo init -b "$manifest_branch" -u "$kernel_url"; then
			echo "ERROR: kernel repo init failed"
			exit $EXIT_REPO_DOWNLOAD
		fi
	else
		echo ".repo already exists. Skip initializing the Kernel repo"
	fi

	echo "> repo sync"
	if ! repo sync; then
		echo "ERROR: kernel repo sync failed"
		exit $EXIT_REPO_DOWNLOAD
	fi

	echo " "
	echo "[!] Build Android Kernel"

	echo "> tools/bazel run $build_target"
	if ! tools/bazel run "$build_target"; then
		echo "ERROR: kernel build failed"
		exit $EXIT_KERNEL_BUILD
	fi
}

function build_host_android_kernel() {
	_build_android_kernel \
		"$HOST_ANDROID_KERNEL_DIR" \
		"$ANDROID_KERNEL_URL" \
		"$HOST_ANDROID_KERNEL_MANIFEST_BRANCH" \
		"$HOST_ANDROID_KERNEL_BUILD_TARGET"

	echo "Check kernel built images..."
	realpath $HOST_ANDROID_INITRAMFS_PATH
	realpath $HOST_ANDROID_KERNEL_IMG_PATH
}

function build_guest_android_kernel() {
	_build_android_kernel \
		"$GUEST_ANDROID_KERNEL_DIR" \
		"$ANDROID_KERNEL_URL" \
		"$GUEST_ANDROID_KERNEL_MANIFEST_BRANCH" \
		"$GUEST_ANDROID_KERNEL_BUILD_TARGET"

	echo "Check kernel built images..."
	realpath $GUEST_ANDROID_KERNEL_IMG_PATH
}

function build_bootconfig() {
	cd $HOST_ANDROID_KERNEL_DIR/common/tools/bootconfig
	make
	mkdir -p $ROOT/out
	cp bootconfig $ROOT/out
}

install_required_packages

prepare_chrony_configuration
build_guest_android_kernel
build_host_android_kernel
build_bootconfig

build_aosp
