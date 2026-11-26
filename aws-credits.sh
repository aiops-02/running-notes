#!/usr/bin/env bash
# =============================================================================
#  AWS Free Tier: earn the 5 x $20 "explore AWS" activity credits from the CLI
#  and delete every resource afterwards.
#
#    1. EC2      - launch and terminate an instance
#    2. RDS      - create a free-tier MySQL database (then delete it)
#    3. Lambda   - deploy a small web app behind a public Function URL
#    4. Bedrock  - send a text prompt to an Amazon Nova model
#    5. Budgets  - create a monthly cost budget
#
#  Usage:
#    ./aws-credits.sh            # run all 5 activities, then clean up
#    ./aws-credits.sh cleanup    # delete anything this script left behind
#
#  Optional environment variables:
#    AWS_REGION=us-east-1        region to use (default us-east-1)
#    BUDGET_EMAIL=you@x.com      email alerts at 80% of the budget
#    KEEP_BUDGET=true            keep the budget (budgets are free; default: delete)
#
#  Runs in AWS CloudShell, Linux, macOS, or Git Bash on Windows.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

PREFIX="credits-demo"
WORK=".work"
EC2_NAME="$PREFIX-ec2"
DB_ID="$PREFIX-db"
FN_NAME="$PREFIX-webapp"
ROLE_NAME="$PREFIX-lambda-role"
BUDGET_NAME="$PREFIX-budget"
BUDGET_EMAIL="${BUDGET_EMAIL:-}"
KEEP_BUDGET="${KEEP_BUDGET:-false}"

# Amazon Nova Micro via the cross-region inference profile for this geography.
case "$AWS_REGION" in
  us-*) GEO="us" ;;
  eu-*) GEO="eu" ;;
  ap-*) GEO="apac" ;;
  *)    GEO="us" ;;
esac
BEDROCK_MODEL="${BEDROCK_MODEL:-$GEO.amazon.nova-micro-v1:0}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    [ok] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    [!] %s\033[0m\n' "$*"; }

retry() {   # retry <attempts> <sleep-seconds> <command...>
  local tries=$1 pause=$2 n=1; shift 2
  until "$@"; do
    [ "$n" -ge "$tries" ] && return 1
    n=$((n + 1)); sleep "$pause"
  done
}

# -----------------------------------------------------------------------------
preflight() {
  log "Checking AWS credentials and region ($AWS_REGION)"
  command -v aws >/dev/null || { echo "AWS CLI v2 is not installed."; exit 1; }
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  ok "Account $ACCOUNT_ID, caller $(aws sts get-caller-identity --query Arn --output text)"
  mkdir -p "$WORK"
}

# -----------------------------------------------------------------------------
step_ec2() {
  log "1/5 EC2: launch and terminate an instance"

  if [ "$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
          --query 'length(Vpcs)' --output text)" = "0" ]; then
    warn "No default VPC found, creating one"
    aws ec2 create-default-vpc >/dev/null
  fi

  local ami itype iid
  ami=$(aws ssm get-parameter \
        --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
        --query Parameter.Value --output text)

  itype=$(aws ec2 describe-instance-types \
          --filters Name=free-tier-eligible,Values=true \
                    Name=processor-info.supported-architecture,Values=x86_64 \
          --query 'InstanceTypes[].InstanceType' --output text \
          | tr '\t' '\n' | grep -E '^t3\.micro$|^t2\.micro$' | head -n1 || true)
  itype=${itype:-t3.micro}

  iid=$(aws ec2 run-instances --image-id "$ami" --instance-type "$itype" --count 1 \
        --metadata-options HttpTokens=required \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$EC2_NAME},{Key=Project,Value=$PREFIX}]" \
        --query 'Instances[0].InstanceId' --output text)
  ok "Launched $iid ($itype, $ami)"

  aws ec2 wait instance-running --instance-ids "$iid"
  ok "Instance is running"

  aws ec2 terminate-instances --instance-ids "$iid" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "$iid"
  ok "Instance terminated"
}

# -----------------------------------------------------------------------------
step_rds() {
  log "2/5 RDS: create a free-tier MySQL database (takes 5-15 min)"

  local pass
  pass="Db$(head -c 300 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-22)"

  aws rds create-db-instance \
    --db-instance-identifier "$DB_ID" \
    --engine mysql \
    --db-instance-class db.t3.micro \
    --allocated-storage 20 --storage-type gp2 \
    --master-username admin --master-user-password "$pass" \
    --no-multi-az --no-publicly-accessible \
    --backup-retention-period 0 \
    --tags "Key=Project,Value=$PREFIX" >/dev/null
  ok "Creating $DB_ID (db.t3.micro, 20 GB gp2)"

  aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
  ok "Database is available: $(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
        --query 'DBInstances[0].Endpoint.Address' --output text)"

  aws rds delete-db-instance --db-instance-identifier "$DB_ID" \
    --skip-final-snapshot --delete-automated-backups >/dev/null
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID"
  ok "Database deleted"
}

