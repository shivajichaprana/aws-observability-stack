###############################################################################
# providers.tf
#
# Provider configuration for the aws-observability-stack project. We pin the
# AWS provider tightly because Amazon Managed Prometheus / Managed Grafana
# resources have shifted argument shapes across minor versions, and we want
# the Terraform plan to be reproducible across CI runs and operator machines.
###############################################################################

terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }

    # The Grafana provider is used to manage data sources and dashboards
    # inside the Managed Grafana workspace once it has been provisioned.
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.7"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        Project     = "aws-observability-stack"
        Environment = var.environment
        ManagedBy   = "terraform"
        Owner       = var.owner
      },
      var.extra_tags,
    )
  }
}

# Some Grafana resources require alert/data-source provisioning AFTER the
# Managed Grafana workspace exists. The provider URL and auth token are
# passed in by the bootstrap workflow described in docs/quickstart.md.
provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_api_key
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}
