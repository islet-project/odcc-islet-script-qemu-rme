# Environment Setup for Confidential Computing on Android
## 1. Build AOSP source and Android kernels.
```bash
./scripts/init_android_on_qemu.sh
```

Source codes are downloaded to the root of this project
```bash
> ls
android16-6.12-host    README.md          scripts
android15-6.6-realm    aosp-15.0.0_r8     LICENSE
```

## 2. Build CCA firmware.
Go to your [Islet](https://github.com/islet-project/islet) root, delete the existing firmware if you were working on fvp-cca,
and build it again using the command below:

```bash
cd ${your-islet-root}
./scripts/fvp-cca --clean tf-a
./scripts/fvp-cca --clean tf-rmm
./scripts/fvp-cca --clean islet

# Note: Set rmm-log-level to warn. Otherwise, rmm gets busy with printing logs out and handling IRQs without making progress.
./scripts/qemu-cca -nw linux -rmm islet --hes --rmm-log-level warn -bo --no-sdk
```

## 3. Install Cuttlefish, an Android Virtual Device.

1. Register the apt repository on Artifact Registry.

```bash
sudo curl -fsSL https://us-apt.pkg.dev/doc/repo-signing-key.gpg \
    -o /etc/apt/trusted.gpg.d/artifact-registry.asc
sudo chmod a+r /etc/apt/trusted.gpg.d/artifact-registry.asc
echo "deb https://us-apt.pkg.dev/projects/android-cuttlefish-artifacts android-cuttlefish main" \
    | sudo tee -a /etc/apt/sources.list.d/artifact-registry.list
sudo apt update
```

2. Download the packages.

```bash
sudo apt install cuttlefish-base
sudo usermod -aG kvm,cvdnetwork,render $USER
sudo reboot
```

## 4. Run Cuttlefish.

```bash
cd ${this-branch}
./scripts/run_cuttlefish.sh ${your-islet-root}
```

To Access the Android screen, connect to localhost:6444 using a VNC viewer.
As an alternative, you can use [scrcpy](https://github.com/Genymobile/scrcpy).

To build scrcpy,

```bash
sudo apt install ffmpeg libsdl2-2.0-0 adb wget \
                 gcc git pkg-config meson ninja-build libsdl2-dev \
                 libavcodec-dev libavdevice-dev libavformat-dev libavutil-dev \
                 libswresample-dev libusb-1.0-0 libusb-1.0-0-dev
git clone https://github.com/Genymobile/scrcpy
cd scrcpy
./install_release.sh
```
