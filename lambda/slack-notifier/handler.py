"""Slack notifier Lambda for SNS-delivered Prometheus alerts.

Subscribed to the high-priority and low-priority SNS topics created in
`terraform/sns.tf`. SNS delivers JSON published by the AMP alert manager
(or any other SNS publisher) and this handler reformats the payload into
a Slack-friendly Block Kit message and posts it to a webhook.

The webhook URL is read from a Secrets Manager secret rather than a plain
environment variable so the secret never lands in Lambda configuration
exports or CloudTrail. The secret name is supplied via `SLACK_WEBHOOK_SECRET`.

The handler is idempotent: if Slack returns a 5xx the Lambda raises so
SNS retries; on 4xx it logs and swallows the error to avoid retry loops
on permanent failures.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request
from typing import Any

import boto3

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

# Map Prometheus alert severity to a Slack-friendly colour and emoji.
# These are referenced in `_build_attachment` below.
_SEVERITY_STYLE = {
    "critical": {"color": "#d62728", "emoji": ":fire:"},
    "warning":  {"color": "#ff9f1c", "emoji": ":warning:"},
    "info":     {"color": "#1f77b4", "emoji": ":information_source:"},
}


def _get_webhook_url() -> str:
    """Fetch the Slack webhook URL from Secrets Manager.

    Caches the value across invocations within the same execution
    environment by stuffing it into the function's globals on first
    fetch. Cold-start lookups still hit Secrets Manager, but warm
    invocations reuse the cached value.
    """
    cached = globals().get("_WEBHOOK_URL_CACHE")
    if cached:
        return cached

    secret_name = os.environ["SLACK_WEBHOOK_SECRET"]
    client = boto3.client("secretsmanager")
    response = client.get_secret_value(SecretId=secret_name)
    url = response["SecretString"].strip()
    globals()["_WEBHOOK_URL_CACHE"] = url
    return url


def _parse_alert(message: str) -> dict[str, Any]:
    """Parse the SNS Message body. AMP alert manager publishes JSON;
    other publishers may publish plain text. Always return a dict so
    downstream code does not need to branch."""
    try:
        body = json.loads(message)
        if isinstance(body, dict):
            return body
    except (ValueError, TypeError):
        pass
    return {"text": message}


def _build_attachment(alert: dict[str, Any]) -> dict[str, Any]:
    """Build a Slack attachment block for a single alert."""
    labels = alert.get("labels", {}) or {}
    annotations = alert.get("annotations", {}) or {}
    severity = labels.get("severity", "info").lower()
    style = _SEVERITY_STYLE.get(severity, _SEVERITY_STYLE["info"])

    fields = []
    for key in ("job", "slo", "team", "instance"):
        if labels.get(key):
            fields.append({"title": key, "value": labels[key], "short": True})

    text_blocks = []
    if summary := annotations.get("summary"):
        text_blocks.append(f"*{summary}*")
    if description := annotations.get("description"):
        text_blocks.append(description.strip())
    if runbook := annotations.get("runbook_url"):
        text_blocks.append(f"<{runbook}|Open runbook>")

    return {
        "color": style["color"],
        "pretext": f"{style['emoji']} *{labels.get('alertname', 'Unnamed alert')}* "
                   f"({alert.get('status', 'firing')})",
        "fields": fields,
        "text": "\n".join(text_blocks) if text_blocks else "(no details)",
        "ts": alert.get("startsAt"),
    }


def _post_to_slack(payload: dict[str, Any]) -> int:
    """Post `payload` to the Slack webhook. Returns HTTP status."""
    url = _get_webhook_url()
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.getcode()
    except urllib.error.HTTPError as exc:
        # Bubble 5xx so SNS retries; swallow 4xx to avoid retry loops on
        # bad webhooks. Log the response body for debugging.
        body = exc.read().decode("utf-8", errors="replace")
        if 500 <= exc.code < 600:
            LOG.error("slack 5xx (will retry): %s %s", exc.code, body)
            raise
        LOG.error("slack 4xx (won't retry): %s %s", exc.code, body)
        return exc.code


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Lambda entry point. SNS delivers `event['Records']` with one or
    more `Sns` envelopes. Each envelope's `Message` is the alert payload
    we re-shape for Slack."""
    LOG.info("received SNS event with %d records", len(event.get("Records", [])))

    delivered = 0
    for record in event.get("Records", []):
        sns = record.get("Sns", {})
        message = sns.get("Message", "")
        topic_arn = sns.get("TopicArn", "")
        body = _parse_alert(message)

        # AMP alert manager batches firing alerts under "alerts" key, but
        # may also publish flat single alerts. Handle both.
        alerts = body.get("alerts") or [body]
        attachments = [_build_attachment(alert) for alert in alerts]

        payload = {
            "username": "Prometheus",
            "icon_emoji": ":bell:",
            "text": f"*{len(attachments)} alert(s) from* `{topic_arn.rsplit(':', 1)[-1]}`",
            "attachments": attachments,
        }
        status = _post_to_slack(payload)
        if 200 <= status < 300:
            delivered += 1

    return {"statusCode": 200, "delivered": delivered}
