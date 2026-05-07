###############################################################################
# variables.tf
###############################################################################

variable "aws_region" {
  description = "AWS region the observability stack is deployed into."
  type        = string
  default     = "ap-south-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region code (e.g. ap-south-1, us-east-1)."
  }
}

variable "environment" {
  description = "Deployment environment (dev / staging / prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "owner" {
  description = "Team or individual that owns this stack (used in resource tags)."
  type        = string
  default     = "platform-engineering"
}

variable "name_prefix" {
  description = "Common prefix for resource names. Keep short — AMG workspace names have a 64-char limit."
  type        = string
  default     = "obs"

  validation {
    condition     = length(var.name_prefix) >= 2 && length(var.name_prefix) <= 16
    error_message = "name_prefix must be between 2 and 16 characters."
  }
}

variable "extra_tags" {
  description = "Additional tags merged into provider default_tags."
  type        = map(string)
  default     = {}
}

###############################################################################
# AMP / Prometheus
###############################################################################

variable "amp_workspace_alias" {
  description = "Alias for the Amazon Managed Prometheus workspace."
  type        = string
  default     = "obs-primary"
}

variable "amp_alert_manager_definition" {
  description = "YAML alert manager definition applied to the AMP workspace. Empty string skips this resource."
  type        = string
  default     = ""
}

variable "amp_log_retention_days" {
  description = "CloudWatch log retention (days) for AMP workspace logs."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 180, 365], var.amp_log_retention_days)
    error_message = "amp_log_retention_days must match a CloudWatch retention value."
  }
}

###############################################################################
# AMG / Grafana
###############################################################################

variable "amg_admin_role_arns" {
  description = "IAM role ARNs that should be granted ADMIN access to the Managed Grafana workspace."
  type        = list(string)
  default     = []
}

variable "amg_editor_role_arns" {
  description = "IAM role ARNs that should be granted EDITOR access."
  type        = list(string)
  default     = []
}

variable "amg_authentication_providers" {
  description = "Auth providers for AMG. AWS_SSO is the recommended default; SAML is supported via the saml_configuration block."
  type        = list(string)
  default     = ["AWS_SSO"]

  validation {
    condition = alltrue([
      for p in var.amg_authentication_providers : contains(["AWS_SSO", "SAML"], p)
    ])
    error_message = "amg_authentication_providers entries must be one of AWS_SSO, SAML."
  }
}

variable "amg_account_access_type" {
  description = "Whether the workspace can access resources in the current account or across an organization."
  type        = string
  default     = "CURRENT_ACCOUNT"

  validation {
    condition     = contains(["CURRENT_ACCOUNT", "ORGANIZATION"], var.amg_account_access_type)
    error_message = "amg_account_access_type must be CURRENT_ACCOUNT or ORGANIZATION."
  }
}

variable "amg_data_sources" {
  description = "List of AWS data sources to enable on the AMG workspace."
  type        = list(string)
  default     = ["PROMETHEUS", "CLOUDWATCH", "XRAY"]
}

variable "amg_notification_destinations" {
  description = "Notification destinations enabled on the AMG workspace (used for contact points)."
  type        = list(string)
  default     = ["SNS"]
}

###############################################################################
# Grafana provider (post-provisioning data-source / dashboard mgmt)
###############################################################################

variable "grafana_url" {
  description = "Endpoint URL of the Managed Grafana workspace. Filled in after the workspace is created."
  type        = string
  default     = ""
}

variable "grafana_api_key" {
  description = "Grafana service-account API key used by the grafana provider. Pull from AWS Secrets Manager in CI."
  type        = string
  default     = ""
  sensitive   = true
}
