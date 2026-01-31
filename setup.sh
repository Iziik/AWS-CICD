#!/bin/bash
# AWS Infrastructure Setup for CI/CD Pipeline

set -e  # Exit on any error

# Configuration variables
CLUSTER_NAME="webapp-cicd-cluster"
SERVICE_NAME="webapp-cicd-service"
TASK_FAMILY="webapp-cicd-task"
ECR_REPOSITORY="my-webapp"
AWS_REGION="us-east-1"
GITHUB_USER_NAME="github-actions-user"

echo "=========================================="
echo "Setting up AWS infrastructure for CI/CD"
echo "=========================================="
echo "Cluster: $CLUSTER_NAME"
echo "Service: $SERVICE_NAME"
echo "ECR Repository: $ECR_REPOSITORY"
echo "Region: $AWS_REGION"
echo ""

# Check if AWS CLI is configured
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "❌ AWS CLI not configured. Please run 'aws configure' first."
    exit 1
fi

echo "✅ AWS CLI configured"

# 1. Create ECR Repository
echo "📦 Creating ECR repository..."
if aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $AWS_REGION >/dev/null 2>&1; then
    echo "✅ ECR repository already exists"
else
    aws ecr create-repository \
        --repository-name $ECR_REPOSITORY \
        --region $AWS_REGION \
        --image-scanning-configuration scanOnPush=true
    echo "✅ ECR repository created"
fi

# Get ECR repository URI
ECR_URI=$(aws ecr describe-repositories \
    --repository-names $ECR_REPOSITORY \
    --region $AWS_REGION \
    --query 'repositories[0].repositoryUri' \
    --output text)

echo "✅ ECR URI: $ECR_URI"

# 2. Create IAM role for ECS task execution
echo "🔐 Creating ECS execution role..."
EXECUTION_ROLE_NAME="ecsTaskExecutionRole-$CLUSTER_NAME"

if aws iam get-role --role-name $EXECUTION_ROLE_NAME >/dev/null 2>&1; then
    echo "✅ ECS execution role already exists"
else
    aws iam create-role \
        --role-name $EXECUTION_ROLE_NAME \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {
                        "Service": "ecs-tasks.amazonaws.com"
                    },
                    "Action": "sts:AssumeRole"
                }
            ]
        }'

    aws iam attach-role-policy \
        --role-name $EXECUTION_ROLE_NAME \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    
    echo "✅ ECS execution role created"
fi

# Get execution role ARN
EXECUTION_ROLE_ARN=$(aws iam get-role \
    --role-name $EXECUTION_ROLE_NAME \
    --query 'Role.Arn' \
    --output text)

# 3. Create ECS cluster
echo "🏗️ Creating ECS cluster..."
if aws ecs describe-clusters --clusters $CLUSTER_NAME --region $AWS_REGION ; then
    echo "✅ ECS cluster already exists"
else
    aws ecs create-cluster \
        --cluster-name $CLUSTER_NAME \
        --region $AWS_REGION
    echo "✅ ECS cluster created"
fi

# 4. Get VPC and subnet information
echo "🌐 Getting VPC information..."
DEFAULT_VPC=$(aws ec2 describe-vpcs \
    --filters "Name=is-default,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --output text)

SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$DEFAULT_VPC" \
    --query 'Subnets[*].SubnetId' \
    --output text | tr '\t' ',')

echo "✅ VPC: $DEFAULT_VPC"
echo "✅ Subnets: $SUBNETS"

# 5. Create security group
echo "🛡️ Creating security group..."
SECURITY_GROUP_NAME="webapp-cicd-sg"

if aws ec2 describe-security-groups --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" --query 'SecurityGroups[0].GroupId' --output text >/dev/null 2>&1; then
    SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" \
        --query 'SecurityGroups[0].GroupId' \
        --output text)
    echo "✅ Security group already exists: $SECURITY_GROUP_ID"
else
    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --group-name $SECURITY_GROUP_NAME \
        --description "Security group for webapp CI/CD" \
        --vpc-id $DEFAULT_VPC \
        --query 'GroupId' \
        --output text)

    # Add inbound rule for port 3001
    aws ec2 authorize-security-group-ingress \
        --group-id $SECURITY_GROUP_ID \
        --protocol tcp \
        --port 3001 \
        --cidr 0.0.0.0/0

    echo "✅ Security group created: $SECURITY_GROUP_ID"
fi

# 6. Create CloudWatch log group
echo "📊 Creating CloudWatch log group..."
LOG_GROUP_NAME="/ecs/$TASK_FAMILY"

