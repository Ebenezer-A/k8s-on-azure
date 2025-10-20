terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=4.1.0"
    }
  }
}

# Configure the Microsoft Azure Provider
provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
  tenant_id = var.tenant_id
}

# -------------------------------
# Resource Group Already exists in my account
# If you want terraform to create it change the data to resource
# And remove the data prefix from other resource referance
# -------------------------------
data "azurerm_resource_group" "k8s_rg" {
  name     = "Kubernetes"
}

# -------------------------------
# Virtual Network and Subnet
# -------------------------------
resource "azurerm_virtual_network" "k8s_vnet" {
  name                = "k8s-vnet"
  address_space       = ["172.10.0.0/16"]
  location            = data.azurerm_resource_group.k8s_rg.location
  resource_group_name = data.azurerm_resource_group.k8s_rg.name
}

resource "azurerm_subnet" "k8s_subnet" {
  name                 = "k8s-subnet-1"
  resource_group_name  = data.azurerm_resource_group.k8s_rg.name
  virtual_network_name = azurerm_virtual_network.k8s_vnet.name
  address_prefixes     = ["172.10.0.0/24"]
}

# -------------------------------
# Network Security Group
# -------------------------------
resource "azurerm_network_security_group" "k8s_nsg" {
  name                = "k8s-nsg"
  location            = data.azurerm_resource_group.k8s_rg.location
  resource_group_name = data.azurerm_resource_group.k8s_rg.name

  security_rule {
    name                       = "ssh"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range           = "*"
    destination_port_range      = "22"
    source_address_prefix       = "*"
    destination_address_prefix  = "*"
  }

  security_rule {
    name                       = "k8s-api"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range           = "*"
    destination_port_range      = "6443"
    source_address_prefix       = "*"
    destination_address_prefix  = "*"
  }
}

# -------------------------------
# Network Interfaces
# -------------------------------
resource "azurerm_network_interface" "control_plane_nic" {
  name                = "control-plane-nic"
  location            = data.azurerm_resource_group.k8s_rg.location
  resource_group_name = data.azurerm_resource_group.k8s_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.k8s_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.control_plane_ip.id
  }
}

resource "azurerm_network_interface" "worker_nic" {
  name                = "worker-nic"
  location            = data.azurerm_resource_group.k8s_rg.location
  resource_group_name = data.azurerm_resource_group.k8s_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.k8s_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.worker_ip.id
  }
}

# -------------------------------
# Network Security Group Association
# -------------------------------
resource "azurerm_network_interface_security_group_association" "worker_nsg_association" {
  network_interface_id      = azurerm_network_interface.worker_nic.id
  network_security_group_id = azurerm_network_security_group.k8s_nsg.id
}

resource "azurerm_network_interface_security_group_association" "control_plane_nsg_association" {
  network_interface_id      = azurerm_network_interface.control_plane_nic.id
  network_security_group_id = azurerm_network_security_group.k8s_nsg.id
}


# -------------------------------
# Public IPs
# -------------------------------
resource "azurerm_public_ip" "control_plane_ip" {
  name                = "control-plane-ip"
  location            = data.azurerm_resource_group.k8s_rg.location
  resource_group_name = data.azurerm_resource_group.k8s_rg.name
  allocation_method   = "Static"
}

resource "azurerm_public_ip" "worker_ip" {
  name                = "worker-ip"
  location            = data.azurerm_resource_group.k8s_rg.location
  resource_group_name = data.azurerm_resource_group.k8s_rg.name
  allocation_method   = "Static"
}

# -------------------------------
# SSH Key. Aleardy exists in azure.
# If you want create a new one replace data with resource
# Read terraform docs for further instractions
# -------------------------------
data "azurerm_ssh_public_key" "control_plane_key" {
  name                = "control-panel_key"
  resource_group_name = data.azurerm_resource_group.k8s_rg.name
}

# -------------------------------
# Virtual Machines
# -------------------------------
resource "azurerm_linux_virtual_machine" "control_plane" {
  name                = "control-plane"
  resource_group_name = data.azurerm_resource_group.k8s_rg.name
  location            = data.azurerm_resource_group.k8s_rg.location
  size                = "Standard_B2as_v2"
  admin_username      = "azureuser"
  
  network_interface_ids = [
    azurerm_network_interface.control_plane_nic.id
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = data.azurerm_ssh_public_key.control_plane_key.public_key
  }

  os_disk {
    name              = "control-plane-osdisk"
    caching           = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  tags = {
    role = "control-plane"
  }

  user_data = base64encode(<<EOF
      #!/bin/bash

      cd /home/azureuser

      git clone https://github.com/Ebenezer-A/k8s-on-azure.git
      
      cd k8s-on-azure

      git checkout main

      ./k8scp.sh
  EOF
)
}

resource "azurerm_linux_virtual_machine" "worker" {
  name                = "worker-node"
  resource_group_name = data.azurerm_resource_group.k8s_rg.name
  location            = data.azurerm_resource_group.k8s_rg.location
  size                = "Standard_B2as_v2"
  admin_username      = "azureuser"
  network_interface_ids = [
    azurerm_network_interface.worker_nic.id
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = data.azurerm_ssh_public_key.control_plane_key.public_key
  }

  os_disk {
    name              = "worker-osdisk"
    caching           = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  tags = {
    role = "worker"
  }
  
  user_data = base64encode(<<EOF
      #!/bin/bash

      cd /home/azureuser

      git clone https://github.com/Ebenezer-A/k8s-on-azure.git
      
      cd k8s-on-azure

      git checkout main

      ./k8sworker-node.sh
  EOF
)
}

