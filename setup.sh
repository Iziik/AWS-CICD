#!/bin/bash


#================================
#AUTHOR: Isaac ADEIZA
#DATE: 01/02/2026
#================================

# AWS Infrastructure Setup for CI/CD Pipeline
set -e

# Configuration variables
CLUSTER_NAME="webapp-cicd-cluster"
SERVICE_NAME="webapp-cicd-service"
TASK_FAMILY="webapp-cicd-task"
ECR_REPOSITORY="my-webapp"
AWS_REGION="us-east-1"
GITHUB_USER_NAME="github-actions-user"

echo "=========================================="
echo "🚀 Setting up AWS infrastructure for CI/CD."
echo "=========================================="

# 1. Create ECR Repository
echo "📦 Checking ECR repository..."
if aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $AWS_REGION >/dev/null 2>&1; then
    echo "✅ ECR repository already exists."
else
    aws ecr create-repository --repository-name $ECR_REPOSITORY --region $AWS_REGION --image-scanning-configuration scanOnPush=true
    echo "✅ ECR repository created."
fi

ECR_URI=$(aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $AWS_REGION --query 'repositories[0].repositoryUri' --output text)

# 2. Create an IAM role for ECS task execution
echo "🔐 Checking ECS execution role..."
EXECUTION_ROLE_NAME="ecsTaskExecutionRole-$CLUSTER_NAME"

if aws iam get-role --role-name $EXECUTION_ROLE_NAME >/dev/null 2>&1; then
    echo "✅ ECS execution role already exists."
else
    aws iam create-role --role-name $EXECUTION_ROLE_NAME --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{"Effect": "Allow", "Principal": {"Service": "ecs-tasks.amazonaws.com"}, "Action": "sts:AssumeRole"}]
    }'
    aws iam attach-role-policy --role-name $EXECUTION_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    echo "✅ ECS execution role created. Waiting 10s for IAM propagation..."
    sleep 10 # Critical: IAM roles take a moment to become "usable" by ECS
fi

EXECUTION_ROLE_ARN=$(aws iam get-role --role-name $EXECUTION_ROLE_NAME --query 'Role.Arn' --output text)

# 3. Create ECS cluster
echo "🏗️ Checking ECS cluster..."
# describe-clusters returns 0 even if the cluster is missing/inactive, so we check the 'status.'
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters $CLUSTER_NAME --region $AWS_REGION --query 'clusters[0].status' --output text 2>/dev/null || echo "MISSING")

if [ "$CLUSTER_STATUS" == "ACTIVE" ]; then
    echo "✅ ECS cluster is already ACTIVE"
else
    aws ecs create-cluster --cluster-name $CLUSTER_NAME --region $AWS_REGION
    echo "✅ ECS cluster created."
fi

# 4. Get VPC and subnet information
echo "🌐 Fetching Network Info..."
DEFAULT_VPC=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$DEFAULT_VPC" --query 'Subnets[*].SubnetId' --output text | tr '\t' ',')

# 5. Create a security group
SECURITY_GROUP_NAME="webapp-cicd-sg"
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "NONE")

if [ "$SECURITY_GROUP_ID" != "NONE" ] && [ "$SECURITY_GROUP_ID" != "null" ]; then
    echo "✅ Security group exists: $SECURITY_GROUP_ID"
else
    SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name $SECURITY_GROUP_NAME --description "SG for webapp CI/CD" --vpc-id $DEFAULT_VPC --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 3001 --cidr 0.0.0.0/0
    echo "✅ Security group created: $SECURITY_GROUP_ID"
fi

# 6. Create CloudWatch log group
LOG_GROUP_NAME="/ecs/$TASK_FAMILY"
if aws logs describe-log-groups --log-group-name-prefix $LOG_GROUP_NAME --query 'logGroups[0].logGroupName' --output text | grep -q "$LOG_GROUP_NAME"; then
    echo "✅ CloudWatch log group already exists"
else
    aws logs create-log-group --log-group-name $LOG_GROUP_NAME --region $AWS_REGION
    echo "✅ CloudWatch log group created"
fi

# 7. Register Task Definition
echo "📋 Registering task definition..."
aws ecs register-task-definition \
    --family $TASK_FAMILY \
    --network-mode awsvpc \
    --requires-compatibilities FARGATE \
    --cpu 256 \
    --memory 512 \
    --execution-role-arn $EXECUTION_ROLE_ARN \
    --container-definitions "[{
        \"name\": \"webapp\",
        \"image\": \"nginx:latest\",
        \"portMappings\": [{\"containerPort\": 3001, \"protocol\": \"tcp\"}],
        \"logConfiguration\": {
            \"logDriver\": \"awslogs\",
            \"options\": {
                \"awslogs-group\": \"$LOG_GROUP_NAME\",
                \"awslogs-region\": \"$AWS_REGION\",
                \"awslogs-stream-prefix\": \"ecs\"
            }
        }
    }]" --region $AWS_REGION > /dev/null

# 8. Create an ECS service
echo "🚀 Checking ECS service..."
SERVICE_EXISTS=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION --query 'services[0].status' --output text 2>/dev/null || echo "MISSING")

if [ "$SERVICE_EXISTS" == "ACTIVE" ]; then
    echo "✅ ECS service already exists."
else
    aws ecs create-service \
        --cluster $CLUSTER_NAME \
        --service-name $SERVICE_NAME \
        --task-definition $TASK_FAMILY \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
        --region $AWS_REGION > /dev/null
    echo "✅ ECS service created."
fi

# 9. IAM User for GitHub
echo "👤 Handling GitHub Actions user..."
if ! aws iam get-user --user-name $GITHUB_USER_NAME >/dev/null 2>&1; then
    aws iam create-user --user-name $GITHUB_USER_NAME
    aws iam attach-user-policy --user-name $GITHUB_USER_NAME --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess
    aws iam attach-user-policy --user-name $GITHUB_USER_NAME --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess
fi

echo "✨ Done! Use the values below for your GitHub Secrets."
echo "ECR_REGISTRY: ${ECR_URI%/*}" # Strip the repo name to get just the registry URL
echo "ECR_REPOSITORY: $ECR_REPOSITORY"
echo "ECS_CLUSTER: $CLUSTER_NAME"
echo "ECS_SERVICE: $SERVICE_NAME"


#add AWS/AZURE Security credentials, region, taskfamily to GitHub secrets
