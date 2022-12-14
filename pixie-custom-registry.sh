#!/bin/bash

# Based on Pixie docs at https://docs.pixielabs.ai/reference/admin/deploy-options#custom-image-registry
# Supports AWS ECR registries. You must have a registry and provide a URL for it.

# Usage: REGISTRY_URL=12345.dkr.ecr.us-east-1.amazonaws.com AWS_REGION=us-east-1 ./pixie-custom-registry.sh

VERBOSE=0
# check for verbose mode
if [ "$1" = "-v" ]; then 
    VERBOSE=1
fi

# Called when a needed repo already exists
warn_repo_exists () {
    if [ "$VERBOSE" = "1" ]; then
        echo "Repository already exists, not creating"
    fi
}

# Don't run if we have previous runs around
BUILD_FILES=( yamls downloaded bundle.Dockerfile )
for i in "${BUILD_FILES[@]}"
do
    if test -e $i; then
        echo "Directory or build file exists, please remove it:" $i
        exit
    fi
done

########
# Vizier
########

# Get latest Vizier yamls
echo "Downloading Vizier yamls"
curl https://storage.googleapis.com/pixie-dev-public/vizier/latest/vizier_yamls.tar | tar x

echo "Logging into custom registry"
# Login to AWS ECR (replace this if you need to use a different registry)
#aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY_URL" $OUTPUT
AWS_LOGIN_COMMAND=("aws" "ecr" "get-login-password" "--region" "$AWS_REGION")
DOCKER_LOGIN_COMMAND=("docker" "login" "--username" "AWS" "--password-stdin" "$REGISTRY_URL")

if [ "$VERBOSE" = "0" ]; then
    "${AWS_LOGIN_COMMAND[@]}" | "${DOCKER_LOGIN_COMMAND[@]}" >> /dev/null 2>&1
elif [ "$VERBOSE" = "1" ]; then
    "${AWS_LOGIN_COMMAND[@]}" | "${DOCKER_LOGIN_COMMAND[@]}"
fi

echo "Creating and populating container repositories"
# Create the repositories using the naming convention defined by Pixie
# https://docs.pixielabs.ai/reference/admin/deploy-options#custom-image-registry-collect-the-vizier-images
if [ "$USE_ETCD_OPERATOR" = "1" ]; then
    VIZIER_IMAGE_LIST=yamls/images/vizier_etcd_image_list.txt
else
    VIZIER_IMAGE_LIST=yamls/images/vizier_image_list.txt
fi

while read -r i
do  
    echo "$i" | xargs docker pull >> /dev/null 2>&1

    NEW_IMAGE_NAME=$(echo "$i" | cut -f 1 -d ':' | cut -f 2 -d '"' | sed 's/\//-/g')
    if aws ecr describe-repositories --no-cli-pager --repository-name "$NEW_IMAGE_NAME" >> /dev/null 2>&1; then
        warn_repo_exists
    else
        aws ecr create-repository --no-cli-pager --repository-name "$NEW_IMAGE_NAME" >> /dev/null 2>&1
    fi

    PIXIE_IMAGE_NAME=$(echo "$i" | cut -f 1 -d ':'  | rev | cut -d '/' -f 1 | rev)
    #echo "Pixie image name: $PIXIE_IMAGE_NAME"
    PIXIE_IMAGE_ID=$(docker images | grep "$PIXIE_IMAGE_NAME" | cut -f 3 -w | tail -1)
    #echo "Pixie image id: $PIXIE_IMAGE_ID"
    CUSTOM_IMAGE_NAME=$(echo "$i" | cut -f 1 -d ':' | cut -f 2 -d '"' | sed 's/\//-/g')
    #echo "Custom image name: $CUSTOM_IMAGE_NAME"
    IMAGE_VERSION=$(docker images | grep "$PIXIE_IMAGE_NAME" | grep -v "$REGISTRY_URL" | cut -f 2 -w)
    #echo "Pixie image version: $IMAGE_VERSION"

    docker tag "$PIXIE_IMAGE_ID" "$REGISTRY_URL"/"$CUSTOM_IMAGE_NAME":"$IMAGE_VERSION" >> /dev/null 2>&1
    docker push "$REGISTRY_URL"/"$CUSTOM_IMAGE_NAME":"$IMAGE_VERSION" >> /dev/null 2>&1
done < "$VIZIER_IMAGE_LIST"

#####
# OPM
#####

echo "Building operator bundle"
opm index export --index gcr.io/pixie-oss/pixie-prod/operator/bundle_index:0.0.1 >> /dev/null 2>&1

# Get the latest version number (e.g. 0.0.34):
PIXIE_OPERATOR_VERSION=$(grep -A1 stable -m 1 downloaded/pixie-operator/package.yaml | grep current | cut -f 2 -d 'v')
echo "Got Pixie Operator version $PIXIE_OPERATOR_VERSION"

# Delete the replaces line (this is for Mac using BSD sed, use sed -i '/replaces/d' on Linux):
sed -i '' '/replaces/d' ./downloaded/pixie-operator/"$PIXIE_OPERATOR_VERSION"/csv.yaml

# Set up operator image repo (used by vizier-operator pod in px-operator namespace)
OPERATOR_IMAGE_REPO=gcr.io-pixie-oss-pixie-prod-operator-operator_image

