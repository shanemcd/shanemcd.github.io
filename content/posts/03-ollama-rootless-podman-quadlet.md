---
title: Running Ollama under Rootless Podman with Quadlet
---

I haven't seen any instances of other people running Ollama quite like this, so I thought I would share in case it proves to be useful for anyone else out there.

For those not familiar with Quadlet, it provides functionality that allows you to run and manage containers with `systemd`.

## NVIDIA GPU support

Before we can run Ollama inside of a container we first need to install the NVIDIA Container Toolkit as described [here](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html#with-dnf-rhel-centos-fedora-amazon-linux).

### Generating the CDI specification file

The documentation [here](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html) shows running this command manually. Given this will likely need to be re-ran over time and it is safe to re-invoke multiple times, I decided to wrap this up in a systemd unit that runs once every time my machine boots:

```ini
[Unit]
Description=Generate NVIDIA CDI configuration

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Place this in `/etc/systemd/system/nvidia-cdi-generator.service` and run these commands as root:

```
$ systemctl daemon-reload
$ systemctl enable --now nvidia-cdi-generator.service
```

## Ollama with Podman and Quadlet

Now that we can talk to our NVIDIA GPU from within a container, we can create a Quadlet in `~/.config/containers/systemd/ollama.container`:

```ini
[Unit]
Description=My Llama
Requires=nvidia-cdi-generator
After=nvidia-cdi-generator

[Container]
Image=docker.io/ollama/ollama
AutoUpdate=registry
PodmanArgs=--privileged --gpus=all
Environment=NVIDIA_VISIBLE_DEVICES=all
Volume=%h/.ollama:/root/.ollama
PublishPort=11434:11434

[Service]
Restart=always

[Install]
WantedBy=default.target
```

Start it by:

```
$ systemctl --user daemon-reload
$ systemctl --user start ollama.service
```

Verify it's running by viewing the logs:

```
$ journalctl --user -xeu ollama
```
