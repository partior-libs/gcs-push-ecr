#!/bin/bash

# Function to authenticate Docker to an AWS ECR registry.
#
# Arguments:
#   $1: The AWS Account ID (e.g., "123456789012").
#   $2: The AWS Region where the ECR registry is located (e.g., "ap-southeast-1").
#
# Returns:
#   0: On successful Docker login to ECR.
#   1: On failure (e.g., AWS CLI not configured, invalid credentials, network issue).
#
function authenticate_ecr_docker_registry() {
  local ecr_account_id="$1"
  local aws_region="$2"

  # Validate inputs
  if [[ -z "$ecr_account_id" || -z "$aws_region" ]]; then
    echo "ERROR: Missing arguments for authenticate_ecr_docker_registry." >&2
    echo "Usage: authenticate_ecr_docker_registry <aws_account_id> <aws_region>" >&2
    return 1
  fi

  local ecr_registry_url="${ecr_account_id}.dkr.ecr.${aws_region}.amazonaws.com"
  echo "[INFO] Attempting Docker login to ECR registry: $ecr_registry_url"

  # Use set -e for this critical command to ensure script exits on failure
  set -e
  # This command retrieves an ECR login password and pipes it to docker login
  aws ecr get-login-password --region "$aws_region" | docker login --username AWS --password-stdin "$ecr_registry_url"
  local login_status=$? # Capture the exit code of the docker login command
  set +e # Revert set -e

  if [[ $login_status -eq 0 ]]; then
    echo "[INFO] Successfully authenticated Docker to ECR registry: $ecr_registry_url"
    return 0
  else
    echo "ERROR: Failed to authenticate Docker to ECR registry: $ecr_registry_url. Exit code: $login_status" >&2
    return 1
  fi
}