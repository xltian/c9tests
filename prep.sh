#!/bin/bash

#
# Make a devenv into a C9 node capable of 15k gears.
# This script may be run multiple times, make it idempotent.
#

source /etc/openshift/node.conf

# Switching to ephemeral storage for speed and space
if [ `stat -f -c '%i' /var/lib/openshift` == `stat -f -c '%i' /var` ]
then
    # We have gears? nuke them.  Allow this to fail.
    grep ":${GEAR_GECOS}:" /etc/passwd | cut -f 1 -d : | while read gearn
    do
        ( 
            for f in /var/lib/openshift/$gearn/.env/*; do
                source $f
            done
            OPENSHIFT_APP_DOMAIN=`echo $OPENSHIFT_APP_DNS | cut -f 1 -d . | cut -f 2 -d -`
            oo-app-destroy \
                --with-container-uuid "$OPENSHIFT_GEAR_UUID" \
                --with-container-name "$OPENSHIFT_GEAR_NAME" \
                --with-app-uuid "$OPENSHIFT_APP_NAME" \
                --with-app-name "$OPENSHIFT_APP_UUID" \
                --with-namespace "$OPENSHIFT_APP_DOMAIN"
        ) || :
    done

    # Disable quotas on /var
    quotaoff -ug /var
    rm -f /var/aquota.user
    sed -i -e 's|,usrjquota=aquota.user,jqfmt=vfsv0||' /etc/fstab

    # Setup the device for openshift
    trydevs=( `tail -n +3 /proc/partitions | awk '{ print $4 }' | grep -v '[0-9]'` )
    diskdevs=()
    diskcount=0
    for d in "${trydevs[@]}"
    do
        if [ -e "/dev/${d}" ]
        then
            if ! grep -q "$d" /proc/mounts
            then
                dd if=/dev/zero of="/dev/${d}" bs=1024k count=100
                diskdevs=( "${diskdevs[@]}" "/dev/${d}" )
                diskcount=$(( $diskcount + 1 ))
            fi
        fi
    done

    # Make a raid if we have more than one disk
    if [ $diskcount -gt 1 ]; then
        mdadm --create md0 --level=stripe --raid-disks=$diskcount "${diskdevs[@]}"
        diskdevs="/dev/md/md0"
    fi

    # Make openshift and setup quotas
    mkfs.ext4 -O ^has_journal "$diskdevs"
    tune2fs -c 0 -i 0 "$diskdevs"
    tune2fs -L 'openshift' "$diskdevs"
    tune2fs -o +nobarrier "$diskdevs"
    echo 'LABEL=openshift /var/lib/openshift ext4 defaults,usrjquota=aquota.user,jqfmt=vfsv0 1 1' >> /etc/fstab
    mount -a
    mkdir -m 750 /var/lib/openshift/.httpd.d/
    setenforce 0
    quotacheck -cmuf /var/lib/openshift
    restorecon -r /var/lib/openshift
    setenforce 1
    quotaon -u /var/lib/openshift

    # And we need a big swap
    dd if=/dev/zero of=/var/lib/openshift/.swapfile bs=1024k count=8192
    restorecon /var/lib/openshift/.swapfile
    mkswap /var/lib/openshift/.swapfile
    swapon /var/lib/openshift/.swapfile
fi

# We're creating thousands of directories already.
sed -i -e 's|CREATE_APP_SYMLINKS=1|CREATE_APP_SYMLINKS=0|' /etc/openshift/node.conf
sed -i -e 's|GEAR_MAX_UID=6500|GEAR_MAX_UID=262143|' /etc/openshift/node.conf

# Keep the node alive for a long time
echo "HOURS=66666" > /etc/charlie.conf

# Need these for testing
rpm -q setools-console || yum -y install setools-console
rpm -q nc || yum -y install nc

# Remove expensive crontabs
rm -f /etc/cron.*/openshift-origin-cron-*
rm -f /etc/cron.daily/openshift_tmpwatch.sh 
rm -f /etc/cron.daily/mlocate.cron
rm -f /etc/cron.hourly/charlie 
rm -f ./cron.minutely/openshift-facts
crontab -u root -r || :
service crond reload

# Setup resource limits for C9
rm -f /etc/openshift/resource_limits.conf
ln -sf resource_limits.conf.c9 /etc/openshift/resource_limits.conf

# Shrink down httpd configuration so that its not a hog
sed -i \
    -e 's|^StartServers .*$|StartServers 1|' \
    -e 's|^MinSpareServers .*$|MinSpareServers 1|' \
    -e 's|^MaxSpareServers .*$|MaxSpareServers 1|' \
    -e 's|^ServerLimit .*$|ServerLimit 1|' \
    -e 's|^MaxClients .*$|MaxClients 1|' \
    -e 's|^MaxRequestsPerChild .*$|MaxRequestsPerChild 400|' \
    /etc/httpd/conf/httpd.conf

# Disable unneeded services and restart ones we've reconfigured
service rhc-broker stop ; chkconfig rhc-broker off
service rhc-site stop ; chkconfig rhc-site off
service mcollective stop ; chkconfig mcollective off
service libra-watchman stop ; chkconfig libra-watchman off
service activemq stop; chkconfig activemq off
service mongod stop; chkconfig mongod off
service jenkins stop; chkconfig jenkins off
chkconfig openshift-gears off
service openshift-cgroups restart
service httpd restart

# This should pass
rhc-accept-node
