---
title: Running Qwen3.8 on a DGX Spark
modified: 08-31-2026
---

I got my DGX Spark yesterday and immediately started trying to get a useful local model running on it. The goal was fairly simple: run something capable enough to use for coding and general computer work, keep the data on my own machine, and have it available to more than one client at a time.

As usual, the simple version of the goal turned out to involve considerably more decisions than I expected.

## The hardware

The machine is a DGX Spark with an NVIDIA GB10 and 128 GB of unified memory. That last part is important. There isn't a separate pool of VRAM that the operating system can ignore. The CPU, GPU, desktop, and model all draw from the same memory pool.

This makes the Spark feel a little different from a conventional workstation GPU. A model can fit according to its weight size and still leave the rest of the machine struggling once the runtime allocates its KV cache, CUDA graphs, and temporary buffers.

## Choosing a model

I started with Qwen3.8-27B. It is a dense hybrid-attention model with a vision encoder, a native 262,144-token context window, and a built-in multi-token prediction head. It is also a model that benefits from a serving runtime that understands more than just ordinary transformer attention.

The first version I tried was an NVFP4 checkpoint. It was fast and it worked, but I wasn't happy with the quality. That left me with an awkward choice: use the fast quantized checkpoint, or give up some serving performance in exchange for a higher-quality quantization.

I tried the Q6_K_XL GGUF variant through llama.cpp. The model fit and llama.cpp could use the GPU once I selected the CUDA image rather than the generic ARM64 image. It also supported parallel slots and DFlash2 speculative decoding.

That setup was useful, but the prompt processing and first-token latency were noticeably worse than the SGLang setup. It was a good reminder that model format and serving runtime are coupled more tightly than the OpenAI-compatible API makes obvious.

## FP8 was the compromise

The solution was to try the native FP8 checkpoint instead:

```text
Qwen/Qwen3.8-27B-FP8
```

This is not a GGUF conversion. It is a fine-grained FP8 checkpoint in the Hugging Face format, and it can be loaded directly by SGLang. That means SGLang can use the model-specific implementation and its optimized kernels instead of treating the model as a generic file to be decoded.

The FP8 model uses more memory than NVFP4, but considerably less than BF16. On this machine that gives us a useful middle ground: better quality than NVFP4, while leaving enough memory for the serving runtime and concurrent requests.

## Running SGLang in a container

I used the ARM64 image built for the Qwen3.8 serving path:

```text
docker.io/lmsysorg/sglang:dev-qwen38-27b-dflash2
```

The container is started with rootless Podman and gets the GPU through NVIDIA CDI. The model itself is mounted read-only from the host, while the compiler and runtime cache lives under `~/.cache` so that a restart doesn't discard everything SGLang has already built.

The complete Quadlet looks like this:

```ini
[Unit]
Description=Qwen3.8-27B FP8 + DFlash2 (SGLang CUDA)
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/lmsysorg/sglang:dev-qwen38-27b-dflash2
ContainerName=qwen38-fp8
AddDevice=nvidia.com/gpu=all
SecurityLabelDisable=true
Network=host
PodmanArgs=--ipc=host
Memory=110g

Environment=HF_HOME=/root/.cache/huggingface
Environment=HF_HUB_CACHE=/root/.cache/huggingface/hub
Environment=SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1
Secret=qwen38-hf,target=HF_TOKEN,type=env
Secret=qwen38-api,target=/run/secrets/qwen38-api,type=mount

Volume=%h/.local/share/models/qwen3.8-27b-fp8:/models:ro
Volume=%h/.cache/qwen38-sglang:/root/.cache

Exec=/bin/sh -c 'exec python3 -m sglang.launch_server \
    --model-path /models \
    --trust-remote-code \
    --tp-size 1 \
    --served-model-name qwen3.8-27b-fp8 \
    --host 0.0.0.0 \
    --port 30000 \
    --mem-fraction-static 0.50 \
    --max-running-requests 2 \
    --context-length 262144 \
    --chunked-prefill-size 8192 \
    --attention-backend flashinfer \
    --disable-prefill-cuda-graph \
    --cuda-graph-max-bs 4 \
    --disable-flashinfer-autotune \
    --enable-torch-compile \
    --torch-compile-max-bs 4 \
    --reasoning-parser qwen3 \
    --tool-call-parser qwen3_coder \
    --speculative-algorithm DFLASH \
    --speculative-draft-model-path z-lab/Qwen3.8-27B-DFlash2 \
    --speculative-draft-model-revision 50307d4c4cde6860d4eee73e2547cd786fe8e8a4 \
    --speculative-num-draft-tokens 6 \
    --speculative-draft-model-quantization unquant \
    --mamba-radix-cache-strategy extra_buffer \
    --mamba-ssm-dtype bfloat16 \
    --max-mamba-cache-size 10 \
    --api-key "$$(cat /run/secrets/qwen38-api)"'

[Service]
Restart=on-failure
RestartSec=20
TimeoutStartSec=infinity

[Install]
WantedBy=default.target
```

The two Podman secrets are populated from the desktop keyring and injected at container start. The Hugging Face token is exposed as `HF_TOKEN` for downloads; the API key is mounted temporarily at `/run/secrets/qwen38-api` so the server can read it without putting its value in the Quadlet.

The model is served with a 262,144-token context and two running requests. I started with two rather than filling the machine with speculative concurrency. On a unified-memory system, leaving room for the desktop is part of making the setup reliable.

