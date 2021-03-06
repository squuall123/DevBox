
set -eux 
mkdir -p /tmp/doimg/

docker run -i --rm --privileged -v /tmp/doimg:/tmp/doimg centos:7.2.1511 bash << 'EOF'
set -eux
WORKDIR=/workdir
TMPMNT=/workdir/tmp/mnt

# Vars for the image
QCOWXZIMGURL='http://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud-1604.qcow2.xz'
QCOWXZIMGSUM='ac832790bee379fe28f814e22f607f01111fff366fe08f81e14f35dd19bcec53'
QCOWXZIMG=$(basename $QCOWXZIMGURL) # Just the file name
QCOWIMG=${QCOWXZIMG:0:-3}           # Pull .xz off of the end
IMG="${QCOWIMG:0:-6}.raw"    # Pull off .qcow2 and add .raw

# URL/File location for upstream DO data source file.
DODATASOURCEURL='http://bazaar.launchpad.net/~cloud-init-dev/cloud-init/trunk/download/head:/datasourcedigitaloce-20141016153006-gm8n01q6la3stalt-1/DataSourceDigitalOcean.py'
export DODATASOURCEFILE='/usr/lib/python2.7/site-packages/cloudinit/sources/DataSourceDigitalOcean.py'

# File location for DO cloud config
export DOCLOUDCFGFILE='/etc/cloud/cloud.cfg.d/01_digitalocean.cfg'

# Create workdir and cd to it
mkdir -p $TMPMNT && cd $WORKDIR

# Get any additional rpms that we need
yum install -y gdisk wget qemu-img xfsprogs

# Get the xz image, verify, and decompress the contents
wget $QCOWXZIMGURL 
imgsum=$(sha256sum $QCOWXZIMG | cut -d " " -f 1)
if [ "$imgsum" != "$QCOWXZIMGSUM" ]; then
    echo "Checksum doesn't match: $imgsum"
    exit 1
fi
unxz $QCOWXZIMG

# Convert the qcow2 into a raw disk
qemu-img convert -f qcow2 -O raw $QCOWIMG $IMG

# Convert to GPT (needed for DOs "external kernel management")
sgdisk -g -p $IMG

# Find the starting byte and the total bytes in the 1st partition
# NOTE: normally would be able to use partx/kpartx directly to loopmount
#       the disk image and add the partitions, but inside of docker I found
#       that wasn't working quite right so I resorted to this manual approach.
PAIRS=$(partx --pairs $IMG)
eval `echo "$PAIRS" | head -n 1 | sed 's/ /\n/g'`
STARTBYTES=$((512*START))   # 512 bytes * the number of the start sector
TOTALBYTES=$((512*SECTORS)) # 512 bytes * the number of sectors in the partition

# Discover the next available loopback device
LOOPDEV=$(losetup -f)
LOMAJOR=''

# Make the loopback device if it doesn't exist already
if [ ! -e $LOOPDEV ]; then
    LOMAJOR=${LOOPDEV#/dev/loop} # Get just the number
    mknod -m660 $LOOPDEV b 7 $LOMAJOR
fi

# Loopmount the first partition of the device
losetup -v --offset $STARTBYTES --sizelimit $TOTALBYTES $LOOPDEV $IMG

# Add in DOROOT label to the root partition
xfs_admin -L 'DOROOT' $LOOPDEV

# Mount it on $TMPMNT
mount $LOOPDEV $TMPMNT

# Get the DO datasource and store in the right place
curl $DODATASOURCEURL > ${TMPMNT}/${DODATASOURCEFILE}
chcon system_u:object_r:lib_t:s0 ${TMPMNT}/${DODATASOURCEFILE}

# Put in place the config from Digital Ocean
cat << END > ${TMPMNT}/${DOCLOUDCFGFILE}
datasource_list: [ DigitalOcean, None ]
datasource:
 DigitalOcean:
   retries: 5
   timeout: 10
vendor_data:
   enabled: True
END
chcon system_u:object_r:etc_t:s0 ${TMPMNT}/${DOCLOUDCFGFILE}

# umount and tear down loop device
umount $TMPMNT
losetup -d $LOOPDEV
[ ! -z $LOMAJOR ] && rm -f $LOOPDEV #Only remove if we created it

# finally, cp $IMG into /tmp/doimg/ on the host
cp -a $IMG /tmp/doimg/ 

EOF