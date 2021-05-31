#!/bin/bash
# MIT License 
# Copyright (c) 2017 Ken Fallon http://kenfallon.com
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# v1.1 - changes to reflect that the sha_sum is now SHA-256
# v1.2 - Changes to split settings to different file, and use losetup
# v1.3 - Removed requirement to use xmllint (Thanks MachineSaver)
#        Added support for wifi mac naming (Thanks danielo515)
#        Moved ethernet naming to firstboot.sh

# Credits to:
# - http://hackerpublicradio.org/correspondents.php?hostid=225
# - https://gpiozero.readthedocs.io/en/stable/pi_zero_otg.html#legacy-method-sd-card-required
# - https://github.com/nmcclain/raspberian-firstboot

# Change the settings in the file mentioned below.

settings_file="fix-ssh-on-pi.ini"

# You should not need to change anything beyond here.

if [ -e "${settings_file}" ]
then
  source "${settings_file}"
elif [ -e "${HOME}/${settings_file}" ]
then
  source "${HOME}/${settings_file}"
elif [ -e "${0%.*}.ini" ]
then
  source "${0%.*}.ini"
else
  echo "ERROR: Can't find the Settings file \"${settings_file}\""
  exit 1
fi

variables=(
  # root_password_clear
  # pi_password_clear
  public_key_file
  wifi_file
  os_type
)

for variable in "${variables[@]}"
do
  if [[ -z ${!variable+x} ]]; then   # indirect expansion here
    echo "ERROR: The variable \"${variable}\" is missing from your \""${settings_file}"\" file.";
    exit 2
  fi
done

image_to_download="https://downloads.raspberrypi.org/raspios_${os_type}_armhf_latest"
url_base="https://downloads.raspberrypi.org/raspios_${os_type}_armhf/images/"
version="$( wget -q ${url_base} -O - | grep -o raspios_${os_type}_armhf-[0-9]*-[0-9]*-[0-9]*/ - | sort -nr | head -1 )"
sha_file=$( wget -q ${url_base}/${version} -O - | awk -F '"' '/zip.sha256/ {print $8}' - )

sha_sum=$( wget -q "${url_base}/${version}/${sha_file}" -O - | awk '{print $1}' )
sdcard_mount="/mnt/sdcard"

if [ $(id | grep 'uid=0(root)' | wc -l) -ne "1" ]
then
    echo "You are not root "
    exit
fi

if [ ! -e "${public_key_file}" ]
then
    echo "Can't find the public key file \"${public_key_file}\""
    echo "You can create one using:"
    echo "   ssh-keygen -t ed25519 -f ./${public_key_file} -C \"Raspberry Pi keys\""
    exit 3
fi

function umount_sdcard () {
    umount "${sdcard_mount}"
    if [ $( ls -al "${sdcard_mount}" | wc -l ) -eq "3" ]
    then
        echo "Sucessfully unmounted \"${sdcard_mount}\""
        sync
    else
        echo "Could not unmount \"${sdcard_mount}\""
        exit 4
    fi
}

# Download the latest image, using the  --continue "Continue getting a partially-downloaded file"
if [ ! -e raspbian_image.zip ]
then
	echo "Didn't find raspbian_image.zip. Going to download it now."
	wget --continue ${image_to_download} -O raspbian_image.zip
fi

echo "Checking the SHA-1 of the downloaded image matches \"${sha_sum}\""

if [ $( sha256sum raspbian_image.zip | grep ${sha_sum} | wc -l ) -eq "1" ]
then
    echo "The sha_sums match"
else
    echo "The sha_sums did not match"
    exit 5
fi

if [ ! -d "${sdcard_mount}" ]
then
  mkdir ${sdcard_mount}
fi

# unzip
extracted_image=$( zipnote raspbian_image.zip |head -n1|sed 's/^@ //' )
echo "The name of the image is \"${extracted_image}\""

unzip raspbian_image.zip

if [ ! -e ${extracted_image} ]
then
    echo "Can't find the image \"${extracted_image}\""
    exit 6
fi

umount_sdcard
echo "Mounting the sdcard boot disk"

loop_base=$( losetup --partscan --find --show "${extracted_image}" )

echo "Running: mount ${loop_base}p1 \"${sdcard_mount}\" "
mount ${loop_base}p1 "${sdcard_mount}"
ls -al /mnt/sdcard
if [ ! -e "${sdcard_mount}/kernel.img" ]
then
    echo "Can't find the mounted card\"${sdcard_mount}/kernel.img\""
    exit 7
fi

