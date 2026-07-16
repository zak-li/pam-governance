variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tenant_id" { type = string }
variable "admin_object_id" { type = string }
variable "subnet_id" { type = string }
variable "admin_source_ip" { type = string }
variable "name_suffix" { type = string }
variable "splunk_password" {
  type      = string
  sensitive = true
}
variable "auth0_client_secret" {
  type      = string
  sensitive = true
}
variable "vault_tls_key" {
  type      = string
  sensitive = true
}
