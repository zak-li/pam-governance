variable "resource_group_name" { type = string }
variable "location" { type = string }

variable "authorized_ip_ranges" {
  description = "CIDR ranges allowed to reach the public Kubernetes API server."
  type        = list(string)
}
