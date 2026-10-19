# Falco catches an attacker inside a container

Kyverno decides what's allowed to start. Once something is running, Falco watches what it does by reading system calls on every node.

I played the attacker in a throwaway pod: read `/etc/shadow`, searched for AWS keys and tried to reach the Kubernetes API. Falco logged each step within two seconds, and the alerts showed up in Alertmanager 38 seconds after I started:

```text
18:23:21 WARNING | Read sensitive file untrusted         | pod attacker | cmd cat /etc/shadow
18:23:21 WARNING | Find AWS Credentials                  | pod attacker | cmd grep -rs aws_secret_access_key /etc /root /home
18:23:21 NOTICE  | Contact K8S API Server From Container | pod attacker | cmd wget ... https://kubernetes.default.svc

alertmanager 18:23:57   FalcoWarningEvent | Falco: Read sensitive file untrusted | active
                        FalcoWarningEvent | Falco: Find AWS Credentials         | active
```

Two things I didn't see coming. Out of the box, Falco flagged Argo CD and Kyverno 54 times for talking to the Kubernetes API, which is literally their job. I excluded the platform namespaces and added a stricter rule for staging and production instead.

The other one: the textbook alert, `increase()` on Falco's counter, would have missed this exact attack. Falco creates the counter at 1 on the first match, so the increase looks like zero. The alert's unit tests caught that before the cluster did.
