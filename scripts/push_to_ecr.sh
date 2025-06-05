#!/bin/bash

# Source the ECR utility functions (adjust path as needed)
# It's assumed that setup_ecr_repo.sh contains the create_ecr_repo_if_not_exists function.
source "$(dirname "${BASH_SOURCE[0]}")/setup_ecr_repo.sh" || { echo "ERROR: Could not source setup_ecr_repo.sh" >&2; exit 1; }

# Function to process a single Docker image: pull, check/create ECR repo, tag, push.
#
# Arguments:
#   $1: full_artifact_path (e.g., "my.artifactory.com/docker-dev/litmuschaos/litmusportal-subscriber:3.15.0")
#   $2: ecr_account_id (e.g., "123456789012")
#   $3: ecr_base_repo_name (e.g., "docker-dev" or "docker-release")
#   $4: aws_region (e.g., "ap-southeast-1")
#   $5: disable_pull_flag ("true" or "false")
#   $6: reference_list_base_path (e.g., "/tmp/") - path where output lists will be written
#
# Returns:
#   0: On successful pull, check, and push (or if skipped due to duplicate/scope).
#   1: On any critical failure during the process (e.g., pull failure, repo creation failure, push failure).
#
function process_docker_image() {
  local full_artifact_path="$1"
  local ecr_account_id="$2"
  local ecr_base_repo_name="$3"
  local aws_region="$4"
  local disable_pull_flag="$5" # New argument
  local list_base_path="$6"    # Shifted argument

  # Define full paths for the output lists
  local failedList="${list_base_path}partior-push-failed.list"
  local pushedList="${list_base_path}partior-push-pushed.list"
  local existedList="${list_base_path}partior-push-existed.list"

  echo "--------------------------------------------------------------------"
  echo "[INFO] Preparing to process image from [$full_artifact_path]..."

  # Strip the Artifactory registry and docker-(release|dev)/ prefix
  local trimmedArtifactName
  trimmedArtifactName=$(echo "$full_artifact_path" | awk -F"docker-(release|dev)/" '{print $2}')
  if [[ -z "$trimmedArtifactName" ]]; then
    echo "[ERROR] Could not trim artifact name from [$full_artifact_path]. Skipping." >&2
    echo "[FAILED_TRIM] ${full_artifact_path}" >> "$failedList"
    return 1
  fi
  echo "[DEBUG] Trimmed Artifact Name: $trimmedArtifactName"

  # Scope check
  if [[ "$ecr_base_repo_name" == "docker-release" ]] && [[ "$full_artifact_path" == *"/docker-release/"* ]]; then
    echo "[INFO] Image [$full_artifact_path] matches target 'docker-release' scope."
  elif [[ "$ecr_base_repo_name" == "docker-dev" ]] && [[ "$full_artifact_path" == *"/docker-dev/"* ]]; then
    echo "[INFO] Image [$full_artifact_path] matches target 'docker-dev' scope."
  else
    echo "[INFO] Skipping [$full_artifact_path] as it does not match the target repo scope [$ecr_base_repo_name]."
    echo "[SKIP-SCOPE] ${full_artifact_path}" >> "$existedList"
    return 0 # Not a failure, just skipped
  fi

  # 1. Docker Pull
  if [[ "$disable_pull_flag" == "true" ]]; then
    echo "[INFO] Docker pull explicitly disabled for [$full_artifact_path]."
  else
    echo "docker pull \"$full_artifact_path\" --platform linux/amd64"
    if ! docker pull "$full_artifact_path" --platform linux/amd64; then
      echo "[WARNING] Failed to pull image [$full_artifact_path]..." >&2
      echo "[FAILED_PULL] ${full_artifact_path}" >> "$failedList"
      return 1 # Failure to pull
    fi
  fi

  # Construct target ECR URL
  local targetEcrUrl="${ecr_account_id}.dkr.ecr.${aws_region}.amazonaws.com/${ecr_base_repo_name}/${trimmedArtifactName}"

  # 2. Validate Duplicate Image (using docker manifest inspect)
  local pushToEcr=false
  echo "[INFO] Checking if image already exists in ECR: ${targetEcrUrl}..."
  echo "docker manifest inspect \"${targetEcrUrl}\""
  if docker manifest inspect "${targetEcrUrl}" &>/dev/null; then
    if [[ "${trimmedArtifactName}" == "docker:dind" ]]; then
      echo "[WARNING] Docker DIND image already existed in repo. Attempting to refresh with latest version..."
      pushToEcr=true
    else
      echo "[WARNING] Duplicate found. An existing docker image already existed in repo [$targetEcrUrl]. Skipping push."
      echo "[SKIP-EXISTED] ${targetEcrUrl}" >> "$existedList"
      pushToEcr=false
    fi
  else
    echo "[INFO] No duplicate docker image found. Proceeding with push."
    pushToEcr=true
  fi

  if [[ "$pushToEcr" == "true" ]]; then
    # 3. Check/Create ECR Repository
    local fullEcrRepoPathWithTag="${ecr_base_repo_name}/${trimmedArtifactName}"
    local actualEcrRepoNameOnly="${fullEcrRepoPathWithTag%:*}" # Remove tag for repository name

    # Call the library function to create the ECR repository
    if ! create_ecr_repo_if_not_exists "$actualEcrRepoNameOnly" "$aws_region"; then
      echo "[ERROR] Failed to ensure ECR repository '$actualEcrRepoNameOnly' exists. Skipping push for this image." >&2
      echo "[FAILED_REPO_CREATE] ${full_artifact_path}" >> "$failedList"
      return 1 # Failure in repository creation
    fi

    # 4. Docker Tag
    echo "docker image tag \"$full_artifact_path\" \"$targetEcrUrl\""
    if ! docker image tag "$full_artifact_path" "$targetEcrUrl"; then
      echo "[ERROR] Failed to tag image [$full_artifact_path] to [$targetEcrUrl]." >&2
      echo "[FAILED_TAG] ${full_artifact_path}" >> "$failedList"
      return 1 # Failure to tag
    fi

    # 5. Docker Push
    echo "docker push \"$targetEcrUrl\""
    if ! docker push "$targetEcrUrl"; then
      echo "[WARNING] Failed to push image [$targetEcrUrl]..." >&2
      echo "[FAILED_PUSH] ${full_artifact_path}" >> "$failedList"
      return 1 # Failure to push
    fi
    echo "[INFO] Successfully pushed [$targetEcrUrl]"
    echo "[PUSHED] ${targetEcrUrl}" >> "$pushedList"

    # 6. Docker Image Inspect (Verification)
    echo "[INFO] Inspecting docker image for verification: ${targetEcrUrl}..."
    echo "docker image inspect \"${targetEcrUrl}\""
    if ! docker image inspect "${targetEcrUrl}" &>/dev/null; then
      echo "[ERROR] Verification failed: ${targetEcrUrl}. Image not found in ECR after push." >&2
      echo "[FAILED_VERIFICATION] ${full_artifact_path}" >> "$failedList"
      return 1 # Failure in verification
    fi
    echo "[INFO] Verification successful for [$targetEcrUrl]."

  else
    echo "[INFO] Push for [$full_artifact_path] was skipped based on duplicate check or explicit rules."
  fi

  echo "--------------------------------------------------------------------"
  return 0 # Success for this artifact (either pushed or skipped)
}