# -----------------------------------------------------------------------------
make_zip() {   # zips $WORK/lambda_function.py into $WORK/function.zip
  ( cd "$WORK"
    rm -f function.zip
    if command -v zip >/dev/null; then
      zip -q function.zip lambda_function.py
    elif command -v python3 >/dev/null && python3 -c 'import zipfile' 2>/dev/null; then
      python3 -c "import zipfile; zipfile.ZipFile('function.zip','w').write('lambda_function.py')"
    elif command -v python >/dev/null && python -c 'import zipfile' 2>/dev/null; then
      python -c "import zipfile; zipfile.ZipFile('function.zip','w').write('lambda_function.py')"
    else
      powershell.exe -NoProfile -Command "Compress-Archive -Path lambda_function.py -DestinationPath function.zip -Force"
    fi )
}

step_lambda() {
  log "3/5 Lambda: deploy a basic web app with a public Function URL"

  cat > "$WORK/trust.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON

  local role_arn url code
  role_arn=$(aws iam create-role --role-name "$ROLE_NAME" \
             --assume-role-policy-document "file://$WORK/trust.json" \
             --tags "Key=Project,Value=$PREFIX" \
             --query Role.Arn --output text)
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  ok "Execution role $ROLE_NAME created"

  cat > "$WORK/lambda_function.py" <<'PY'
import html
from datetime import datetime, timezone

def lambda_handler(event, context):
    params = event.get("queryStringParameters") or {}
    name = html.escape(params.get("name", "AWS Free Tier"))
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    body = f"""<!doctype html>
<html><head><title>Hello from Lambda</title></head>
<body style="font-family:sans-serif;max-width:40rem;margin:4rem auto">
  <h1>Hello, {name}!</h1>
  <p>This page is served by AWS Lambda at {now}.</p>
  <p>Try adding <code>?name=YourName</code> to the URL.</p>
</body></html>"""
    return {"statusCode": 200, "headers": {"Content-Type": "text/html"}, "body": body}
PY
  make_zip

  # New IAM roles take a few seconds to become assumable by Lambda.
  sleep 10
  retry 10 6 aws lambda create-function \
    --function-name "$FN_NAME" \
    --runtime python3.12 \
    --handler lambda_function.lambda_handler \
    --role "$role_arn" \
    --zip-file "fileb://$WORK/function.zip" \
    --memory-size 128 --timeout 10 \
    --tags "Project=$PREFIX" >/dev/null
  aws lambda wait function-active-v2 --function-name "$FN_NAME"
  ok "Function $FN_NAME is active"

  url=$(aws lambda create-function-url-config --function-name "$FN_NAME" \
        --auth-type NONE --query FunctionUrl --output text)
  aws lambda add-permission --function-name "$FN_NAME" \
    --statement-id public-url --action lambda:InvokeFunctionUrl \
    --principal '*' --function-url-auth-type NONE >/dev/null
  # Newer accounts also require lambda:InvokeFunction for public Function URLs.
  aws lambda add-permission --function-name "$FN_NAME" \
    --statement-id public-url-invoke --action lambda:InvokeFunction \
    --principal '*' --invoked-via-function-url >/dev/null 2>&1 \
    || warn "Could not add lambda:InvokeFunction permission (older CLI?). URL may return 403."
  ok "Function URL: $url"

  code=000
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    code=$(curl -s -o "$WORK/page.html" -w '%{http_code}' "${url}?name=Credits" || echo 000)
    [ "$code" = "200" ] && break
    sleep 5
  done
  if [ "$code" = "200" ]; then
    ok "Web app responded HTTP 200: $(grep -o '<h1>.*</h1>' "$WORK/page.html" || true)"
  else
    warn "Web app returned HTTP $code (the function was still created and deployed)"
  fi

  aws lambda delete-function --function-name "$FN_NAME"
  aws logs delete-log-group --log-group-name "/aws/lambda/$FN_NAME" 2>/dev/null || true
  aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  aws iam delete-role --role-name "$ROLE_NAME"
  ok "Function, log group and role deleted"
}

