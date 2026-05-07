###############################################################################
# otel-irsa.tf
#
# IAM Roles for Service Accounts (IRSA) for the two OpenTelemetry Collector
# tiers running on the EKS data plane:
#
#   1. otel-collector-agent (DaemonSet) — needs aps:RemoteWrite to push
#      metrics to AMP. No X-Ray permissions: the agent forwards traces to
#      the gateway over OTLP/gRPC inside the cluster.
#
#   2. otel-collector-gateway (Deployment) — needs xray:PutTraceSegments to
#      ship spans to AWS X-Ray. No AMP permissions: it doesn't write metrics.
#
# Splitting the two roles enforces least-privilege so a compromised agent
# cannot publish forged traces and a compromised gateway cannot poison
# Prometheus active series.
#
# This file consumes:
#   - var.eks_cluster_name              : EKS cluster the Collectors run in
#   - var.eks_oidc_provider_arn         : OIDC provider ARN for that cluster
#   - var.eks_oidc_provider_url         : OIDC provider URL ("https://" stripped)
#   - var.otel_namespace                : Kubernetes namespace (default: observability)
#   - var.otel_agent_service_account    : ServiceAccount used by the DaemonSet
#   - var.otel_gateway_service_account  : ServiceAccount used by the gateway
#
# It produces:
#   - aws_iam_role.otel_collector_agent
#   - aws_iam_role.otel_collector_gateway
#   - module outputs `otel_agent_role_arn` / `otel_gateway_role_arn`
#     consumed by the manifests in `otel/`.
###############################################################################

# ---------------------------------------------------------------------------
# Variables specific to this file. We keep them here (rather than in
# variables.tf) so the IRSA wiring is self-contained and the file can be
# lifted into other environments unchanged.
# ---------------------------------------------------------------------------

variable "eks_cluster_name" {
  description = "Name of the EKS cluster the OTel Collectors run in."
  type        = string
  default     = ""
}

variable "eks_oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for the EKS cluster (output of the EKS module)."
  type        = string
  default     = ""
}

variable "eks_oidc_provider_url" {
  description = "OIDC provider URL with the 'https://' prefix stripped (e.g. oidc.eks.ap-south-1.amazonaws.com/id/ABCD...)."
  type        = string
  default     = ""
}

variable "otel_namespace" {
  description = "Kubernetes namespace the Collectors run in."
  type        = string
  default     = "observability"
}

variable "otel_agent_service_account" {
  description = "ServiceAccount used by the agent DaemonSet."
  type        = string
  default     = "otel-collector-agent"
}

variable "otel_gateway_service_account" {
  description = "ServiceAccount used by the gateway Deployment."
  type        = string
  default     = "otel-collector-gateway"
}

# ---------------------------------------------------------------------------
# Local helper expressions. We gate every IAM resource on whether the IRSA
# inputs are populated so this file is a no-op when the operator is using
# the cluster from an upstream module that wires its own roles.
# ---------------------------------------------------------------------------

locals {
  irsa_enabled = (
    var.eks_oidc_provider_arn != "" &&
    var.eks_oidc_provider_url != ""
  )

  oidc_url_stripped = trimprefix(var.eks_oidc_provider_url, "https://")

  agent_subject = "system:serviceaccount:${var.otel_namespace}:${var.otel_agent_service_account}"

  gateway_subject = "system:serviceaccount:${var.otel_namespace}:${var.otel_gateway_service_account}"
}

