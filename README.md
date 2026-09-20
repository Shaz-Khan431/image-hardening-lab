# image-hardening-lab

The same Flask app built two ways, a naive Dockerfile and a hardened one. Both
were scanned and compared, then the hardened one was pushed to Amazon ECR and
deployed to ECS Fargate with a read only root filesystem.

Built as a hands on study project to work through container hardening, image
scanning, ECR publishing, and the failure modes you only find by deploying.

`commands.md` is the working notebook. It has every command run, its actual
output, and notes on what each flag does.

## What's here

```
├── app.py            # minimal Flask app with a /health endpoint
├── requirements.txt
├── Dockerfile        # hardened
├── Dockerfile.bad    # the naive version, for comparison
├── .dockerignore
└── commands.md       # lab notebook with real output
```

## Results

| | `demo:bad` | `demo:good` |
|---|---|---|
| Base image | `python:3.12` | `python:3.12-slim` |
| Size | 1.63 GB | 213 MB |
| HIGH/CRITICAL CVEs | long list | much shorter |
| Runs as | root | `app` (UID 10001) |
| Build artifacts in final image | yes | no, multistage |
| Server | Flask dev server | gunicorn |

## What hardening actually meant here

Mostly removing things rather than adding patches. Every package in an image is
code that can carry a CVE, so the smallest image with the fewest packages has
the least to scan, patch, and exploit.

* **Slim base image.** Fewer OS packages, so fewer CVEs inherited before a
  single line of application code exists.
* **Multistage build.** Dependencies are installed in a builder stage and only
  the installed packages are copied forward. Compilers, caches, and build
  tooling never reach the final image.
* **Non root user** with a pinned numeric UID. Filesystem permissions and
  orchestrator security settings operate on numbers, not names.
* **Dependency layer copied before source**, so editing `app.py` doesn't
  invalidate the cached dependency install.
* **`.dockerignore`.** `Dockerfile.bad` does `COPY . /app`, which sweeps in
  `.git` and anything else sitting in the directory. Secrets copied into a
  layer persist there even if a later instruction deletes them.
* **Production WSGI server** instead of Flask's development server.

## Toolchain

Each tool covers a different layer, and none of them substitutes for another.

| Tool | Checks |
|---|---|
| **Hadolint** | the Dockerfile itself, before building |
| **Trivy** | CVEs in the built image |
| **Syft** | SBOM, meaning what's actually inside |
| **ECR scan on push** | the image at rest in the registry |

Hadolint flagged a missing `--no-cache-dir` on the bad Dockerfile. It said
nothing about running as root, the full base image, or copying the entire build
context. It's a recipe linter, not a hardening auditor.

## Deploying it: three failures worth documenting

The image worked locally on the first try. Getting it running on Fargate took
three rounds, each with a different signature.

### 1. Architecture mismatch

```
CannotPullContainerError: manifest does not contain descriptor
matching platform 'linux/amd64'
```

Built on Apple Silicon, so the image was `linux/arm64`, while Fargate defaults
to x86_64. Fixed with `docker build --platform linux/amd64`. Because the ECR
repository is tag immutable, the rebuild had to go up under a new tag rather
than overwriting the old one, which is that setting working as intended.

The durable fix is not building release images on laptops at all. CI builds on
a known architecture, or `buildx` publishes a multi architecture manifest so
one tag serves both.

### 2. Read only filesystem versus gunicorn

The task exited 255 immediately after logging that gunicorn was listening.

```
FileNotFoundError: [Errno 2] No usable temporary directory found in
['/tmp', '/var/tmp', '/usr/tmp', '/app']
```

The task definition had `readonlyRootFilesystem: true`. Gunicorn creates a
small heartbeat file per worker and had nowhere writable to put it.

Fixed by pointing gunicorn at `/dev/shm`, which is memory backed and writable
even with a read only root, rather than by turning the control off:

```dockerfile
CMD ["gunicorn", "-b", "0.0.0.0:8000", "--worker-tmp-dir", "/dev/shm", "app:app"]
```

Notably the container logged `Listening at: http://0.0.0.0:8000` before dying.
A startup log line is not evidence that the app is healthy.

### 3. A tag that lied

```
gunicorn: error: unrecognized arguments: app:app
```

The fixed `CMD` was in the Dockerfile, but the image had been re tagged and
pushed without being rebuilt, so a fresh commit SHA pointed at stale content.

A tag asserts a relationship to source code that nothing actually enforces.
This is why deployments should pin digests rather than tags, and why build
provenance exists as a concept.

## Reproducing the read only failure locally

Debugging in ECS means a build, a push, a new task definition revision, and a
task launch for every attempt. The same constraint reproduces locally in
seconds:

```bash
docker run --rm -d -p 8000:8000 --read-only --name demo demo:good
curl localhost:8000/health
```

## Known gaps

* **The base image is not pinned by digest.** `python:3.12-slim` is a moving
  tag. Production would pin `@sha256:...` and pair that with scheduled
  rebuilds, so version drift becomes a reviewed change rather than a silent
  one.
* **No checksum verification** on downloaded artifacts, and no lock file with
  hashes for the Python dependencies.
* **No image signing.** A digest proves the image hasn't changed. A signature
  proves it came from your pipeline. Cosign plus a policy that refuses unsigned
  images is the pair, since a signature nobody verifies accomplishes nothing.
* **Scanning is not a gate.** Trivy was run by hand. In CI it would run with
  `--exit-code 1 --severity CRITICAL --ignore-unfixed` so bad images never
  reach the registry, with ECR and Inspector continuous scanning as the
  backstop for CVEs published after the build.
* **Not distroless.** The next step down in attack surface removes the shell
  and package manager entirely, at the cost of not being able to exec in and
  look around. That trade is worth making once the debugging story is handled.
