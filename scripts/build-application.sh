#!/bin/bash
set -e

# build and push application services into ECR

# Check Docker installation and platform support
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        echo "Docker daemon is not running. Please start Docker."
        exit 1
    fi
}

# Download the official certificate for AWS RDS
download_RDS_ssl() {
    local SSL_CERT_PATH="../server/application/microservices/product_mysql/src/SSLCA.pem"
    echo -e "Downloading Amazon Root CA 1 certificate..."

    mkdir -p $(dirname "$SSL_CERT_PATH")

    curl -s -o "$SSL_CERT_PATH" https://www.amazontrust.com/repository/AmazonRootCA1.pem

    if [ $? -eq 0 ]; then
        chmod 644 "$SSL_CERT_PATH"
        echo "Amazon Root CA 1 certificate downloaded successfully to $SSL_CERT_PATH"
    else
        echo "Failed to download Amazon Root CA 1 certificate"
        exit 1
    fi
}

# Prompt user for DB_TYPE selection
select_db_type () {
    echo "Select the database type for 'product' service:"
    echo "1) DynamoDB"
    echo -n "2) MySQL: "
    echo -e "\033[38;5;172m\033[1m\033[4mScheme-per-tenant isolation in MySQL is only available for testing in Advanced Tier\033[0m"

    read -p "Enter the number corresponding to the database type [ default: 1) DynamoDB ]: " db_selection

    case $db_selection in
        2)
            DB_TYPE="mysql"
            download_RDS_ssl
            ;;
        *)
            DB_TYPE="dynamodb"
            ;;
    esac
    
    echo "export DB_TYPE=$DB_TYPE" > /tmp/db_type.env
    echo "Selected DB_TYPE: $DB_TYPE"
}

# Check AWS CLI configuration
check_aws_config() {
    if ! aws sts get-caller-identity &> /dev/null; then
        echo "AWS CLI is not configured properly. Please configure AWS CLI with valid credentials."
        exit 1
    fi
}

export DOCKER_DEFAULT_PLATFORM=linux/amd64

SERVICE_REPOS=("user" "product" "order" "rproxy")

# Run initial checks
check_docker
check_aws_config

REGION=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Login to ECR
echo "Logging into ECR..."
if ! aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin $REGISTRY; then
    echo "Failed to login to ECR. Please check your AWS credentials and permissions."
    exit 1
fi

deploy_service () {
    local SERVICE_NAME="$1"
    local VERSION="$2"

    if [[ -z "$SERVICE_NAME" ]]; then
      echo "Please provide a SERVICE NAME"
      exit 1
    fi

    local SERVICEECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/$SERVICE_NAME"

    # Database handling for 'product' service  
    if [ "$SERVICE_NAME" == "product" ]; then
      echo "➤➤➤ Database App handling for $SERVICE_NAME"

      DB_TYPE=${DB_TYPE:-"dynamodb"}  # default to dynamodb if not set

      if [ "$DB_TYPE" == "mysql" ]; then
        echo "Building $SERVICE_NAME service for MySQL"
        cp -r ./microservices/product_mysql ./microservices/product
      elif [ "$DB_TYPE" == "dynamodb" ]; then
        echo "Building $SERVICE_NAME service for DynamoDB"
        cp -r ./microservices/product_dynamodb ./microservices/product
      else
        echo "Unknown DB_TYPE: $DB_TYPE. Exiting..."
        exit 1
      fi
    fi

    echo "Building Docker image for $SERVICE_NAME..."
    if ! docker build -t $SERVICEECR -f Dockerfile.$SERVICE_NAME .; then
        echo "Failed to build Docker image for $SERVICE_NAME"
        exit 1
    fi

    echo "Tagging Docker image for $SERVICE_NAME..."
    if ! docker tag "$SERVICEECR" "$SERVICEECR:$VERSION"; then
        echo "Failed to tag Docker image for $SERVICE_NAME"
        exit 1
    fi

    echo "Pushing Docker image for $SERVICE_NAME to ECR..."
    if ! docker push "$SERVICEECR:$VERSION"; then
        echo "Failed to push Docker image for $SERVICE_NAME to ECR"
        exit 1
    fi

    echo '************************' 
    echo "AWS_REGION:" $REGION
    echo "$SERVICE_NAME SERVICE_ECR_REPO: $SERVICEECR VERSION: $VERSION"
    rm -rf ./microservices/product || echo "Directory ./microservices/product does not exist."
}

# Call the select_db_type function for DB_TYPE selection
select_db_type

CWD=$(pwd)
cd ../server/application

for SERVICE in "${SERVICE_REPOS[@]}"; do
  echo -e "\033[0;33m==========\033[0;32m Repository [$SERVICE] checking... \033[0;33m==========\033[0m"
  REPO_EXISTS=$(aws ecr describe-repositories --repository-names "$SERVICE" --query 'repositories[0].repositoryUri' --output text 2>/dev/null || echo "")

  if [ "$REPO_EXISTS" == "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/$SERVICE" ]; then
    echo "Repository [$SERVICE] already exists."
  else
    echo "Repository [$SERVICE] does not exist, creating it..."
    if ! aws ecr create-repository --repository-name "$SERVICE"; then
        echo "Failed to create ECR repository for $SERVICE"
        exit 1
    fi
    echo "Repository [$SERVICE] created."
  fi

  VERSION="latest"
  deploy_service $SERVICE $VERSION
done

cd $CWD

# cloud9 SSM plugins to connect to the inside of Container
# sudo dnf install -y https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm