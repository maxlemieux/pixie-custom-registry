# pixie-custom-registry
Helper for hosting custom images for Pixie

pixie-custom-registry.sh will try to pull images for Pixie, its operators and dependencies, then create custom repositories on your existing AWS ECR registry and upload the tagged images.

Tested with AWS ECR, running on MacOS 12.6 with zsh. Takes a few minutes to run.

Requires:

Custom image registry, currently supporting AWS ECR.
A shell to run it, and permission to write to the current directory.

Usage:

`AWS_REGION=us-east-1 REGISTRY_URL=12345.dkr.ecr.us-east-1.amazonaws.com ./pixie-custom-registry.sh`

```
pixie-chart:
  registry: "12345.dkr.ecr.us-east-1.amazonaws.com"
```

You can remove the temporary files after running the script:

```
downloaded/
yamls/
bundle.Dockerfile
```
