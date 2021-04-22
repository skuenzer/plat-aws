#!/usr/bin/env bash
# This script automates the process of deploying unikraft built images
# to AWS EC2 service.
# !!!!! IMPORTANT !!!!
# This script needs all the environmrntal variables mentioned in the
# "config-aws.sh" file to be set correctly. Any unset value or
# incorrect value will cause the script to halt.

# Global Defines
GREEN="\e[92m"
LIGHT_BLUE="\e[94m"
RED="\e[31m"
LIGHT_RED="\e[91m"
GRAY_BG="\e[100m"
UNDERLINE="\e[4m"
BOLD="\e[1m"
END="\e[0m"

# Default Values to be taken if not provided to the script.
NAME=unikraft
# Never put a minus for the bucket name!
BUCKET=unikraft
REGION=eu-central-1
INSTYPE=m3.medium
CONFIG_FILE=config-aws.sh
CONFIG_DIR="$HOME/.unikraft"
CONFIG_PATH_DEF="$CONFIG_DIR/$CONFIG_FILE"
ARCH=x86_64
TMP_DIR=aws_ec2_tmp

# Gives script usage information to the user
function usage () {
   echo "usage: $0 [-h] [-v] -k <unikernel> -p <config-path> [-n <name>]"
   echo -e "\n     [-I <initrd>] [-b <bucket>] [-r <region>] [-i <instance-type>] [-s]"
   echo ""
   echo -e "${UNDERLINE}Mandatory Args:${END}"
   echo "<unikernel>: 	  Name/Path of the unikernel generated by Unikraft.(Please use \"Xen\" target images) "
   echo "<initrd>: 	  Name/Path of the initrd."
   echo "<config-path>:	  Path of the script config file (Default: ${CONFIG_PATH_DEF})"
   echo ""
   echo -e "${UNDERLINE}Optional Args:${END}"
   echo "<name>: 	  Image name to use on the cloud (default: ${NAME})"
   echo "<bucket>: 	  AWS S3 bucket name (default: ${BUCKET})"
   echo "<region>: 	  AWS EC2 region to register AMI (default: ${REGION})"
   echo "<instance-type>:  Specify the type of the machine on which you wish to deploy the kernel (default: ${INSTYPE}) "
   echo "<-v>: 		  Turns on verbose mode"
   echo "<-s>: 		  Automatically starts an instance on AWS cloud"
   echo ""
   echo -e "${LIGHT_RED}#########  !!IMPORTANT!!  #############${END}"
   echo  -- Please set the environment variables in \"config-aws.sh\" file.
   echo  -e "-- Please make sure that following packages are installed:
   - AWS EC2 AMI TOOLS (sudo apt install ec2-ami-tools)
   - AWS EC2 API TOOLS (sudo apt-get install ec2-api-tools)
   - AWS CLI TOOLS (sudo apt  install awscli) "
   echo "* Installation commands are given for Debian based systems like Ubuntu."
   echo "Please install the packages according to your system."
   exit 1
}
# Directs the script output to data sink
log_pause(){
if [ -z "$V" ]
then
	exec 6>&1
	exec &>/dev/null
fi
}

# Restores the script output to STDOUT
log_resume(){
if [ -z "$V" ]
then
	exec >&6
fi
}

# If any command fails in script, this function will be invoked to handle the error.
function handle_error (){
	log_resume
	echo -e "${RED}[FAILED]${END}"
	echo -e "${LIGHT_BLUE}Error${END} on line:$1"
	echo -e "Please run the script with verbose mode ${GRAY_BG}-v${END} too see detailed error"
	clean
	exit 1
}

clean() {
echo -n "Cleaning temporary files................"
log_pause
#rm -rf ${TMP_DIR}
#rm -r ${IMG}
log_resume
echo -e "${GREEN}[OK]${END}"
}


# Process the arguments given to script by user
while getopts "vshk:I:n:p:b:r:i:" opt; do
 case $opt in
 h) usage;;
 p) CONFIG_PATH=$OPTARG ;;
 n) NAME=$OPTARG ;;
 b) BUCKET=$OPTARG ;;
 r) REGION=$OPTARG ;;
 k) UNIKERNEL=$OPTARG ;;
 I) INITRD=$OPTARG ;;
 i) INSTYPE=$OPTARG ;;
 v) V=true ;;
 s) S=true ;;
 esac
done

shift $((OPTIND-1))

# Check if provided image file exists.
if [ ! -e "$UNIKERNEL" ]; then
  echo "Please specify a unikraft image with required [-k] flag."
  echo "Run '$0 -h' for more help"
  exit 1
fi

# Check if provided config file exists.
if [ ! -e "$CONFIG_PATH" ]; then
	if [ ! -e $CONFIG_PATH_DEF ]; then
		echo -e "${LIGHT_RED}No config file found!${END}"
	        echo "Please copy the config file ${CONFIG_FILE} to \"${CONFIG_DIR}\" dir or "
		echo "specify config file path with [-p] flag."
		echo "Run '$0 -h' for full option list."
		exit 1
	else
		# Use Default file as config file.
		CONFIG_PATH="$CONFIG_PATH_DEF"
	fi
fi