# ---------------------------------------------------------------------------
# Trust policy generators — one per ServiceAccount. We constrain `sub` to
# the exact ServiceAccount and `aud` to sts.amazonaws.com so the role is
# only assumable by the matching pod identity, not any pod in the cluster.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "otel_agent_assume_role" {
  count = local.irsa_enabled ? 1 : 0

  statement {
    sid     = "AllowAgentSAAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.eks_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url_stripped}:sub"
      values   = [local.agent_subject]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url_stripped}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "otel_gateway_assume_role" {
  count = local.irsa_enabled ? 1 : 0

  statement {
    sid     = "AllowGatewaySAAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.eks_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url_stripped}:sub"
      values   = [local.gateway_subject]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url_stripped}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Agent role + policy attachment.
#
# We intentionally REUSE aws_iam_policy.amp_remote_write defined in amp.tf
# (which already grants `aps:RemoteWrite`, `aps:GetSeries`, `aps:GetLabels`,
# `aps:GetMetricMetadata` scoped to the workspace ARN). Defining a second
# AMP policy would diverge over time.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "otel_collector_agent" {
  count = local.irsa_enabled ? 1 : 0

  name               = "${local.name_prefix}-otel-collector-agent"
  description        = "IRSA role assumed by the OTel Collector agent DaemonSet to remote_write metrics to AMP."
  assume_role_policy = data.aws_iam_policy_document.otel_agent_assume_role[0].json

  tags = merge(local.common_tags, {
    Component = "otel-agent-irsa"
  })
}

resource "aws_iam_role_policy_attachment" "otel_agent_amp" {
  count = local.irsa_enabled ? 1 : 0

  role       = aws_iam_role.otel_collector_agent[0].name
  policy_arn = aws_iam_policy.amp_remote_write.arn
}

# ---------------------------------------------------------------------------
# Gateway role + policy.
#
# X-Ray's documented IAM action set for the AWS-X-Ray-Daemon equivalent is
# the `AWSXRayDaemonWriteAccess` managed policy. We inline the contents
# here so the role attaches a *customer-managed* policy with the exact same
# permissions: this keeps IAM resources discoverable from a single source
# and lets us extend the policy later (e.g. cross-account relay).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "otel_gateway_xray" {
  count = local.irsa_enabled ? 1 : 0

  statement {
    sid    = "AllowXRayWrite"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
      "xray:GetSamplingStatisticSummaries",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowEKSResourceDetection"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "otel_gateway_xray" {
  count = local.irsa_enabled ? 1 : 0

  name        = "${local.name_prefix}-otel-gateway-xray"
  description = "Allow OTel Collector gateway to write segments to AWS X-Ray and read sampling rules."
  policy      = data.aws_iam_policy_document.otel_gateway_xray[0].json

  tags = local.common_tags
}

resource "aws_iam_role" "otel_collector_gateway" {
  count = local.irsa_enabled ? 1 : 0

  name               = "${local.name_prefix}-otel-collector-gateway"
  description        = "IRSA role assumed by the OTel Collector gateway Deployment to push spans to AWS X-Ray."
  assume_role_policy = data.aws_iam_policy_document.otel_gateway_assume_role[0].json

  tags = merge(local.common_tags, {
    Component = "otel-gateway-irsa"
  })
}

resource "aws_iam_role_policy_attachment" "otel_gateway_xray" {
  count = local.irsa_enabled ? 1 : 0

  role       = aws_iam_role.otel_collector_gateway[0].name
  policy_arn = aws_iam_policy.otel_gateway_xray[0].arn
}

# ---------------------------------------------------------------------------
# Outputs — surfaced so the user can plug them into Helm/Kustomize values
# and stamp the eks.amazonaws.com/role-arn annotations on the manifests in
# ../otel/.
# ---------------------------------------------------------------------------

output "otel_agent_role_arn" {
  description = "ARN of the IRSA role for the OTel Collector agent DaemonSet."
  value       = local.irsa_enabled ? aws_iam_role.otel_collector_agent[0].arn : ""
}

output "otel_gateway_role_arn" {
  description = "ARN of the IRSA role for the OTel Collector gateway Deployment."
  value       = local.irsa_enabled ? aws_iam_role.otel_collector_gateway[0].arn : ""
}

output "otel_service_account_annotations" {
  description = "Map of ServiceAccount-name -> {eks.amazonaws.com/role-arn} annotation values, ready to splice into Helm values."
  value = local.irsa_enabled ? {
    (var.otel_agent_service_account)   = { "eks.amazonaws.com/role-arn" = aws_iam_role.otel_collector_agent[0].arn }
    (var.otel_gateway_service_account) = { "eks.amazonaws.com/role-arn" = aws_iam_role.otel_collector_gateway[0].arn }
  } : {}
}
