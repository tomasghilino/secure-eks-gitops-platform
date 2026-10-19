# Only images signed by CI get in

Kyverno checks every pod in staging and production before it starts. For the API image it wants three things, all signed with the KMS key that CI uses: the signature itself, an SBOM, and a provenance record saying the image was built from this repo's `dev` branch.

To make sure it actually says no, I ran the same pod in production with `kubectl apply --dry-run=server` and only changed the image. The last one is our image name pointing at another AWS account's ECR:

```text
signed-with-sbom      pod/signed-with-sbom created (server dry run)
never-signed          denied: the api image is not signed with the ci key
signed-without-sbom   denied: the api image has no sbom signed with the ci key
docker-hub            denied (restrict-image-sources): only the api image pinned to a commit and a digest, ...
someone-elses-ecr     denied: kyverno's role can't read that registry (DENIED), and the policy fails closed
```

The first two rejected images aren't fakes. They're real images from our own ECR, built by the same CI before I added signing and SBOMs.

Funny enough, the policy also rejected the good image on the first try. Kyverno hands you the whole signed statement, not just the provenance inside it, so my path to the branch name was one level off. I found it by copying the policy into a throwaway namespace and making it print what it saw.