# Configure the environment and paths needed for script to run properly.
. ${CONFIG_PATH} -r ${REGION}

# Make name unique to avoid registration clashes
NAME=${NAME}-`date +%s`
MNT_DIR=$( mktemp -d )
TMP_DIR=$( mktemp -d )
SUDO=sudo
IMG=${NAME}.img

${SUDO} echo "" >/dev/null
echo -e "Deploying ${LIGHT_BLUE}${IMG}${END} on AWS..."
echo -e "${BOLD}Name  :${END} ${NAME}"
echo -e "${BOLD}Bucket:${END} ${BUCKET}"
echo -e "${BOLD}Region:${END} ${REGION}"
echo ""

# set error callback
trap 'handle_error $LINENO' ERR

echo -n "Fetching the pv-grub Kernel-Id..........";
log_pause
if [ ${REGION} = "eu-central-1" ];
then
	# Hard code the kernel-id for 'eu-central-1' region. Saves few seconds.
	KERNEL='aki-931fe3fc'
else
	# Get the pv-grub kernel-id based on the provided region
	KERNEL=`ec2-describe-images -o amazon --region ${REGION} -F "manifest-location=*pv-grub-hd0*" -F "architecture=x86_64" | tail -1 | cut -f2`
fi
log_resume
echo -e "${GREEN}[OK]${END}"


# Create the image disk
${SUDO} mkdir -p ${MNT_DIR}
rm -f ${IMG}
echo -n "Creating Disk Image (4MB)...............";
log_pause
# This echo maintains the formatting
echo ""
dd if=/dev/zero of=${TMP_DIR}/${IMG} bs=1M count=4
${SUDO} mke2fs -F -j ${TMP_DIR}/${IMG}
${SUDO} mount -o loop ${TMP_DIR}/${IMG} ${MNT_DIR}
${SUDO} mkdir -p ${MNT_DIR}/boot/grub

# Create menu.lst (grub) file
if [ ! -z "$INITRD" ]; then
cat > menu.lst << EOF
default 0
timeout 0
title Unikraft
 root (hd0)
 kernel /boot/kernel
 initrd /boot/initrd
EOF
else
cat > menu.lst << EOF
default 0
timeout 0
title Unikraft
 root (hd0)
 kernel /boot/kernel
EOF
fi
${SUDO} mv menu.lst ${MNT_DIR}/boot/grub/menu.lst
${SUDO} sh -c "cp -v $UNIKERNEL ${MNT_DIR}/boot/kernel"
[ ! -z "$INITRD" ] && ${SUDO} sh -c "cp -v $INITRD ${MNT_DIR}/boot/initrd"
${SUDO} umount -d ${MNT_DIR}
log_resume
echo -e "${GREEN}[OK]${END}"
echo -n "Creating image bundle...................";
log_pause
# This echo maintains the formatting
echo ""
ec2-bundle-image -i ${TMP_DIR}/${IMG} -k ${EC2_PRIVATE_KEY} -c ${EC2_CERT} -u ${EC2_USER} -d ${TMP_DIR} -r ${ARCH} --kernel ${KERNEL}
log_resume
echo -e "${GREEN}[OK]${END}"
# Upload the bundle to the AWS cloud (i.e. to S3)
echo -n "Uploading bundle to cloud...............";
log_pause
# This echo maintains the formatting
echo ""
ec2-upload-bundle -b ${BUCKET} -m ${TMP_DIR}/${IMG}.manifest.xml -a ${AWS_ACCESS_KEY} -s ${AWS_SECRET_KEY} --region ${REGION}
log_resume
echo -e "${GREEN}[OK]${END}"
echo -n "Registering image on the cloud.........."
log_pause
# This echo maintains the formatting
echo ""
aws ec2 register-image --image-location ${BUCKET}/${IMG}.manifest.xml --architecture ${ARCH} --name ${NAME} --virtualization-type paravirtual
log_resume
echo -e "${GREEN}[OK]${END}"

clean
echo ""
echo "To run the instance on AWS, use following command-"
echo -e "${GRAY_BG}insID=\`aws ec2 run-instances --region ${REGION} --image-id <ami-ID> --count 1 --instance-type ${INSTYPE} | awk 'FNR == 2 {print $2}'\`${END}"
insID="<insID>"
else
    echo -n "Starting the instance on the cloud......"
	log_pause
	# This echo maintains the formatting
	echo ""
	# Start an instance on the cloud
	insID=`ec2-run-instances ${amiID} --region ${REGION} -k ukraft-key-eu -t ${INSTYPE} | awk 'FNR == 2 {print $2}'`
	echo "AWS Instance ID: ${insID}"
	log_resume
	echo -e "${GREEN}[OK]${END}"
	clean
fi
echo ""
echo -e "${UNDERLINE}NOTE:${END}"
echo "1) To see the AWS system console log, use following command-"
echo -e "${GRAY_BG}aws ec2 get-console-output --instance-id <ins ID> --query Output --output text --region ${REGION}${END}"
echo "2) AWS takes some time to initialise the instance and start the booting process"
# AWS changes required
echo "3) Don't forget to customise this with a security group, as the
echo default one won't let any inbound traffic in."
echo ""
