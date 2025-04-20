#!/bin/bash -e

# Ensure AWS Profile is set
if [[ -z "${AWS_PROFILE}" ]]; then
    echo "AWS_PROFILE is not set. Please set it first:"
    echo "export AWS_PROFILE=825765427811"
    exit 1
fi

# Validate AWS credentials
if ! aws sts get-caller-identity &>/dev/null; then
    echo "AWS credentials are not valid. Please run:"
    echo "aws sso login --profile ${AWS_PROFILE}"
    exit 1
fi

export CDK_PARAM_SYSTEM_ADMIN_EMAIL="$1"

if [[ -z "$CDK_PARAM_SYSTEM_ADMIN_EMAIL" ]]; then
  echo "Please provide system admin email"
  exit 1
fi

export REGION=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')  # Region setting
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create S3 Bucket for provision source.
source ./update-provision-source.sh

echo "CDK_PARAM_COMMIT_ID exists: $CDK_PARAM_COMMIT_ID"

# Create ECS service linked role.
ECS_ROLE=$(aws iam list-roles --query 'Roles[?contains(RoleName, `AWSServiceRoleForECS`)].Arn' --output text)
if [ -z "$ECS_ROLE" ]; then
    aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com | cat
else
    echo "ECS Service linked role exists: $ECS_ROLE"
fi
# Create RDS service linked role.
RDS_ROLE=$(aws iam list-roles --query 'Roles[?contains(RoleName, `AWSServiceRoleForRDS`)].Arn' --output text)
if [ -z "$RDS_ROLE" ]; then
    aws iam create-service-linked-role --aws-service-name rds.amazonaws.com | cat
else
    echo "RDS Service linked role exists: $RDS_ROLE"
fi
# Preprovision basic infrastructure
cd ../server

FILE="/tmp/db_type.env"

if [ -f "$FILE" ]; then
    source /tmp/db_type.env
    echo "DB_TYPE: $DB_TYPE"
else
    DB_TYPE="dynamodb"
fi

if [ "$DB_TYPE" == 'mysql' ]; then 
    sed "s/<REGION>/$REGION/g; s/<ACCOUNT_ID>/$ACCOUNT_ID/g" ./service-info_mysql.txt > ./lib/service-info.json
else
    sed "s/<REGION>/$REGION/g; s/<ACCOUNT_ID>/$ACCOUNT_ID/g" ./service-info.txt > ./lib/service-info.json
fi

# npx cdk bootstrap
export CDK_PARAM_ONBOARDING_DETAIL_TYPE='Onboarding'
export CDK_PARAM_PROVISIONING_DETAIL_TYPE=$CDK_PARAM_ONBOARDING_DETAIL_TYPE
export CDK_PARAM_OFFBOARDING_DETAIL_TYPE='Offboarding'
export CDK_PARAM_DEPROVISIONING_DETAIL_TYPE=$CDK_PARAM_OFFBOARDING_DETAIL_TYPE
export CDK_PARAM_TIER='basic'
export CDK_PARAM_STAGE='prod'
export CDK_BASIC_CLUSTER="$CDK_PARAM_STAGE-$CDK_PARAM_TIER"
export CDK_USE_DB=$DB_TYPE

npm install
echo "bootstrapping CDK..."

# Ensure jq is installed
if ! command -v jq &> /dev/null
then
    echo "jq could not be found. Please install jq (e.g., sudo apt-get install jq or brew install jq)"
    exit 1
fi

# Fetch temporary credentials (which are in JSON format) using the current AWS_PROFILE
echo "Fetching temporary credentials for profile: $AWS_PROFILE..."
CREDENTIALS=$(aws configure export-credentials --profile $AWS_PROFILE)

# Parse JSON and export credentials
export AWS_ACCESS_KEY_ID=$(echo "$CREDENTIALS" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDENTIALS" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDENTIALS" | jq -r .SessionToken)

# Optional: Add echo statements here if needed to verify variables are set
echo "AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"
echo "AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY"
echo "AWS_SESSION_TOKEN: $AWS_SESSION_TOKEN"

if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" || -z "$AWS_SESSION_TOKEN" || "$AWS_ACCESS_KEY_ID" == "null" ]]; then
  echo "Failed to retrieve or parse temporary credentials. Ensure you are logged in via SSO (aws sso login --profile $AWS_PROFILE) and jq is installed."
  exit 1
fi

# Bootstrap using explicit account/region/profile, calling cdk directly
cdk bootstrap aws://$ACCOUNT_ID/$REGION --profile $AWS_PROFILE

# Unset credentials after use (optional, good practice)
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

SERVICES=$(aws ecs list-services --cluster $CDK_BASIC_CLUSTER --query 'serviceArns[*]' --output text || true)
for SERVICE in $SERVICES; do
    SERVICE_NAME=$(echo $SERVICE | rev | cut -d '/' -f 1 | rev)
    echo -n "==== Service Connect re-set if any...  "
    aws ecs update-service \
        --cluster $CDK_BASIC_CLUSTER \
        --service $SERVICE_NAME \
        --service-connect-configuration 'enabled=false' \
        --no-cli-pager --query 'service.serviceArn' --output text
done

npx cdk deploy \
    --all \
    --require-approval=never \
    --context account=$ACCOUNT_ID \
    --context region=$REGION

# Get SaaS application url
ADMIN_SITE_URL=$(aws cloudformation describe-stacks --stack-name shared-infra-stack --query "Stacks[0].Outputs[?OutputKey=='adminSiteUrl'].OutputValue" --output text)
APP_SITE_URL=$(aws cloudformation describe-stacks --stack-name shared-infra-stack --query "Stacks[0].Outputs[?OutputKey=='appSiteUrl'].OutputValue" --output text)
echo "Admin site url: $ADMIN_SITE_URL"
echo "Application site url: $APP_SITE_URL"