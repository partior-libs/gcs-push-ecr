#!/bin/bash

# Function to create an ECR repository if it doesn't already exist.
#
# Arguments:
#   $1: The full ECR repository name (e.g., "docker-dev/my-app", "production/service-api").
#       This should NOT include the image tag.
#   $2: The AWS region (e.g., "ap-southeast-1", "us-east-1").
#
# Returns:
#   0: If the repository already existed or was successfully created.
#   1: If there was an error (e.g., invalid name, permission denied, unexpected AWS CLI error).
#
function create_ecr_repo_if_not_exists() {
  local repo_name="$1"
  local aws_region="$2"

  if [[ -z "$repo_name" || -z "$aws_region" ]]; then
    echo "ERROR: Missing arguments for create_ecr_repo_if_not_exists." >&2
    echo "Usage: create_ecr_repo_if_not_exists <repository_name> <aws_region>" >&2
    return 1
  fi

  echo "[INFO] Checking if ECR repository '$repo_name' exists in '$aws_region'..."

  set +e
  local repo_status
  repo_status=$(aws ecr describe-repositories --repository-names "$repo_name" --region "$aws_region" 2>&1)
  local describe_exit_code=$?
  set -e

  if echo "$repo_status" | grep -q "RepositoryNotFoundException"; then
    echo "[INFO] ECR repository '$repo_name' not found. Creating..."
    aws ecr create-repository \
      --repository-name "$repo_name" \
      --region "$aws_region" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability IMMUTABLE \
      --output text
    echo "[INFO] ECR repository '$repo_name' created successfully."
    return 0
  elif [[ "$describe_exit_code" -ne 0 ]]; then
    echo "[ERROR] Failed to describe ECR repository '$repo_name' in '$aws_region'." >&2
    echo "[ERROR] AWS CLI Output: $repo_status" >&2
    return 1
  else
    echo "[INFO] ECR repository '$repo_name' already exists. Skipping creation."
    return 0
  fi
}