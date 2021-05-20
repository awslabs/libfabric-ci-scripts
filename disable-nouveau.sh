#!/bin/bash
set -xe

os_name="$(. /etc/os-release; echo $NAME)"

cat << EOF | sudo tee --append /etc/modprobe.d/blacklist.conf
blacklist vga16fb
blacklist nouveau
blacklist rivafb
blacklist nvidiafb
blacklist rivatv
EOF

echo "GRUB_CMDLINE_LINUX="rdblacklist=nouveau"" | sudo tee -a /etc/default/grub
if [ "$os_name" == "Ubuntu" ]; then
    sudo update-grub
else
    sudo grub2-mkconfig -o /boot/grub2/grub.cfg
fi
