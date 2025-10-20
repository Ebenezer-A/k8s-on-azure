output "control_plane_public_ip" {
  value = azurerm_public_ip.control_plane_ip.ip_address
}

output "worker_public_ip" {
  value = azurerm_public_ip.worker_ip.ip_address
}

