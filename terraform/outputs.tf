###############################################################################
# outputs.tf
###############################################################################

output "amp_workspace_id" {
  description = "Workspace ID of the Amazon Managed Prometheus workspace."
  value       = aws_prometheus_workspace.this.id
}

output "amp_workspace_arn" {
  description = "ARN of the AMP workspace, used by IRSA policies and Grafana data sources."
  value       = aws_prometheus_workspace.this.arn
}

output "amp_prometheus_endpoint" {
  description = "PromQL-compatible API endpoint exposed by the AMP workspace."
  value       = aws_prometheus_workspace.this.prometheus_endpoint
}

output "amg_workspace_id" {
  description = "Workspace ID of the Amazon Managed Grafana workspace."
  value       = aws_grafana_workspace.this.id
}

output "amg_workspace_endpoint" {
  description = "Public endpoint of the Managed Grafana workspace."
  value       = aws_grafana_workspace.this.endpoint
}

output "amg_workspace_role_arn" {
  description = "Workspace IAM role ARN granted to AMG for cross-service AWS data sources."
  value       = aws_iam_role.amg_workspace.arn
}

output "amp_log_group_name" {
  description = "Name of the CloudWatch log group used by AMP for ingestion logs."
  value       = aws_cloudwatch_log_group.amp_logs.name
}