cp -v "${wifi_file}" "${sdcard_mount}/wpa_supplicant.conf"
if [ ! -e "${sdcard_mount}/wpa_supplicant.conf" ]
then
    echo "Can't find the wpa_supplicant file \"${sdcard_mount}/wpa_supplicant.conf\""
    exit 8
fi

touch "${sdcard_mount}/ssh"
if [ ! -e "${sdcard_mount}/ssh" ]
then
    echo "Can't find the ssh file \"${sdcard_mount}/ssh\""
    exit 9
fi

if [ -e "${first_boot}" ]
then
  cp -v "${first_boot}" "${sdcard_mount}/firstboot.sh"
fi

umount_sdcard

echo "Mounting the sdcard root disk"
echo "Running: mount ${loop_base}p2 \"${sdcard_mount}\" "
mount ${loop_base}p2 "${sdcard_mount}"
ls -al /mnt/sdcard

if [ ! -e "${sdcard_mount}/etc/shadow" ]
then
    echo "Can't find the mounted card\"${sdcard_mount}/etc/shadow\""
    exit 10
fi

echo "Change the passwords and sshd_config file"
echo "Setting root password"
root_password="$( python3 set_pw.py)"
echo "Please type password again"
while [ "$( python3 verify_pw.py $root_password )" != "True" ]
do
    echo "Verificytion failed, passwords don't match"
    root_password="$( python3 set_pw.py)"
    echo "Please type password again"
done

pi_password="$( python3 -c "import crypt; print(crypt.crypt('${pi_password_clear}', crypt.mksalt(crypt.METHOD_SHA512)))" )"
echo "Setting pi password"
pi_password="$( python3 set_pw.py)"
echo "Please type password again"
while [ "$( python3 verify_pw.py $pi_password )" != "True" ]
do
    echo "Verificytion failed, passwords don't match"
    pi_password="$( python3 set_pw.py)"
    echo "Please type password again"
done


sed -e "s#^root:[^:]\+:#root:${root_password}:#" "${sdcard_mount}/etc/shadow" -e  "s#^pi:[^:]\+:#pi:${pi_password}:#" -i "${sdcard_mount}/etc/shadow"
sed -e 's;^#PasswordAuthentication.*$;PasswordAuthentication no;g' -e 's;^PermitRootLogin .*$;PermitRootLogin no;g' -i "${sdcard_mount}/etc/ssh/sshd_config"
mkdir "${sdcard_mount}/home/pi/.ssh"
chmod 0700 "${sdcard_mount}/home/pi/.ssh"
chown 1000:1000 "${sdcard_mount}/home/pi/.ssh"
cat ${public_key_file} >> "${sdcard_mount}/home/pi/.ssh/authorized_keys"
chown 1000:1000 "${sdcard_mount}/home/pi/.ssh/authorized_keys"
chmod 0600 "${sdcard_mount}/home/pi/.ssh/authorized_keys"
if [ -e "${first_boot}" ]
then
    echo "[Unit]
    Description=FirstBoot
    After=network.target
    Before=rc-local.service
    ConditionFileNotEmpty=/boot/firstboot.sh

    [Service]
    ExecStart=/boot/firstboot.sh
    ExecStartPost=/bin/mv /boot/firstboot.sh /boot/firstboot.sh.done
    Type=oneshot
    RemainAfterExit=no

    [Install]
    WantedBy=multi-user.target" > "${sdcard_mount}/lib/systemd/system/firstboot.service"

    cd "${sdcard_mount}/etc/systemd/system/multi-user.target.wants" && ln -s "/lib/systemd/system/firstboot.service" "./firstboot.service"
    cd -
fi
echo ""
echo "Do you want to change the Hostname?(Y/n)"
read QHOST
if [ "${QHOST,,}" == "y" ] || [ $QHOST == "" ]
then
    echo "Enter hostname"
    read HNAME
    echo $HNAME > $sdcard_mount/etc/hostname
fi
echo ""

echo "Do you want a static ipv4 address?(y/N)"
read QIP
if [ "${QIP,,}" == "y" ]
then
    if [ -e static_ip.conf ]
    then
        cat static_ip.conf >> $sdcard_mount/etc/dhcpcd.conf
    else
        echo "static_ip.conf not found"
        echo "ip address not changed to static"
    fi
fi

umount_sdcard

rm -r ${sdcard_mount}
new_name="${extracted_image%.*}-ssh-enabled.img"
cp -v "${extracted_image}" "${new_name}"

losetup -d ${loop_base}

lsblk

echo ""
echo "Now you can burn the disk using something like:"
echo "      dd bs=4M status=progress if=${new_name} of=/dev/mmcblk????"
echo ""
