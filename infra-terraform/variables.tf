variable "subscription_id" {
  type        = string
  description = "Target Azure subscription ID"
  # no default = required
}

variable "prefix" {
  type    = string
  default = "learningstepslvl"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "acr_name" {
  type = string
}

variable "db_admin" {
  type    = string
  default = "pgadmin"
}

variable "db_password" {
  type      = string
  sensitive = true          # hidden in plan output / logs
  default = "SuperStr0ngP@$$"
}

variable "kv_name" {
  type = string
}