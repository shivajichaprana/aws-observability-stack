###############################################################################
# main.tf
#
# Top-level locals and shared resources for the aws-observability-stack project.
# Module-specific resources live in dedicated files (amp.tf, amg.tf, etc.) and
# get pulled together by this entry point.
###############################################################################

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name

  # Common name prefix that is short enough to fit AMG's 64-char workspace
  # name limit and CloudWatch log group naming conventions.
  name_prefix = "${var.name_prefix}-${var.environment}"

  # Shared resource tags — also merged into provider default_tags.
  common_tags = merge(
    {
      Project     = "aws-observability-stack"
      Environment = var.environment
      Owner       = var.owner
    },
    var.extra_tags,
  )
}

###############################################################################
# CloudWatch log group used by AMP for ingestion logging. Created here rather
# than inside amp.tf so it stays bounded by the module-wide retention setting.
###############################################################################

resource "aws_cloudwatch_log_group" "amp_logs" {
  name              = "/aws/prometheus/${local.name_prefix}-${var.amp_workspace_alias}"
  retention_in_days = var.amp_log_retention_days
  tags              = local.common_tags
}
