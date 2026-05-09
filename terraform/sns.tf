###############################################################################
# sns.tf
#
# Alert delivery infrastructure for the observability stack:
#
#   - Two SNS topics, one per severity tier:
#       * `alerts_high` -> page on-call (critical alerts, 1h repeat)
#       * `alerts_low`  -> file ticket  (warning alerts, 4h repeat)
#
#   - Email subscriptions for the on-call rotation (managed via a list
#     variable so individual humans can be added/removed without touching
#     Terraform state surgery).
#
#   - Lambda (`slack-notifier`) subscribed to both topics, posting to a
#     Slack webhook stored in Secrets Manager.
#
#   - The AMP alert manager definition that routes alerts based on
#     `severity` label to the right topic.
#
# Why two topics? SNS subscription filter policies could route by attribute
# but the AMP alert manager only sets the SNS subject, not message attributes.
# Two topics is the cleanest way to give critical / warning paths
# independent retry behaviour and IAM policies.
###############################################################################

# -----------------------------------------------------------------------------
# Variables specific to alert delivery. Kept here (rather than in
# variables.tf) so the file is self-contained.
# -----------------------------------------------------------------------------

variable "alert_email_recipients" {
  description = "Email addresses subscribed to high-priority alerts. Each address must confirm via the SNS confirmation email before delivery starts."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.alert_email_recipients : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "Every entry in alert_email_recipients must be a syntactically valid email address."
  }
}

variable "slack_webhook_secret_name" {
  description = "Name of the Secrets Manager secret holding the Slack incoming webhook URL. The secret value should be the bare URL (no JSON wrapper)."
  type        = string
  default     = "obs/slack-alert-webhook"
}

variable "lambda_log_retention_days" {
  description = "Retention (days) for the Slack notifier Lambda's CloudWatch log group."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 180, 365], var.lambda_log_retention_days)
    error_message = "lambda_log_retention_days must be a CloudWatch-supported retention value."
  }
}

# -----------------------------------------------------------------------------
# KMS key used to encrypt SNS payloads at rest. AMP requires that any KMS
# key used by SNS allow service principals from the AMP region to use it
# via `kms:GenerateDataKey*` and `kms:Decrypt`.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "alerts" {
  description             = "Encrypts SNS topics used by the observability alert pipeline."
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags = merge(local.common_tags, {
    Component = "alerts-kms"
  })
}

resource "aws_kms_alias" "alerts" {
  name          = "alias/${local.name_prefix}-alerts"
  target_key_id = aws_kms_key.alerts.key_id
}

data "aws_iam_policy_document" "alerts_kms" {
  statement {
    sid     = "AllowAMPAlertManager"
    effect  = "Allow"
    actions = ["kms:GenerateDataKey*", "kms:Decrypt"]
    principals {
      type        = "Service"
      identifiers = ["aps.amazonaws.com"]
    }
    resources = ["*"]
  }
  statement {
    sid     = "AllowAccountAdmin"
    effect  = "Allow"
    actions = ["kms:*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
    resources = ["*"]
  }
}

resource "aws_kms_key_policy" "alerts" {
  key_id = aws_kms_key.alerts.id
  policy = data.aws_iam_policy_document.alerts_kms.json
}

# -----------------------------------------------------------------------------
# SNS topics — one per severity tier.
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "alerts_high" {
  name              = "${local.name_prefix}-alerts-high"
  display_name      = "Observability Alerts (CRITICAL)"
  kms_master_key_id = aws_kms_key.alerts.id
  tags = merge(local.common_tags, {
    Component = "sns-alerts-high"
    Severity  = "critical"
  })
}

resource "aws_sns_topic" "alerts_low" {
  name              = "${local.name_prefix}-alerts-low"
  display_name      = "Observability Alerts (WARN)"
  kms_master_key_id = aws_kms_key.alerts.id
  tags = merge(local.common_tags, {
    Component = "sns-alerts-low"
    Severity  = "warning"
  })
}

# Allow AMP to publish to both topics. Without an explicit topic policy
# the publish would fail with `AuthorizationError`.
data "aws_iam_policy_document" "sns_topic_policy" {
  for_each = {
    high = aws_sns_topic.alerts_high.arn
    low  = aws_sns_topic.alerts_low.arn
  }

  statement {
    sid     = "AllowAMPPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]
    principals {
      type        = "Service"
      identifiers = ["aps.amazonaws.com"]
    }
    resources = [each.value]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts_high" {
  arn    = aws_sns_topic.alerts_high.arn
  policy = data.aws_iam_policy_document.sns_topic_policy["high"].json
}

resource "aws_sns_topic_policy" "alerts_low" {
  arn    = aws_sns_topic.alerts_low.arn
  policy = data.aws_iam_policy_document.sns_topic_policy["low"].json
}

# -----------------------------------------------------------------------------
# Email subscriptions. SNS sends a confirmation email to each address; the
# subscription stays in `PendingConfirmation` until the recipient clicks
# the link. Terraform tolerates that state.
# -----------------------------------------------------------------------------

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_email_recipients)
  topic_arn = aws_sns_topic.alerts_high.arn
  protocol  = "email"
  endpoint  = each.value
}