The long hexadecimal value in the command is not a model setting. It is the revision of the DFlash2 repository. I got it by looking up the repository's Git history and choosing the exact commit used by the Qwen3.8 SGLang recipe. The command-line option is called `--speculative-draft-model-revision`, and setting it means Hugging Face downloads that specific version instead of whatever happens to be current on `main`.

In other words, these two pieces belong together:

```text
--speculative-draft-model-path z-lab/Qwen3.8-27B-DFlash2
--speculative-draft-model-revision 50307d4c4cde6860d4eee73e2547cd786fe8e8a4
```

The first identifies the repository. The second pins the repository to an immutable revision. If the draft model is updated later, this deployment will continue using the version that was tested here.

## CUDA graphs and DFlash2

The long startup is intentional. SGLang loads both the target model and the DFlash2 draft model, compiles the Triton and FlashInfer kernels, and captures CUDA graphs for the decode and verification paths.

The log contains messages like these during startup:

```text
Capture target verify CUDA graph end
DFLASH selector decode folded into the draft cuda graph
Capture draft verify CUDA graph begin
```

Prefill CUDA graphs are disabled because prompt lengths vary and capturing every possible prompt shape would consume a lot of memory. Decode and speculative verification graphs are still enabled, which is where the repeated work happens.

The result is a slow first boot followed by a much more capable serving path. Once the graphs and kernels are ready, SGLang can batch requests, reuse prefixes, and verify several drafted tokens at once. DFlash2 changes the speed of generation, not the target model's output: the target still verifies the result.

## The Quadlet

After getting the model working, I moved the container into a real Quadlet so that it would no longer depend on a terminal or a background process started from a shell.

The source file lives at:

```text
~/.config/containers/systemd/qwen38-fp8.container
```

The generated service is managed like any other user service:

```bash
systemctl --user status qwen38-fp8
journalctl --user -u qwen38-fp8 -f
systemctl --user restart qwen38-fp8
```

The service is enabled for my user, so it starts as part of the user systemd environment. If I stop it, the model stops. If the process exits unexpectedly, systemd starts it again.

## Keeping credentials out of the unit

The SGLang server has an API key. Hugging Face also supports an optional token for higher rate limits, which is useful when the draft model needs to be downloaded. I initially used a small environment file, but that felt like the wrong place for secrets.

Instead, I put the values in the desktop keyring with `secret-tool`, then copied them into Podman secrets. The Quadlet receives the secrets without putting their values in the unit file or the shell command used to start the service.

I populated the keyring without putting either credential in a file or in my shell history:

```bash
secret-tool store \\
  --label="Qwen38 local API key" \\
  service qwen38 type api-key

secret-tool store \\
  --label="Hugging Face token" \\
  service huggingface type token
```

Each command prompts for the secret on standard input. I then verified that the entries existed without printing their contents:

```bash
secret-tool lookup service qwen38 type api-key \
  | wc -c

secret-tool lookup service huggingface type token \
  | wc -c
```

The API key is required by the local server; the Hugging Face token is optional and is only used to get higher download rate limits. If you do not need those higher limits, omit the HF token and the `qwen38-hf` secret.

Podman secrets can then be populated from the keyring through a pipe:

```bash
secret-tool lookup service qwen38 type api-key \
  | podman secret create --replace qwen38-api -

secret-tool lookup service huggingface type token \
  | podman secret create --replace qwen38-hf -
```

The `--replace` option makes it possible to rotate a credential and recreate the container without editing the Quadlet. The values themselves never appear in the commands above. I also avoid using `podman secret inspect --showsecret` except when deliberately testing a secret, since that would print the credential.

The important part is not the particular secret backend. It is keeping credentials separate from the deployment configuration and making sure they don't end up in the service definition, shell history, or logs.

## Using the model

The server exposes an OpenAI-compatible API:

```text
http://127.0.0.1:30000/v1
```

That made it straightforward to connect both Pi and Hermes. The client only needs the endpoint, the model name, and the API key:

```text
qwen3.8-27b-fp8
```

The API is convenient, but it also hides some differences between clients. In particular, Qwen's reasoning levels need to be mapped to the values accepted by its chat template. Once that was handled, the same local server worked from both clients.

## Performance

A simple 512-token streaming test on the running FP8 service produced approximately:

```text
Time to first token: 0.23 seconds
Decode speed:        17.4 tokens/second
End-to-end speed:    17.3 tokens/second
```

Those numbers depend heavily on prompt shape, reasoning mode, concurrency, and whether a prefix is already cached. They are not a universal benchmark, but they give me a repeatable baseline for future changes.

The more important result is that two clients can use the service without each loading its own copy of the model. SGLang handles the batching, while the Quadlet handles the lifecycle.

## What I learned

The most useful lesson was that the quantization, model architecture, and serving runtime cannot be evaluated independently.

- NVFP4 gave me the best raw serving characteristics, but I didn't like the quality.
- Q6_K_XL gave me the quality I wanted, but llama.cpp was slower for prompt processing and concurrent serving.
- FP8 gave SGLang a native checkpoint it could optimize while preserving more quality than NVFP4.
- CUDA graphs and speculative decoding made the long startup worthwhile.
- Rootless Podman and Quadlet made the final deployment repeatable.
- Unified memory means that model-serving limits are also desktop reliability limits.

This is the first local model setup I've had that feels like something I can leave running rather than a benchmark that happens to work once. It took more experimentation than I expected, but the final arrangement is fairly simple: one model directory, one cache, one Quadlet, and an OpenAI-compatible endpoint for the clients I actually use.
