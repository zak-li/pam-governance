variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "admin_source_ip" {
  type        = string
  description = "Public IP allowed inbound to SSH/Vault/Splunk"
}
