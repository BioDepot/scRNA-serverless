#!/bin/bash
sudo apt update && sudo apt upgrade -y
sudo apt install python3 python3-pip -y
sudo apt install awscli -y
aws --version

# optimal disk mounting

# Create RAID 0 with 256KB stripe size
sudo mdadm --create --verbose /dev/md0 --level=0 --raid-devices=2 --chunk=256K /dev/nvme1n1 /dev/nvme2n1

# Format with XFS and optimize for RAID 0
sudo mkfs.xfs -f -d su=256k,sw=2 /dev/md0

# Mount RAID 0 optimally
sudo mkdir -p /mnt/nvme
sudo mount -o noatime,nodiratime,logbufs=8,logbsize=256k,allocsize=64m /dev/md0 /mnt/nvme
sudo chown -R ubuntu:ubuntu /mnt/nvme

# Optimize NVMe I/O scheduler
echo "none" | sudo tee /sys/block/nvme1n1/queue/scheduler
echo "none" | sudo tee /sys/block/nvme2n1/queue/scheduler

# Increase read-ahead buffer
sudo blockdev --setra 65536 /dev/md0
