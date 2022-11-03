#!/bin/sh
# Supports AWS ECR registries. You must have a registry and provide a URL for it.
# Usage: REGISTRY_URL=12345.dkr.ecr.us-east-1.amazonaws.com AWS_REGION=us-east-1 ./pixie-custom-registry.sh

# Called when a needed repo already exists
warn_repo_exists () {
    echo "Repository already exists, not creating"
}

# Don't run if we have previous runs around
if test -e "yamls"; then
    echo "yamls directory exists, please remove it."
    exit
fi

if test -e "downloads"; then
    echo "downloads directory exists, please remove it"
    exit
fi

if test -f "bundle.Dockerfile"; then
    echo "bundle.Dockerfile exists, please remove it"
    exit
fi

########
# Vizier
########

# Get latest Vizier yamls
echo "Downloading Vizier yamls"
curl https://storage.googleapis.com/pixie-dev-public/vizier/latest/vizier_yamls.tar | tar x

echo "Logging into custom registry"
# Login to AWS ECR (replace this if you need to use a different registry)
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REGISTRY_URL

# Create the repositories using the naming convention defined by Pixie
# https://docs.pixielabs.ai/reference/admin/deploy-options#custom-image-registry-collect-the-vizier-images
for i in $(cat yamls/images/vizier_image_list.txt)
do 
    echo $i | xargs docker pull

    NEW_IMAGE_NAME=$(echo $i | cut -f 1 -d ':' | cut -f 2 -d '"' | sed 's/\//-/g')
    aws ecr describe-repositories --repository-name $NEW_IMAGE_NAME >> /dev/null 2>&1 && warn_repo_exists || aws ecr create-repository --repository-name $NEW_IMAGE_NAME 

    PIXIE_IMAGE_NAME=$(echo $i | cut -f 1 -d ':'  | rev | cut -d '/' -f 1 | rev)
    PIXIE_IMAGE_ID=$(docker images | grep $PIXIE_IMAGE_NAME | cut -f 3 -w | tail -1)
    CUSTOM_IMAGE_NAME=$(echo $i | cut -f 1 -d ':' | cut -f 2 -d '"' | sed 's/\//-/g')
    IMAGE_VERSION=$(docker images | grep $PIXIE_IMAGE_NAME | grep -v $REGISTRY_URL | cut -f 2 -w)

    docker tag $PIXIE_IMAGE_ID $REGISTRY_URL/$CUSTOM_IMAGE_NAME
    docker push $REGISTRY_URL/$CUSTOM_IMAGE_NAME\:$IMAGE_VERSION
done

#####
# OPM
#####

echo "Downloading opm"
opm index export --index gcr.io/pixie-oss/pixie-prod/operator/bundle_index:0.0.1

# Get the latest version number (e.g. 0.0.32):
PIXIE_OPERATOR_VERSION=$(grep -A1 stable -m 1 downloaded/pixie-operator/package.yaml | grep current | cut -f 2 -d 'v')
echo "Got Pixie Operator version $PIXIE_OPERATOR_VERSION"

# Delete the replaces line (this is for Mac using BSD sed, use sed -i '/replaces/d' on Linux):
sed -i '' '/replaces/d' ./downloaded/pixie-operator/$PIXIE_OPERATOR_VERSION/csv.yaml

# Check for the image attribute to be replaced with the custom repo URL:
# e.g. - image: gcr.io/pixie-oss/pixie-prod/operator/operator_image:0.0.32
echo "Replacing the image attribute with the custom repo URL."
IMAGE_TO_REPLACE=$(grep image ./downloaded/pixie-operator/$PIXIE_OPERATOR_VERSION/csv.yaml | cut -f 4 -w)
sed -i -e 's@'"$IMAGE_TO_REPLACE"'@'"$REGISTRY_URL"'/gcr.io-pixie-oss-pixie-prod-operator-operator_image@g' ./downloaded/pixie-operator/$PIXIE_OPERATOR_VERSION/csv.yaml

# Replace this if you don't use AWS ECR
aws ecr create-repository --repository-name bundle

# Building and pushing operator images to the custom registry
opm alpha bundle generate --package pixie-operator --channels stable --default stable --directory downloaded/pixie-operator/0.0.32
docker build -t $REGISTRY_URL/bundle:0.0.32 -f bundle.Dockerfile .
docker push $REGISTRY_URL/bundle:0.0.32   

# Create bundle index, repo for bundle index, and push the image
opm index add --bundles $REGISTRY_URL/bundle:0.0.32 --tag $REGISTRY_URL/gcr.io-pixie-oss-pixie-prod-operator-bundle_index:0.0.1 -u docker
OPERATOR_BUNDLE_REPO=gcr.io-pixie-oss-pixie-prod-operator-bundle_index
aws ecr describe-repositories --repository-name $OPERATOR_BUNDLE_REPO >> /dev/null 2>&1 && warn_repo_exists || aws ecr create-repository --repository-name $OPERATOR_BUNDLE_REPO
docker push $REGISTRY_URL/gcr.io-pixie-oss-pixie-prod-operator-bundle_index:0.0.1

# And finally, install these dependencies
docker pull quay.io/operator-framework/olm
docker pull quay.io/operator-framework/configmap-operator-registry

# Create ECR repos (change if not using ECR)
OLM_REPO=quay.io-operator-framework-olm
aws ecr describe-repositories --repository-name $OLM_REPO >> /dev/null 2>&1 && warn_repo_exists || aws ecr create-repository --repository-name $OLM_REPO

CONFIGMAP_REPO=quay.io-operator-framework-configmap-operator-registry
aws ecr describe-repositories --repository-name $CONFIGMAP_REPO >> /dev/null 2>&1 && warn_repo_exists || aws ecr create-repository --repository-name $CONFIGMAP_REPO

# Docker tag and push
OLM_IMAGE_ID=$(docker images | grep "operator-framework/olm" | cut -f 3 -w | head -1)
echo $OLM_IMAGE_ID
docker tag $OLM_IMAGE_ID $REGISTRY_URL/quay.io-operator-framework-olm:latest
docker push $REGISTRY_URL/quay.io-operator-framework-olm:latest

CONFIGMAP_IMAGE_ID=$(docker images | grep "configmap-operator-registry" | cut -f 3 -w | head -1)
echo $CONFIGMAP_IMAGE_ID
docker tag $CONFIGMAP_IMAGE_ID $REGISTRY_URL/quay.io-operator-framework-configmap-operator-registry:latest
docker push $REGISTRY_URL/quay.io-operator-framework-configmap-operator-registry:latest


#########
# CLEANUP  
#########
# or just download to a new temp directory each time...
# rm -rf downloaded
# rm -rf yamls
# rm -rf bundle.Dockerfile