# Evidence

Each of these is something I broke on purpose, or a control I tried to sneak past, and what stopped it. The logs are trimmed, and account IDs and hostnames are removed.

- [Only images signed by CI get in](signed-images-at-admission.md)
- [Promoting to production, and rolling back](promotion-and-rollback.md)
- [CI talks to AWS without keys, and only from dev](github-oidc.md)
- [A manual change in production, undone in two seconds](drift-self-heal.md)
- [Staging asks for production's password, and AWS says no](secrets-across-environments.md)
- [Falco catches an attacker inside a container](falco-runtime-detection.md)
- [A hole in the image rules: kubectl debug](debug-container-bypass.md)
