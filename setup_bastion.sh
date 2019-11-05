#!/bin/sh

KEY_NAME="aws_ec2_key_pair"
KEY_FULL_NAME="$KEY_NAME.pem"
KEY_PATH="$HOME/.ssh/$KEY_FULL_NAME"

VPC_CIDR_BLOCK="13.13.0.0/16"
VPC_NAME_TAG="not default"

PUBLIC_SUBNET_CIDR="13.13.1.0/24"
PUBLIC_SUBNET_NAME_TAG="public subnet"

PRIVATE_SUBNET_CIDR="13.13.3.0/24"
PRIVATE_SUBNET_NAME_TAG="private subnet"

BASTION_SG_NAME="bastion-sg"
BASTION_SG_DESCRIPTION="Bastion security group"
BASTION_SG_NAME_TAG="bastion"

INTERNAL_SG_NAME="internal-sg"
INTERNAL_SG_DESCRIPTION="Internal security group"
INTERNAL_SG_NAME_TAG="internal"

BASTION_INSTANCE_NAME_TAG="bastion"
INTERNAL_INSTANCE_NAME_TAG="internal"

MY_IP="$(curl --silent https://checkip.amazonaws.com)"

# Create aws ec2 key pair for next SSH connections
aws ec2 create-key-pair \
    --key-name $KEY_NAME \
    --query 'KeyMaterial' \
    --output text > $KEY_PATH

# Make key read for me only rights
chmod 400 $KEY_PATH

# Create Not-Default VPC
VPC_ID="$(aws ec2 create-vpc --cidr-block $VPC_CIDR_BLOCK | jq -r .Vpc.VpcId)" 
echo "[VPC] $VPC_ID"

# Add Name tag to created VPC
aws ec2 create-tags \
    --resources $VPC_ID \
    --tags "Key=\"Name\",Value=\"${VPC_NAME_TAG}\""

# Create public subnet
PUBLIC_SUBNET_ID="$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PUBLIC_SUBNET_CIDR | jq -r .Subnet.SubnetId) "
echo "[Subnet] $PUBLIC_SUBNET_ID    (public)"

# Add Name tag to created public subnet
aws ec2 create-tags \
    --resources $PUBLIC_SUBNET_ID \
    --tags "Key=\"Name\",Value=\"${PUBLIC_SUBNET_NAME_TAG}\""

# Create private subnet
PRIVATE_SUBNET_ID="$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PRIVATE_SUBNET_CIDR | jq -r .Subnet.SubnetId)"
echo "[Subnet] $PRIVATE_SUBNET_ID    (private)"

# Add Name tag to created private subnet
aws ec2 create-tags \
    --resources $PRIVATE_SUBNET_ID \
    --tags "Key=\"Name\",Value=\"${PRIVATE_SUBNET_NAME_TAG}\""

# Create internet gateway
INTERNET_GATEWAY_ID="$(aws ec2 create-internet-gateway | jq -r .InternetGateway.InternetGatewayId)"
echo "[Internet Gateway] $INTERNET_GATEWAY_ID"

# Attach created internet gateway to VPC
aws ec2 attach-internet-gateway \
    --vpc-id $VPC_ID \
    --internet-gateway-id $INTERNET_GATEWAY_ID

# Find route table for VPC
ROUTE_TABLE_ID="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" | jq -r .RouteTables[0].RouteTableId)"

# Create route in route table for internet traffic
aws ec2 create-route \
    --route-table-id $ROUTE_TABLE_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $INTERNET_GATEWAY_ID > /dev/null

# Associate subnet with route table to make it public
aws ec2 associate-route-table \
    --subnet-id $PUBLIC_SUBNET_ID \
    --route-table-id $ROUTE_TABLE_ID > /dev/null

# Make all public subnet instances receive public IP address automatically after launch
aws ec2 modify-subnet-attribute \
    --subnet-id $PUBLIC_SUBNET_ID \
    --map-public-ip-on-launch

# Create security group for bastion host
BASTION_SG_ID="$(aws ec2 create-security-group --group-name $BASTION_SG_NAME --description "${BASTION_SG_DESCRIPTION}" --vpc-id $VPC_ID | jq -r .GroupId)"
echo "[Security Group] $BASTION_SG_ID (bastion)"

# Add Name tag to bastion security group
aws ec2 create-tags \
    --resources $BASTION_SG_ID \
    --tags "Key=\"Name\",Value=\"${BASTION_SG_NAME_TAG}\""

# Add TCP Port 22 persmission for my IP address to Bastion Security Group
aws ec2 authorize-security-group-ingress \
    --group-id $BASTION_SG_ID \
    --protocol tcp \
    --port 22 \
    --cidr "${MY_IP}/32"

