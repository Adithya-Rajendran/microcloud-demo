#!/bin/bash

source config.sh

echo "Starting cleanup process..."

echo "Stopping VMs..."
for vm in micro1 micro2 micro3; do
  if lxc info $vm &> /dev/null; then
    lxc stop $vm
  else
    echo "VM $vm does not exist or is already stopped."
  fi
done

echo "Detaching and deleting local storage volumes..."
for i in {1..3}; do
  if lxc storage volume list $STORAGE_POOL | grep -q "local$i"; then
    lxc storage volume detach $STORAGE_POOL local$i micro$i

    lxc storage volume delete $STORAGE_POOL local$i
  else
    echo "Local storage volume local$i does not exist."
  fi
done

echo "Detaching and deleting remote storage volumes..."
for i in {1..3}; do
  if lxc storage volume list $STORAGE_POOL | grep -q "remote$i"; then
    vm="micro$i"
    lxc storage volume detach $STORAGE_POOL remote$i $vm

    lxc storage volume delete $STORAGE_POOL remote$i
  else
    echo "Remote storage volume remote$i does not exist."
  fi
done

echo "Deleting VMs..."
for vm in micro1 micro2 micro3; do
  if lxc info $vm &> /dev/null; then
    lxc delete $vm
  else
    echo "VM $vm does not exist."
  fi
done

echo "Deleting storage pool '$STORAGE_POOL'..."
if lxc storage list | grep -q "^| $STORAGE_POOL "; then
  lxc storage delete $STORAGE_POOL
else
  echo "Storage pool '$STORAGE_POOL' does not exist."
fi

echo "Deleting network '$NETWORK_NAME'..."
if lxc network list | grep -q "^| $NETWORK_NAME "; then
  lxc network delete $NETWORK_NAME
else
  echo "Network '$NETWORK_NAME' does not exist."
fi

cloud_config_file="my-microcloud-init.yaml"
if [ -f $cloud_config_file ]; then
  rm $cloud_config_file
else
  echo "Cloud-config file $cloud_config_file does not exist."
fi

echo "Cleanup completed successfully."
