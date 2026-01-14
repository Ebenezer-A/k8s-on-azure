# Kubernetes Cluster on Azure

This repository contains Infrastructure as Code (IaC) and scripts to deploy a production-ready Kubernetes cluster on Azure using Terraform, kubeadm, Cilium CNI, and MetalLB load balancer.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Azure Setup](#azure-setup)
- [Infrastructure Deployment](#infrastructure-deployment)
- [Kubernetes Cluster Setup](#kubernetes-cluster-setup)
- [MetalLB Configuration](#metallb-configuration)
- [Example Application Deployment](#example-application-deployment)
- [Cluster Management](#cluster-management)
- [Troubleshooting](#troubleshooting)
- [Cleanup](#cleanup)

## Overview

This project automates the deployment of a Kubernetes cluster on Azure with the following components:

- **Infrastructure**: Azure VMs, networking, and security groups provisioned via Terraform
- **Kubernetes**: v1.33.5 cluster deployed with kubeadm
- **Container Runtime**: containerd
- **CNI Plugin**: Cilium v1.18.2 for networking
- **Load Balancer**: MetalLB v0.15.2 for LoadBalancer service type support
- **Package Manager**: Helm 3

## Architecture

The cluster consists of:

- **1 Control Plane Node**: Runs Kubernetes control plane components (API server, scheduler, controller manager)
- **1 Worker Node**: Runs application workloads
- **Virtual Network**: 172.10.0.0/16 with subnet 172.10.0.0/24
- **MetalLB IP Pool**: 172.10.0.100-172.10.0.120 for LoadBalancer services
- **Public IPs**: Both control plane and worker nodes have public IPs for external access

## Prerequisites

Before you begin, ensure you have:

### Local Machine Requirements

- **Terraform**: v1.0 or later ([Installation Guide](https://developer.hashicorp.com/terraform/downloads))
- **Azure CLI**: For authentication ([Installation Guide](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli))
- **SSH Client**: For connecting to Azure VMs
- **kubectl**: For managing the Kubernetes cluster (optional, can be installed on control plane)

### Azure Requirements

- An active Azure subscription
- An Azure resource group named **"Kubernetes"** (or modify `terraform/main.tf` to create a new one)
- An SSH public key named **"control-panel_key"** in the resource group (or configure Terraform to create a new one)
- Sufficient quota for:
  - 2x Standard_B2as_v2 VMs (2 vCPUs, 8 GB RAM each)
  - 2x Static public IP addresses
  - 1x Virtual network and subnet

### Azure Permissions

Your Azure account needs:
- Contributor or Owner role on the subscription
- Ability to create/manage resources in the resource group

## Azure Setup

### 1. Authenticate with Azure

```bash
az login
```

### 2. Get Your Azure Credentials

Find your subscription ID and tenant ID:

```bash
# List all subscriptions
az account list --output table

# Get your current subscription details
az account show --query "{subscriptionId:id, tenantId:tenantId}" --output json
```

### 3. Create or Use Existing SSH Key

If you need to create a new SSH key in Azure:

```bash
# Create SSH key pair locally
ssh-keygen -t rsa -b 4096 -f ~/.ssh/k8s_azure_key

# Create SSH key in Azure
az sshkey create \
  --name "control-panel_key" \
  --resource-group "Kubernetes" \
  --public-key @~/.ssh/k8s_azure_key.pub
```

Or verify your existing SSH key:

```bash
az sshkey show --name "control-panel_key" --resource-group "Kubernetes"
```

## Infrastructure Deployment

### 1. Configure Terraform Variables

Create a `terraform/terraform.tfvars` file with your Azure credentials:

```hcl
subscription_id = "your-subscription-id-here"
tenant_id       = "your-tenant-id-here"
```

**Important**: Never commit `terraform.tfvars` to version control as it contains sensitive information.

### 2. Initialize and Deploy Infrastructure

```bash
cd terraform

# Initialize Terraform
terraform init

# Review the execution plan
terraform plan

# Deploy infrastructure
terraform apply
```

Type `yes` when prompted to confirm the deployment.

### 3. Retrieve VM IP Addresses

After deployment, Terraform will output the public IP addresses:

```bash
terraform output
```

Note the IP addresses:
- `control_plane_public_ip`: IP of the control plane node
- `worker_public_ip`: IP of the worker node

## Kubernetes Cluster Setup

### 1. Setup Control Plane Node

SSH into the control plane VM:

```bash
ssh azureuser@<control_plane_public_ip> -i ~/.ssh/k8s_azure_key
```

Copy and run the control plane setup script:

```bash
# Upload the script
scp -i ~/.ssh/k8s_azure_key k8scp.sh azureuser@<control_plane_public_ip>:~/

# SSH to the VM
ssh azureuser@<control_plane_public_ip> -i ~/.ssh/k8s_azure_key

# Make executable and run
chmod +x k8scp.sh
./k8scp.sh
```

The script will:
- Install containerd runtime
- Install Kubernetes components (kubelet, kubeadm, kubectl)
- Initialize the cluster with Cilium CNI
- Generate a join command saved in `~/kubeadm-join.sh`
- Install Helm package manager

**Note**: The script takes approximately 10-15 minutes to complete.

### 2. Setup Worker Node

SSH into the worker VM:

```bash
ssh azureuser@<worker_public_ip> -i ~/.ssh/k8s_azure_key
```

Copy and run the worker setup script:

```bash
# Upload the script
scp -i ~/.ssh/k8s_azure_key k8sworker-node.sh azureuser@<worker_public_ip>:~/

# SSH to the VM
ssh azureuser@<worker_public_ip> -i ~/.ssh/k8s_azure_key

# Make executable and run
chmod +x k8sworker-node.sh
./k8sworker-node.sh
```

### 3. Join Worker to Cluster

On the **control plane node**, retrieve the join command:

```bash
cat ~/kubeadm-join.sh
```

Copy the entire command and run it on the **worker node** with sudo:

```bash
sudo kubeadm join <control-plane-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

### 4. Verify Cluster Status

On the **control plane node**:

```bash
# Check node status
kubectl get nodes

# Check pod status
kubectl get pods -A

# Wait for all Cilium pods to be running
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cilium -n kube-system --timeout=300s
```

## MetalLB Configuration

MetalLB provides LoadBalancer service support in bare metal and VM environments.

### 1. Install MetalLB

From the **control plane node**:

```bash
# Download MetalLB manifests (if not already in the repo)
# Or use the provided metallb-native.yaml
kubectl apply -f metallb-native.yaml
```

### 2. Configure IP Address Pool

Edit `metallb-ip-pool.yaml` to match your network:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - 172.10.0.100-172.10.0.120  # Adjust to your network range
```

Apply the configuration:

```bash
kubectl apply -f metallb-ip-pool.yaml
```

### 3. Configure L2 Advertisement

Apply the L2 advertisement configuration:

```bash
kubectl apply -f metallb-advertisiment.yaml
```

### 4. Verify MetalLB

```bash
# Check MetalLB controller and speaker pods
kubectl get pods -n metallb-system

# Check IP address pool
kubectl get ipaddresspools -n metallb-system

# Check L2 advertisement
kubectl get l2advertisements -n metallb-system
```

## Example Application Deployment

Deploy a sample nginx application with LoadBalancer service:

### 1. Deploy Nginx Pod

```bash
kubectl apply -f nginx-app.yaml
```

### 2. Expose with LoadBalancer Service

```bash
kubectl apply -f nginx-service.yaml
```

### 3. Check Service Status

```bash
# Get service details
kubectl get svc nginx-service

# Wait for EXTERNAL-IP to be assigned
kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' service/nginx-service --timeout=60s
```

### 4. Test the Application

```bash
# Get the external IP
EXTERNAL_IP=$(kubectl get svc nginx-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Access nginx
curl http://$EXTERNAL_IP
```

## Cluster Management

### Reset and Reinstall Control Plane

The `k8scp.sh` script supports cluster reset:

```bash
./k8scp.sh
# Choose 'y' when prompted to reset the cluster
```

### Reset Worker Node

The `k8sworker-node.sh` script also supports reset:

```bash
./k8sworker-node.sh
# Choose 'y' when prompted to reset
```

### Manual Cluster Reset

```bash
# On any node
sudo kubeadm reset -f
sudo systemctl restart kubelet
```

Or use the provided script:

```bash
./destroy-k8s-cluster.sh
```

### Access Cluster from Local Machine

Copy the kubeconfig from control plane to your local machine:

```bash
# On your local machine
scp azureuser@<control_plane_public_ip>:~/.kube/config ~/.kube/k8s-azure-config

# Set KUBECONFIG environment variable
export KUBECONFIG=~/.kube/k8s-azure-config

# Or merge with existing config
kubectl config view --flatten > ~/.kube/config.tmp
mv ~/.kube/config.tmp ~/.kube/config
```

## Troubleshooting

### Common Issues

#### 1. Pods Not Starting

Check pod status and logs:

```bash
kubectl get pods -A
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

#### 2. Node Not Ready

Check node status:

```bash
kubectl get nodes
kubectl describe node <node-name>

# Check kubelet status
sudo systemctl status kubelet
sudo journalctl -u kubelet -f
```

#### 3. Cilium Issues

Check Cilium status:

```bash
cilium status
cilium connectivity test  # Runs connectivity tests
```

#### 4. MetalLB Not Assigning IPs

Check MetalLB components:

```bash
kubectl get pods -n metallb-system
kubectl logs -n metallb-system -l component=controller
kubectl logs -n metallb-system -l component=speaker
```

Verify IP pool configuration:

```bash
kubectl describe ipaddresspool first-pool -n metallb-system
```

#### 5. SSH Connection Issues

Ensure NSG allows SSH (port 22):

```bash
az network nsg rule list --resource-group Kubernetes --nsg-name k8s-nsg --output table
```

#### 6. Containerd Issues

Check containerd status:

```bash
sudo systemctl status containerd
sudo crictl ps  # List running containers
sudo crictl pods  # List pods
```

### Known Issues

1. **Typo in scripts**: Line 62 in both `k8scp.sh` and `k8sworker-node.sh` has `enanle` instead of `enable`:
   ```bash
   sudo systemctl enable containerd  # Correct command
   ```

2. **destroy-k8s-cluster.sh typo**: Line 5 has `restart` instead of `systemctl restart`:
   ```bash
   sudo systemctl restart kubelet  # Correct command
   ```

## Cleanup

### Destroy Kubernetes Cluster Only

On each node:

```bash
sudo kubeadm reset -f
sudo systemctl restart kubelet
```

### Destroy All Azure Infrastructure

**Warning**: This will delete all resources created by Terraform.

```bash
cd terraform
terraform destroy
```

Type `yes` when prompted to confirm.

## Additional Resources

- [Kubernetes Documentation](https://kubernetes.io/docs/home/)
- [Cilium Documentation](https://docs.cilium.io/)
- [MetalLB Documentation](https://metallb.universe.tf/)
- [Terraform Azure Provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)
- [Kubeadm Documentation](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)

## Contributing

Feel free to open issues or submit pull requests for improvements.

## License

This project is provided as-is for educational and demonstration purposes.