# Create bastion host instance (Ubuntu 16.04 64-bit x86) in public subnet
BASTION_INSTANCE_ID="$(aws ec2 run-instances --image-id ami-050a22b7e0cf85dd0 --count 1 --instance-type t2.micro --key-name $KEY_NAME --security-group-ids $BASTION_SG_ID --subnet-id $PUBLIC_SUBNET_ID |  jq -r .Instances[0].InstanceId)"
echo "[Instance] $BASTION_INSTANCE_ID (bastion host)"

# Add Name tag to bastion instance
aws ec2 create-tags \
    --resources $BASTION_INSTANCE_ID \
    --tags "Key=\"Name\",Value=\"${BASTION_INSTANCE_NAME_TAG}\""

BASTION_INSTANCE_STATUS="terminated"
BASTION_INSTANCE_INFO=""
while [ $BASTION_INSTANCE_STATUS != "running" ]
do
    echo "[Instance] waiting bastion host status is \"running\""
    # Get bastion instance info for private and public ip address
    BASTION_INSTANCE_INFO="$(aws ec2 describe-instances --filter "Name=tag:Name,Values=${BASTION_INSTANCE_NAME_TAG}")"  
    BASTION_INSTANCE_STATUS="$(echo $BASTION_INSTANCE_INFO | jq -r .Reservations[0].Instances[0].State.Name)"
    sleep 5
done

BASTION_INSTANCE_PRIVATE_IP_ADDRESS="$(echo $BASTION_INSTANCE_INFO | jq -r .Reservations[0].Instances[0].PrivateIpAddress)"
BASTION_INSTANCE_PUBLIC_IP_ADDRESS="$(echo $BASTION_INSTANCE_INFO | jq -r .Reservations[0].Instances[0].PublicIpAddress)"

# Create security group for internal hosts
INTERNAL_SG_ID="$(aws ec2 create-security-group --group-name $INTERNAL_SG_NAME --description "${INTERNAL_SG_DESCRIPTION}" --vpc-id $VPC_ID | jq -r .GroupId)"
echo "[Security Group] $INTERNAL_SG_ID (internal)"

# Add Name tag to internal security group
aws ec2 create-tags \
    --resources $INTERNAL_SG_ID \
    --tags "Key=\"Name\",Value=\"${INTERNAL_SG_NAME_TAG}\""

# Add TCP Port 22 persmission for bastion private network IP address to Internal Security Group
aws ec2 authorize-security-group-ingress \
    --group-id $INTERNAL_SG_ID \
    --protocol tcp \
    --port 22 \
    --cidr "${BASTION_INSTANCE_PRIVATE_IP_ADDRESS}/32"

# Create internal host instance (Ubuntu 16.04 64-bit x86) in private subnet
INTERNAL_INSTANCE_ID="$(aws ec2 run-instances --image-id ami-050a22b7e0cf85dd0 --count 1 --instance-type t2.micro --key-name aws_ec2_key_pair --security-group-ids $INTERNAL_SG_ID --subnet-id $PRIVATE_SUBNET_ID |  jq -r .Instances[0].InstanceId)"
echo "[Instance] $INTERNAL_INSTANCE_ID (internal host)"

# Add Name tag to internal instance
aws ec2 create-tags \
    --resources $INTERNAL_INSTANCE_ID \
    --tags "Key=\"Name\",Value=\"${INTERNAL_INSTANCE_NAME_TAG}\""

INTERNAL_INSTANCE_STATUS="terminated"
INTERNAL_INSTANCE_INFO=""
while [ $INTERNAL_INSTANCE_STATUS != "running" ]
do
    echo "[Instance] waiting internal host status is \"running\""
    # Get bastion instance info for private and public ip address
    INTERNAL_INSTANCE_INFO="$(aws ec2 describe-instances --filter "Name=tag:Name,Values=${INTERNAL_INSTANCE_NAME_TAG}")"  
    INTERNAL_INSTANCE_STATUS="$(echo $INTERNAL_INSTANCE_INFO | jq -r .Reservations[0].Instances[0].State.Name)"
    sleep 5
done

INTERNAL_INSTANCE_PRIVATE_IP_ADDRESS="$(echo $INTERNAL_INSTANCE_INFO | jq -r .Reservations[0].Instances[0].PrivateIpAddress)"

echo 
echo "Bastion PUBLIC IP address: $BASTION_INSTANCE_PUBLIC_IP_ADDRESS"
echo "Internal host PRIVATE IP address: $INTERNAL_INSTANCE_PRIVATE_IP_ADDRESS"
echo

echo "Host bastion
  HostName ${BASTION_INSTANCE_PUBLIC_IP_ADDRESS}
  IdentityFile ~/.ssh/aws_ec2_key_pair.pem
  User ubuntu

Host internal
  HostName ${INTERNAL_INSTANCE_PRIVATE_IP_ADDRESS}
  IdentityFile ~/.ssh/aws_ec2_key_pair.pem
  User ubuntu
  ProxyCommand ssh -W %h:%p ubuntu@bastion
  " >> ~/.ssh/config

echo
echo "Execute \"ssh bastion\" to connect to bastion host."
echo "Execute \"ssh internal\" to connect to internal host."
echo