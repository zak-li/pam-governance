variable "public_ip_address" { type = string }
variable "app_url" { type = string }
variable "google_client_id" {
  type    = string
  default = ""
}
variable "google_client_secret" {
  type      = string
  default   = ""
  sensitive = true
}
