# slack-notifier Lambda

SNS-triggered Lambda that translates Prometheus alert manager payloads
into Slack messages. Subscribed to both the high-priority and low-priority
alert SNS topics created in `terraform/sns.tf`.

## Configuration

| Variable | Source | Description |
|----------|--------|-------------|
| `SLACK_WEBHOOK_SECRET` | env (Terraform-managed) | Secrets Manager secret name holding the Slack webhook URL |
| `LOG_LEVEL` | env | Optional log level override (default `INFO`) |

The webhook URL itself is stored in AWS Secrets Manager, not Lambda env,
so it does not appear in Lambda configuration exports or CloudTrail.

## Local testing

```
cd lambda/slack-notifier
python3 -c "
import json, handler
event = {'Records':[{'Sns':{'TopicArn':'arn:aws:sns:ap-south-1:123:high','Message': json.dumps({
    'status':'firing','alerts':[{'labels':{'alertname':'SLOAvailabilityFastBurn','severity':'critical','job':'api','slo':'availability'},
    'annotations':{'summary':'demo','description':'desc','runbook_url':'https://runbook'}}]})}}]}
print(handler.lambda_handler(event, None))
"
```

## Build

The CI workflow zips this directory into `lambda-slack-notifier.zip` and
hashes it for `terraform apply`. The Lambda resource in `terraform/sns.tf`
references the zip via `filename` and `source_code_hash`.
