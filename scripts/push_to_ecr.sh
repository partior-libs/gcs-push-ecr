#!/bin/bash

# Source the ECR utility functions (adjust path as needed)
# It's assumed that ecr_utils.sh contains the create_ecr_repo_if_not_exists function.
source "$(dirname "${BASH_SOURCE[0]}")/ecr_utils.sh" || { echo "ERROR: Could not source ecr_utils.sh" >&2; exit 1; }

# Function to process a single Docker image: pull, check/create ECR repo, tag, push.
#
# Arguments:
#   $1: full_artifact_path (e.g., "my.artifactory.com/docker-dev/litmuschaos/litmusportal-subscriber:3.15.0")
#   $2: ecr_account_id (e.g., "123456789012")
#   $3: ecr_base_repo_name (e.g., "docker-dev" or "docker-release")
#   $4: aws_region (e.g., "ap-southeast-1")
#   $5: reference_list_prefix (optional prefix for logging to lists, e.g., "my_workflow_")
#       This is for the temporary files like failed.list, pushed.list, existed.list.
#       If not provided, defaults to empty, using just "failed.list" etc.
#
# Returns:
#   0: On successful pull, check, and push (or if skipped due to duplicate/scope).
#   1: On any critical failure during the process (e.g., pull failure, repo creation failure, push failure).
#
function process_docker_image() {
  local eachArtifact="$1"
  local ecr_account_id="$2"
  local ecr_base_repo_name="$3"
  local aws_region="$4"
  local list_prefix="${5:-}" # Use optional 5th argument, default to empty

  local failedList="${list_prefix}failed.list"
  local pushedList="${list_prefix}pushed.list"
  local existedList="${list_prefix}existed.list"

  echo "--------------------------------------------------------------------"
  echo "[INFO] Preparing to process image from [$eachArtifact]..."

  # Strip the Artifactory registry and docker-(release|dev)/ prefix
  local trimmedArtifactName
  trimmedArtifactName=$(echo "$eachArtifact" | awk -F"docker-(release|dev)/" '{print $2}')
  if [[ -z "$trimmedArtifactName" ]]; then
    echo "[ERROR] Could not trim artifact name from [$eachArtifact]. Skipping." >&2
    echo "[FAILED_TRIM] ${eachArtifact}" >> "$failedList"
    return 1 # Consider this a failure for the artifact
  fi


  # Scope check
  if [[ "$ecr_base_repo_name" == "docker-release" ]] && [[ "$eachArtifact" == *"/docker-release/"* ]]; then
    echo "[INFO] Proceeding to push to docker-release scope..."
  elif [[ "$ecr_base_repo_name" == "docker-dev" ]] && [[ "$eachArtifact" == *"/docker-dev/"* ]]; then
    echo "[INFO] Proceeding to push to docker-dev scope..."
  else
    echo "[INFO] Skipping [$eachArtifact] as it does not match the target repo scope [$ecr_base_repo_name]..."
    echo "[SKIP-SCOPE] ${eachArtifact}" >> "$existedList"
    return 0 # Not a failure, just skipped
  fi

  # 1. Docker Pull
  echo "docker pull \"$eachArtifact\" --platform linux/amd64"
  if ! docker pull "$eachArtifact" --platform linux/amd64; then
    echo "[WARNING] Failed to pull image [$eachArtifact]..." >&2
    echo "[FAILED_PULL] ${eachArtifact}" >> "$failedList"
    return 1 # Failure to pull
  fi

  # Construct target ECR URL
  local targetEcrUrl="${ecr_account_id}.dkr.ecr.${aws_region}.amazonaws.com/${ecr_base_repo_name}/${trimmedArtifactName}"

  # 2. Validate Duplicate Image (using docker manifest inspect)
  local pushToEcr=false
  echo "[INFO] Check if image already existed in ECR: ${targetEcrUrl}..."
  echo "docker manifest inspect \"${targetEcrUrl}\""
  if docker manifest inspect "${targetEcrUrl}" &>/dev/null; then # &>/dev/null suppresses output
    if [[ "${trimmedArtifactName}" == "docker:dind" ]]; then
      echo "[WARNING] Docker DIND image already existed in repo. Attempting to refresh with latest version..."
      pushToEcr=true
    else
      echo "[WARNING] Duplicate found. An existing docker image already existed in repo [$targetEcrUrl]"
      echo "[SKIP-EXISTED] ${targetEcrUrl}" >> "$existedList"
      pushToEcr=false # Do not push if duplicate and not DIND
    fi
  else
    echo "[INFO] No duplicate docker image found. Proceeding..."
    pushToEcr=true
  fi

  if [[ "$pushToEcr" == "true" ]]; then
    # 3. Check/Create ECR Repository
    local fullEcrPath="${ecr_base_repo_name}/${trimmedArtifactName}"
    local actualEcrRepo="${fullEcrPath%:*}" # Remove tag for repository name

    # Call the library function to create the ECR repository
    if ! create_ecr_repo_if_not_exists "$actualEcrRepo" "$aws_region"; then
      echo "[ERROR] Failed to ensure ECR repository '$actualEcrRepo' exists. Skipping push." >&2
      echo "[FAILED_REPO_CREATE] ${eachArtifact}" >> "$failedList"
      return 1 # Failure in repository creation
    fi

    # 4. Docker Tag
    echo "docker image tag \"$eachArtifact\" \"$targetEcrUrl\""
    if ! docker image tag "$eachArtifact" "$targetEcrUrl"; then
      echo "[ERROR] Failed to tag image [$eachArtifact] to [$targetEcrUrl]." >&2
      echo "[FAILED_TAG] ${eachArtifact}" >> "$failedList"
      return 1 # Failure to tag
    fi

    # 5. Docker Push
    echo "docker push \"$targetEcrUrl\""
    if ! docker push "$targetEcrUrl"; then
      echo "[WARNING] Failed to push image [$targetEcrUrl]..." >&2
      echo "[FAILED_PUSH] ${targetEcrUrl}" >> "$failedList"
      return 1 # Failure to push
    fi
    echo "[INFO] Successfully pushed [$targetEcrUrl]"
    echo "[PUSHED] ${targetEcrUrl}" >> "$pushedList"

    # 6. Docker Image Inspect (Verification)
    echo "[INFO] Inspecting docker image for verification: ${targetEcrUrl}..."
    echo "docker image inspect \"${targetEcrUrl}\""
    if ! docker image inspect "${targetEcrUrl}" &>/dev/null; then
      echo "[ERROR] Verification failed: ${targetEcrUrl}. Image not found after push." >&2
      echo "[FAILED_VERIFICATION] ${targetEcrUrl}" >> "$failedList"
      return 1 # Failure in verification
    fi
    echo "[INFO] Verification successful: ${targetEcrUrl}"

  else
    echo "[INFO] Skipping push for [$eachArtifact] due to duplicate check or scope mismatch."
  fi

  echo "--------------------------------------------------------------------"
  return 0 # Success for this artifact
}