# Check for the image attribute to be replaced with the custom repo URL:
# e.g. - image: gcr.io/pixie-oss/pixie-prod/operator/operator_image:0.0.34
IMAGE_TO_REPLACE=$(grep image ./downloaded/pixie-operator/"$PIXIE_OPERATOR_VERSION"/csv.yaml | cut -f 4 -w)
sed -i -e 's@'"$IMAGE_TO_REPLACE"'@'"$REGISTRY_URL"'/gcr.io-pixie-oss-pixie-prod-operator-operator_image@g' \
    ./downloaded/pixie-operator/"$PIXIE_OPERATOR_VERSION"/csv.yaml

if aws ecr describe-repositories --no-cli-pager --repository-name "$OPERATOR_IMAGE_REPO" >> /dev/null 2>&1; then
    warn_repo_exists
else
    aws ecr create-repository --no-cli-pager --repository-name "$OPERATOR_IMAGE_REPO" >> /dev/null 2>&1
fi

docker pull gcr.io/pixie-oss/pixie-prod/operator/operator_image:$PIXIE_OPERATOR_VERSION
OPERATOR_IMAGE_ID=$(docker images | grep operator_image | cut -f 3 -w | tail -1)
docker tag "$OPERATOR_IMAGE_ID" "$REGISTRY_URL"/"$OPERATOR_IMAGE_REPO":"$PIXIE_OPERATOR_VERSION" >> /dev/null 2>&1
docker push "$REGISTRY_URL"/"$OPERATOR_IMAGE_REPO":"$PIXIE_OPERATOR_VERSION" >> /dev/null 2>&1


# Create bundle repo
# Replace this if you don't use AWS ECR
aws ecr create-repository --repository-name bundle >> /dev/null 2>&1

# Building and pushing operator images to the custom registry
opm alpha bundle generate --package pixie-operator --channels stable --default stable \
    --directory downloaded/pixie-operator/"$PIXIE_OPERATOR_VERSION" >> /dev/null 2>&1
docker build -t "$REGISTRY_URL"/bundle:"$PIXIE_OPERATOR_VERSION" -f bundle.Dockerfile . >> /dev/null 2>&1
docker push "$REGISTRY_URL"/bundle:"$PIXIE_OPERATOR_VERSION" >> /dev/null 2>&1

# Create bundle index, repo for bundle index, and push the image
OPERATOR_BUNDLE_REPO=gcr.io-pixie-oss-pixie-prod-operator-bundle_index

opm index add --bundles "$REGISTRY_URL"/bundle:"$PIXIE_OPERATOR_VERSION" \
    --tag "$REGISTRY_URL"/"$OPERATOR_BUNDLE_REPO":0.0.1 -u docker >> /dev/null 2>&1
if aws ecr describe-repositories --no-cli-pager --repository-name "$OPERATOR_BUNDLE_REPO" >> /dev/null 2>&1; then
    warn_repo_exists
else
    aws ecr create-repository --no-cli-pager --repository-name "$OPERATOR_BUNDLE_REPO" >> /dev/null 2>&1
fi
docker push "$REGISTRY_URL"/"$OPERATOR_BUNDLE_REPO":0.0.1 >> /dev/null 2>&1

echo "Building dependencies"
# And finally, install these dependencies
docker pull quay.io/operator-framework/olm >> /dev/null 2>&1
docker pull quay.io/operator-framework/olm@sha256:b706ee6583c4c3cf8059d44234c8a4505804adcc742bcddb3d1e2f6eff3d6519 >> /dev/null 2>&1
docker pull quay.io/operator-framework/configmap-operator-registry >> /dev/null 2>&1

# Create ECR repos (change if not using ECR)
OLM_REPO=quay.io-operator-framework-olm
if aws ecr describe-repositories --no-cli-pager --repository-name "$OLM_REPO" >> /dev/null 2>&1; then
    warn_repo_exists
else
    aws ecr create-repository --no-cli-pager --repository-name "$OLM_REPO" >> /dev/null 2>&1
fi

CONFIGMAP_REPO=quay.io-operator-framework-configmap-operator-registry
if aws ecr describe-repositories --no-cli-pager --repository-name "$CONFIGMAP_REPO" >> /dev/null 2>&1; then
    warn_repo_exists
else
    aws ecr create-repository --no-cli-pager --repository-name "$CONFIGMAP_REPO" >> /dev/null 2>&1
fi

# Docker tag and push for Operator Framework
# This is the id for quay.io/operator-framework/olm@sha256:b706ee6583c4c3cf8059d44234c8a4505804adcc742bcddb3d1e2f6eff3d6519
OLM_IMAGE_ID="93b0a108131b"
docker tag "$OLM_IMAGE_ID" "$REGISTRY_URL"/quay.io-operator-framework-olm:latest >> /dev/null 2>&1
docker push "$REGISTRY_URL"/quay.io-operator-framework-olm:latest >> /dev/null 2>&1

# Configmap image id
CONFIGMAP_IMAGE_ID=$(docker images | grep "configmap-operator-registry" | cut -f 3 -w | head -1)
docker tag "$CONFIGMAP_IMAGE_ID" "$REGISTRY_URL"/quay.io-operator-framework-configmap-operator-registry:latest >> /dev/null 2>&1
docker push "$REGISTRY_URL"/quay.io-operator-framework-configmap-operator-registry:latest >> /dev/null 2>&1

echo "Completed."

#########
# CLEANUP  
#########
# rm -rf downloaded
# rm -rf yamls
# rm bundle.Dockerfile
