---
title: Obtaining root access in a pod running under kind on Podman
updated: 05-03-2025
---

I am using a development environment that utilizes [`kind`](https://kind.sigs.k8s.io/) running under [rootless Podman](https://kind.sigs.k8s.io/docs/user/rootless/#creating-a-kind-cluster-with-rootless-podman). Here's how I was able to save some time while debugging and avoid needing to rebuild/redeploy when testing changes to containers that are not running as root.

First, we need to exec from our host into the `kind` container:

```
$ podman exec -ti kind-control-plane bash
```

Next, locate the container we want to access:

```
root@kind-control-plane:/# crictl ps | grep api
46fc42d2ed03c       09ba385429956       16 minutes ago      Running             api                    0                   8f72c70f538a5       my-app-8544786747-rzwlp                  default
```

Obtain the full ID:

```
root@kind-control-plane:/# crictl inspect 46fc42d2ed03c | jq -r '.status.id'
46fc42d2ed03c7e42452725bcdea05c089958b1d2c62f4d68526c2640e8cab8a
```

Now we can gain root access to our container:

```
root@kind-control-plane:/# ctr --namespace k8s.io tasks exec --user 0 --exec-id debug --tty 46fc42d2ed03c7e42452725bcdea05c089958b1d2c62f4d68526c2640e8ca
b8a /bin/sh
sh-4.4# id -u   
0
```

🤘
