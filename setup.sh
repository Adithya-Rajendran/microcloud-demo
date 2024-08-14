#!/bin/bash

source config.sh

echo "Creating storage and volumes..."


lxc storage list | grep -q "^| $STORAGE_POOL " || {
  lxc storage create $STORAGE_POOL zfs size=100GiB
}

lxc storage set $STORAGE_POOL volume.size 10GiB

# Create local storage volumes
for i in {1..4}; do
  lxc storage volume list $STORAGE_POOL | grep -q "^| local$i " || {
    lxc storage volume create $STORAGE_POOL local$i --type block
  }
done

# Create remote storage volumes with specific sizes
for i in {1..3}; do
  lxc storage volume list $STORAGE_POOL | grep -q "^| remote$i " || {
    lxc storage volume create $STORAGE_POOL remote$i --type block size=20GiB
  }
done

lxc network list | grep -q "^| $NETWORK_NAME " || {
  lxc network create $NETWORK_NAME
}

cloud_init=$(cat <<EOF
#cloud-config
package_update: true
package_upgrade: true
ubuntu_pro:
  enable: 
  - fips-updates
  token: $TOKEN
snap:
  commands:
    0: [refresh, lxd, --channel=5.21/stable, --cohort="+"]
    1: [install, microceph, --channel=quincy/stable, --cohort="+"]
    2: [install, microovn, --channel=22.03/stable, --cohort="+"]
    3: [install, microcloud, --channel=latest/stable, --cohort="+"]
packages:
  - snapd
write_files:
  - path: /var/lib/cloud/scripts/per-boot/config-network.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      echo 0 > /proc/sys/net/ipv6/conf/enp6s0/accept_ra
      ip link set enp6s0 up
      ip addr flush dev enp6s0
power_state:
  delay: now
  mode: reboot
  message: Rebooting machine
final_message: "The system is finally up, after \$UPTIME seconds"
EOF
)

echo "Initializing VMs..."

initialize_vm() {
  vm_name=$1
  local_volume=$2
  remote_volume=$3
  
  lxc init ubuntu:22.04 $vm_name --vm --config limits.cpu=4 --config limits.memory=4GiB --config user.user-data="$cloud_init"

  lxc storage volume attach $STORAGE_POOL $local_volume $vm_name

  if [ -n "$remote_volume" ]; then
    lxc storage volume attach $STORAGE_POOL $remote_volume $vm_name
  fi

  lxc config device add $vm_name eth1 nic network=$NETWORK_NAME name=eth1

  lxc start $vm_name

  echo "Waiting for $vm_name to fully start..."
  while [ "$(lxc list $vm_name -c s --format csv)" != "RUNNING" ]; do
    sleep 2
  done

  echo "Waiting for LXD agent on $vm_name to start..."
  while ! lxc exec $vm_name -- ls / > /dev/null 2>&1; do
    sleep 2
  done

  echo "Waiting for Cloud-init completion on $vm_name..."
  lxc exec $vm_name -- cloud-init status --wait
}

initialize_vm "micro1" "local1" "remote1" &
initialize_vm "micro2" "local2" "remote2" &
initialize_vm "micro3" "local3" "remote3" &
#initialize_vm "micro4" "local4" &

wait


micro1_ip=""
while [ -z "$micro1_ip" ]; do
  micro1_ip=$(lxc list micro1 -c 4 | grep enp5s0 | awk '{print $2}')
  sleep 2
done

microbr0_ipv4=$(lxc network get microbr0 ipv4.address)
if [ -z "$microbr0_ipv4" ]; then
  echo "Error: Failed to retrieve IPv4 address for microbr0. Exiting."
  exit 1
fi

network_base=$(echo $microbr0_ipv4 | cut -d'/' -f1 | cut -d'.' -f1-3)

range_start="${network_base}.10"
range_end="${network_base}.254"

microbr0_ipv6=$(lxc network get microbr0 ipv6.address)
if [ -z "$microbr0_ipv6" ]; then
  echo "Error: Failed to retrieve IPv6 address for microbr0. Exiting."
  exit 1
fi

cat <<EOF > my-microcloud-init.yaml
lookup_subnet: $micro1_ip/24

systems:
- name: micro1
  ovn_uplink_interface: enp6s0
  storage:
    local:
      path: /dev/sdb
      wipe: true
    ceph:
    - path: /dev/sdc
      wipe: true
- name: micro2
  ovn_uplink_interface: enp6s0
  storage:
    local:
      path: /dev/sdb
      wipe: true
    ceph:
    - path: /dev/sdc
      wipe: true
- name: micro3
  ovn_uplink_interface: enp6s0
  storage:
    local:
      path: /dev/sdb
      wipe: true
    ceph:
    - path: /dev/sdc
      wipe: true

ovn:
  ipv4_gateway: $microbr0_ipv4
  ipv4_range: $range_start-$range_end
  ipv6_gateway: $microbr0_ipv6
EOF

echo "my-microcloud-init.yaml file created successfully."

echo "Initializing Microcloud"
lxc file push my-microcloud-init.yaml micro1/root/my-microcloud-init.yaml
lxc exec micro1 -- bash -c "cat /root/my-microcloud-init.yaml | microcloud init --preseed"

lxc file push certs/lxd-ui.crt micro1/root/lxd-ui.crt
lxc exec micro1 -- bash -c "lxc config trust add /root/lxd-ui.crt"

# Can run to auto populate some images
# lxc exec micro1 -- bash -c "lxc image copy ubuntu:jammy --vm local: --alias ubuntu-jammy"
# lxc exec micro1 -- bash -c "lxc image copy ubuntu:noble --vm local: --alias ubuntu-noble"
