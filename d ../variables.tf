variable "location" {
  description = "Azure location to deploy resources"
  default     = "Central India"
}

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}