if aws logs describe-log-groups --log-group-name-prefix $LOG_GROUP_NAME --query 'logGroups[0].logGroupName' --output text >/dev/null 2>&1; then
    echo "✅ CloudWatch log group already exists"
else
    aws logs create-log-group \
        --log-group-name $LOG_GROUP_NAME \
        --region $AWS_REGION
    echo "✅ CloudWatch log group created"
fi

# 7. Create initial task definition with placeholder image
echo "📋 Creating initial task definition..."
aws ecs register-task-definition \
    --family $TASK_FAMILY \
    --network-mode awsvpc \
    --requires-compatibilities FARGATE \
    --cpu 256 \
    --memory 512 \
    --execution-role-arn $EXECUTION_ROLE_ARN \
    --container-definitions '[
        {
            "name": "webapp",
            "image": "nginx:latest",
            "portMappings": [
                {
                    "containerPort": 3001,
                    "protocol": "tcp"
                }
            ],
            "environment": [
                {
                    "name": "ENVIRONMENT",
                    "value": "production"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "'$LOG_GROUP_NAME'",
                    "awslogs-region": "'$AWS_REGION'",
                    "awslogs-stream-prefix": "ecs"
                }
            }
        }
    ]' \
    --region $AWS_REGION >/dev/null

echo "✅ Initial task definition created"

# 8. Create ECS service
echo "🚀 Creating ECS service..."
if aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION >/dev/null 2>&1; then
    echo "✅ ECS service already exists"
else
    aws ecs create-service \
        --cluster $CLUSTER_NAME \
        --service-name $SERVICE_NAME \
        --task-definition $TASK_FAMILY \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
        --region $AWS_REGION >/dev/null
    echo "✅ ECS service created"
fi

# 9. Create IAM user for GitHub Actions
echo "👤 Creating GitHub Actions IAM user..."
if aws iam get-user --user-name $GITHUB_USER_NAME >/dev/null 2>&1; then
    echo "✅ GitHub Actions user already exists"
    echo "ℹ️ You may need to create new access keys"
else
    aws iam create-user --user-name $GITHUB_USER_NAME
    
    # Attach policies for GitHub Actions
    aws iam attach-user-policy \
        --user-name $GITHUB_USER_NAME \
        --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess
    
    aws iam attach-user-policy \
        --user-name $GITHUB_USER_NAME \
        --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess
    
    echo "✅ GitHub Actions user created with ECS and ECR permissions"
fi

# Create access keys for GitHub Actions
echo "🔑 Creating access keys for GitHub Actions..."
ACCESS_KEY_OUTPUT=$(aws iam create-access-key --user-name $GITHUB_USER_NAME 2>/dev/null || echo "failed")

if [ "$ACCESS_KEY_OUTPUT" = "failed" ]; then
    echo "⚠️ Could not create new access keys (user may already have 2 keys)"
    echo "ℹ️ You may need to delete old keys first or use existing ones"
    AWS_ACCESS_KEY_ID="[Use existing or create new access key]"
    AWS_SECRET_ACCESS_KEY="[Use existing or create new secret key]"
else
    AWS_ACCESS_KEY_ID=$(echo $ACCESS_KEY_OUTPUT | jq -r '.AccessKey.AccessKeyId')
    AWS_SECRET_ACCESS_KEY=$(echo $ACCESS_KEY_OUTPUT | jq -r '.AccessKey.SecretAccessKey')
fi

echo ""
echo "=========================================="
echo "🎉 SETUP COMPLETE!"
echo "=========================================="
echo ""
echo "📋 GitHub Repository Secrets to Add:"
echo ""
echo "AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"
echo "AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY"
echo "AWS_REGION: $AWS_REGION"
echo "ECR_REPOSITORY: $ECR_REPOSITORY"
echo "ECR_REGISTRY: $ECR_URI"
echo "ECS_CLUSTER: $CLUSTER_NAME"
echo "ECS_SERVICE: $SERVICE_NAME"
echo "ECS_TASK_DEFINITION: $TASK_FAMILY"
echo ""
echo "🔧 Next Steps:"
echo "1. Add the above secrets to your GitHub repository"
echo "2. Push your code to trigger the first deployment"
echo "3. Watch the GitHub Actions workflow"
echo "4. Get your app URL from the workflow output"
echo ""
echo "🧹 To clean up later:"
echo "./cleanup-aws.sh"
echo ""
echo "=========================================="