# -----------------------------------------------------------------------------
step_bedrock() {
  log "4/5 Bedrock: send a text prompt to $BEDROCK_MODEL"

  cat > "$WORK/messages.json" <<'JSON'
[{"role": "user", "content": [{"text": "What is observability? What is the scope, is this AI proof?"}]}]
JSON

  local answer
  if answer=$(aws bedrock-runtime converse --model-id "$BEDROCK_MODEL" \
               --messages "file://$WORK/messages.json" \
               --inference-config maxTokens=200,temperature=0.5 \
               --query 'output.message.content[0].text' --output text); then
    ok "Model replied:"
    printf '      %s\n' "$answer"
  else
    warn "Bedrock call failed. Do this one in the console instead:"
    warn "  Bedrock console > Playgrounds > Chat / Text > pick Amazon Nova Micro > Run"
  fi
  # Nothing to delete: a prompt creates no resources.
}

# -----------------------------------------------------------------------------
step_budget() {
  log "5/5 Budgets: create a monthly cost budget"

  cat > "$WORK/budget.json" <<JSON
{
  "BudgetName": "$BUDGET_NAME",
  "BudgetLimit": { "Amount": "5", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
JSON

  local args=(--account-id "$ACCOUNT_ID" --budget "file://$WORK/budget.json")
  if [ -n "$BUDGET_EMAIL" ]; then
    cat > "$WORK/notify.json" <<JSON
[{
  "Notification": {
    "NotificationType": "ACTUAL",
    "ComparisonOperator": "GREATER_THAN",
    "Threshold": 80,
    "ThresholdType": "PERCENTAGE"
  },
  "Subscribers": [{ "SubscriptionType": "EMAIL", "Address": "$BUDGET_EMAIL" }]
}]
JSON
    args+=(--notifications-with-subscribers "file://$WORK/notify.json")
  fi

  aws budgets create-budget "${args[@]}"
  ok "Budget $BUDGET_NAME created (\$5/month)"

  if [ "$KEEP_BUDGET" = "true" ]; then
    ok "Keeping the budget (KEEP_BUDGET=true; budgets are free)"
  else
    aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME"
    ok "Budget deleted"
  fi
}

# -----------------------------------------------------------------------------
# Idempotent cleanup: safe to run any time, deletes only this script's resources.
cleanup() {
  log "Cleanup: removing anything left behind by this script"
  set +e
  ACCOUNT_ID=${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}

  local ids
  ids=$(aws ec2 describe-instances \
        --filters "Name=tag:Project,Values=$PREFIX" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -n "$ids" ]; then
    aws ec2 terminate-instances --instance-ids $ids >/dev/null
    aws ec2 wait instance-terminated --instance-ids $ids
    ok "Terminated EC2: $ids"
  fi

  local status
  status=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
           --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)
  if [ -n "$status" ] && [ "$status" != "None" ]; then
    if [ "$status" != "deleting" ]; then
      aws rds delete-db-instance --db-instance-identifier "$DB_ID" \
        --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 \
      || { aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
           aws rds delete-db-instance --db-instance-identifier "$DB_ID" \
             --skip-final-snapshot --delete-automated-backups >/dev/null; }
    fi
    aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID"
    ok "Deleted RDS: $DB_ID"
  fi

  if aws lambda get-function --function-name "$FN_NAME" >/dev/null 2>&1; then
    aws lambda delete-function --function-name "$FN_NAME"
    ok "Deleted Lambda: $FN_NAME"
  fi
  aws logs delete-log-group --log-group-name "/aws/lambda/$FN_NAME" >/dev/null 2>&1

  if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    aws iam detach-role-policy --role-name "$ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null
    aws iam delete-role --role-name "$ROLE_NAME"
    ok "Deleted IAM role: $ROLE_NAME"
  fi

  if [ "$KEEP_BUDGET" != "true" ] && aws budgets describe-budget \
       --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" >/dev/null 2>&1; then
    aws budgets delete-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME"
    ok "Deleted budget: $BUDGET_NAME"
  fi

  rm -rf "$WORK"
  ok "Cleanup finished"
  set -e
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "Script failed or was interrupted (exit $rc). Cleaning up so nothing keeps billing."
    cleanup
  fi
}

# -----------------------------------------------------------------------------
main() {
  if [ "${1:-}" = "cleanup" ]; then
    preflight; cleanup; exit 0
  fi

  trap on_exit EXIT
  trap 'exit 130' INT TERM

  preflight
  #step_ec2 # TASK-1
  step_budget # TASK-2
  #step_bedrock
  #step_lambda
  #step_rds           # slowest (~10-20 min including deletion)
  cleanup            # final sweep, should find nothing

  log "All 5 activities done and resources deleted."
  echo "    Check progress: AWS console > Billing and Cost Management > Credits"
  echo "    (or the 'Explore AWS' / Free plan widget on the Console Home page)."
}

main "$@"
