#!/bin/bash

FILE=/K8sWorker
if [ -f "$FILE" ]; then
  echo "Script has already been run."

  read -p "Do you want to reset the cluster and run it again? (y/N): " answer
  case "$answer" in
  [yY] | [yY][eE][sS])
    echo "Resetting cluster..."

    sudo kubeadm reset -f

    sudo systemctl restart kubelet

    echo "Running script ..."
    ;;
  *)
    echo "Exiting without changes."
    exit 0
    ;;
  esac
else
  echo "Running script for the first time..."
fi

sudo touch /K8sWorker

sudo apt update && sudo apt upgrade -y

# Install required packages
sudo apt install ca-certificates curl apt-transport-https gpg -y

# Disable swap for current session
sudo swapoff -a

# Disable swap permanently
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab

# Adding Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update && sudo apt-get install containerd.io -y

sudo mkdir -p /etc/containerd

containerd config default | sudo tee /etc/containerd/config.toml

sudo sed -e 's/SystemdCgroup = false/SystemdCgroup = true/g' -i /etc/containerd/config.toml

sudo systemctl restart containerd

sudo systemctl enanle containerd

# Installing crictl
VERSION="v1.34.0"

wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz

sudo tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin

rm -f crictl-$VERSION-linux-amd64.tar.gz

# Set the endpoints to avoid the deprecation error
sudo crictl config --set \
  runtime-endpoint=unix:///run/containerd/containerd.sock \
  --set image-endpoint=unix:///run/containerd/containerd.sock

# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# Load required kernel modules
sudo modprobe overlay
sudo modprobe br_netfilter

# Enable kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/kubernetes.conf
overlay
br_netfilter
EOF

sudo sysctl --system

# Installing kubeadm, kubelet, kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update

sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable --now kubelet

echo '-------------------'
echo 'Node ready to join cluster'
echo '-------------------'
