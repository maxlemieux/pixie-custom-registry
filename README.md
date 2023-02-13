# pixie-custom-registry

### About

Automation for the custom image registry process documented by Pixie: https://docs.pixielabs.ai/reference/admin/deploy-options#custom-image-registry

pixie-custom-registry.sh will try to pull images for Pixie, its operators and dependencies, then it will create custom repositories on your existing [AWS ECR registry](https://docs.aws.amazon.com/AmazonECR/latest/userguide/Registries.html) and upload the tagged images.

What this script does not do: It does not create ECR registries. You will need a registry available to set the environment for REGISTRY_URL.

### Requirements
* Tested with AWS ECR, running on MacOS 12.6 with zsh. Current Pixie version is 0.0.32.
* Authenticated to an available AWS ECR registry: https://docs.aws.amazon.com/AmazonECR/latest/userguide/getting-started-cli.html#cli-authenticate-registry
* A shell to run the script, and permission to write to the current directory.
* Logged into Docker (`docker login` or Docker Desktop)
* Authenticated to AWS ECR

### Usage

Run the script:

`AWS_REGION=us-east-1 REGISTRY_URL=12345.dkr.ecr.us-east-1.amazonaws.com ./pixie-custom-registry.sh`

Check the AWS ECR console and you should see your new repositories.

### Configure Helm

In the chart `values.yaml`:

```
pixie-chart:
  registry: "12345.dkr.ecr.us-east-1.amazonaws.com"
```

### Notes
You can remove the temporary files after running the script:

```
downloaded/
yamls/
bundle.Dockerfile
```
