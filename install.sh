#!/bin/bash

# === Configurable ===
KERNEL_SUFFIX="-dev-$(date +%b%d-%H%M)"
MAKE_THREADS=$(nproc)

# === Optional ===
CLEAN_BUILD=false  # Set to true for full rebuild
DO_KEXEC=false     # Set to true to boot into new kernel with kexec

# === Step 0: Check Dependencies ===
REQUIRED_CMDS=(
    make gcc bc bison flex
    libssl-dev libelf-dev libncurses-dev
    libudev-dev libpci-dev libiberty-dev
    dwarves
)

MISSING_PKGS=()

echo ">> Checking build dependencies..."

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! dpkg -s "$cmd" &>/dev/null && ! command -v "$cmd" &>/dev/null; then
        MISSING_PKGS+=("$cmd")
    fi
done

if (( ${#MISSING_PKGS[@]} )); then
    echo "[ERROR] Missing required packages/tools:"
    printf ' - %s\n' "${MISSING_PKGS[@]}"
    echo "Install them using:"
    echo "  sudo apt install ${MISSING_PKGS[*]}"
    exit 1
fi

# === Step 1: Optionally clean ===
if [ "$CLEAN_BUILD" = true ]; then
    echo ">> Cleaning build directory..."
    make mrproper
fi

# === Step 2: Ensure .config exists ===
if [ ! -f .config ]; then
    echo ">> Copying running kernel config..."
    if [ -f /proc/config.gz ]; then
        zcat /proc/config.gz > .config
    elif [ -f /boot/config-$(uname -r) ]; then
        cp /boot/config-$(uname -r) .config
    else
        echo "[ERROR] Could not find kernel config. Exiting."
        exit 1
    fi



    yes "" | make olddefconfig
fi

# Fix for missing certs
scripts/config --disable SYSTEM_TRUSTED_KEYS
scripts/config --disable SYSTEM_REVOCATION_KEYS

scripts/config --set-str LOCALVERSION "$KERNEL_SUFFIX"
scripts/config --disable LOCALVERSION_AUTO

# === Step 2.5: Disable DKMS ===
if [ -d /etc/kernel/postinst.d/dkms ]; then
    echo ">> Temporarily disabling DKMS hook..."
    sudo mv /etc/kernel/postinst.d/dkms /etc/kernel/postinst.d/dkms.disabled
fi

# === Step 3: Build ===
echo ">> Building kernel..."
make -j"$MAKE_THREADS"

echo ">> Building modules..."
make -j"$MAKE_THREADS" modules

# === Step 4: Install modules ===
echo ">> Installing modules..."
sudo make modules_install

# === Step 6: Install kernel ===
echo ">> Installing kernel..."
sudo make install

# === Step 7: Re-enable DKMS ===
if [ -d /etc/kernel/postinst.d/dkms.disabled ]; then
    sudo mv /etc/kernel/postinst.d/dkms.disabled /etc/kernel/postinst.d/dkms
fi

# === Step 8: Install headers ===
echo ">> Installing headers..."
sudo make headers_install

# === Step 8.A: Update initramfs ===
sudo update-initramfs -c -k $(make kernelrelease)

# === Step 9: Update GRUB ===
echo ">> Updating GRUB..."
sudo update-grub

# === Step 10: Reboot or kexec ===
if [ "$DO_KEXEC" = true ]; then
    echo ">> Rebooting using kexec..."
    KERNEL_VERSION=$(make -s kernelrelease)
    sudo kexec -l /boot/vmlinuz-"$KERNEL_VERSION" \
        --initrd=/boot/initrd.img-"$KERNEL_VERSION" \
        --reuse-cmdline
    sudo kexec -e
else
    echo ">> Rebooting system..."
   # sudo reboot
fi