# -----------------------------------------------------------------------------
# Slack notifier Lambda. Code lives in `lambda/slack-notifier/` and is
# packaged at apply time using `archive_file`. The Lambda role is
# scoped to: get the webhook secret, write to its own log group,
# and (implicitly) be invoked by SNS.
# -----------------------------------------------------------------------------

data "archive_file" "slack_notifier" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/slack-notifier"
  output_path = "${path.module}/.terraform-build/lambda-slack-notifier.zip"
  excludes    = ["__pycache__", "README.md", "requirements.txt"]
}

resource "aws_cloudwatch_log_group" "slack_notifier" {
  name              = "/aws/lambda/${local.name_prefix}-slack-notifier"
  retention_in_days = var.lambda_log_retention_days
  tags              = local.common_tags
}

data "aws_iam_policy_document" "slack_notifier_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "slack_notifier" {
  name               = "${local.name_prefix}-slack-notifier"
  assume_role_policy = data.aws_iam_policy_document.slack_notifier_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "slack_notifier_inline" {
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.slack_notifier.arn}:*"]
  }
  statement {
    sid     = "ReadWebhookSecret"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:${var.slack_webhook_secret_name}-*",
    ]
  }
}

resource "aws_iam_role_policy" "slack_notifier" {
  name   = "inline"
  role   = aws_iam_role.slack_notifier.id
  policy = data.aws_iam_policy_document.slack_notifier_inline.json
}

resource "aws_lambda_function" "slack_notifier" {
  function_name    = "${local.name_prefix}-slack-notifier"
  role             = aws_iam_role.slack_notifier.arn
  filename         = data.archive_file.slack_notifier.output_path
  source_code_hash = data.archive_file.slack_notifier.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      SLACK_WEBHOOK_SECRET = var.slack_webhook_secret_name
      LOG_LEVEL            = "INFO"
    }
  }

  tags = merge(local.common_tags, {
    Component = "slack-notifier"
  })

  depends_on = [
    aws_cloudwatch_log_group.slack_notifier,
    aws_iam_role_policy.slack_notifier,
  ]
}

# Allow each SNS topic to invoke the Lambda.
resource "aws_lambda_permission" "from_sns_high" {
  statement_id  = "AllowSNSInvokeHigh"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts_high.arn
}

resource "aws_lambda_permission" "from_sns_low" {
  statement_id  = "AllowSNSInvokeLow"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts_low.arn
}

resource "aws_sns_topic_subscription" "lambda_high" {
  topic_arn              = aws_sns_topic.alerts_high.arn
  protocol               = "lambda"
  endpoint               = aws_lambda_function.slack_notifier.arn
  endpoint_auto_confirms = true
  depends_on             = [aws_lambda_permission.from_sns_high]
}

resource "aws_sns_topic_subscription" "lambda_low" {
  topic_arn              = aws_sns_topic.alerts_low.arn
  protocol               = "lambda"
  endpoint               = aws_lambda_function.slack_notifier.arn
  endpoint_auto_confirms = true
  depends_on             = [aws_lambda_permission.from_sns_low]
}

# -----------------------------------------------------------------------------
# AMP alert manager definition. Routes by `severity` label to the
# matching SNS topic. This must live in a single resource per workspace
# — only one alert manager definition is allowed.
# -----------------------------------------------------------------------------

locals {
  alertmanager_config = <<-YAML
    alertmanager_config: |
      route:
        receiver: low_priority
        group_by: [alertname, job]
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 4h
        routes:
          - match:
              severity: critical
            receiver: high_priority
            group_wait: 10s
            repeat_interval: 1h
      receivers:
        - name: high_priority
          sns_configs:
            - topic_arn: ${aws_sns_topic.alerts_high.arn}
              sigv4:
                region: ${var.aws_region}
              subject: "[CRITICAL] {{ .GroupLabels.alertname }}"
        - name: low_priority
          sns_configs:
            - topic_arn: ${aws_sns_topic.alerts_low.arn}
              sigv4:
                region: ${var.aws_region}
              subject: "[WARN] {{ .GroupLabels.alertname }}"
  YAML
}

resource "aws_prometheus_alert_manager_definition" "this" {
  workspace_id = aws_prometheus_workspace.this.id
  definition   = local.alertmanager_config

  depends_on = [
    aws_sns_topic_policy.alerts_high,
    aws_sns_topic_policy.alerts_low,
  ]
}

# -----------------------------------------------------------------------------
# Outputs.
# -----------------------------------------------------------------------------

output "alerts_high_topic_arn" {
  description = "ARN of the SNS topic for critical alerts."
  value       = aws_sns_topic.alerts_high.arn
}

output "alerts_low_topic_arn" {
  description = "ARN of the SNS topic for warning alerts."
  value       = aws_sns_topic.alerts_low.arn
}

output "slack_notifier_function_arn" {
  description = "ARN of the Slack notifier Lambda."
  value       = aws_lambda_function.slack_notifier.arn
}
