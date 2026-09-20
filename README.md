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

## Publishing to ECR

The repository was created with two settings that matter more than they look:

```bash
aws ecr create-repository --repository-name demo-hardened \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true
```

**Immutable tags** mean a tag can never be repointed at a different image once
it's in use. Without that, someone can push new content under an existing
version tag and every deployment pulling that tag silently gets different code,
which also makes any prior scan result meaningless. New tags are still allowed,
so this costs nothing in normal use. It came up for real during deployment,
covered below.

**Scan on push** is ECR basic scanning, which checks OS packages at push time
using an open source CVE database. Enhanced scanning hands the job to Amazon
Inspector instead, which rescans continuously and covers language level
dependencies as well. Continuous rescanning is the part that matters, since a
clean image today can have a critical CVE published against it next month.

Authentication uses a temporary token rather than long lived credentials:

```bash
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ACCT.dkr.ecr.$AWS_REGION.amazonaws.com
```

`get-login-password` uses the caller's IAM identity to request a token valid
for 12 hours. `--password-stdin` keeps that token out of shell history and out
of the process list, which `--password <token>` would not.

Images are tagged by git commit SHA so each one traces back to the source that
produced it, and that tag is unique per build, which is what makes immutability
practical.

A lifecycle policy expires untagged images after 7 days. Untagged images
accumulate from re tagging and multi architecture builds, and they are both
storage cost and unreviewed attack surface. Lifecycle policies only support
expiry, and the action is irreversible, so `start-lifecycle-policy-preview` is
worth running first on anything real.

## Running it on ECS Fargate

A Fargate cluster, a task definition, and a standalone task, all in the console
so each setting was visible rather than buried in CLI flags.

Settings applied at the task definition level:

* **`readonlyRootFilesystem: true`**, which has no Dockerfile equivalent and
  only exists here. This one broke the container, which was the useful part.
* **Runtime platform ARM64**, matching the image rather than rebuilding it.
  More on that below.
* **Image selected by digest** rather than tag, so the task definition is
  pinned to exact bytes regardless of what any tag later points at.
* **CloudWatch logging** enabled, which turned out to be the only thing that
  made the second failure diagnosable.
* **Task execution role** for pulling from ECR and writing logs. Distinct from
  a task role, which is what application code would use to call AWS APIs. No
  task role was needed here since the app calls nothing.

Networking is set at launch rather than in the task definition, since the same
definition can be deployed into different environments. The task ran in a
public subnet with a public IP, behind a security group allowing TCP 8000 from
one source address only. The public IP is required both for reachability and
for the task to pull from ECR at all, and forgetting it produces an image pull
failure that reads like a permissions problem.

A standalone task was the right choice here over a service. A service maintains
a desired count and relaunches failed tasks forever, which turns a broken
deployment into a loop. A standalone task runs once and stops, which is what
you want while debugging.

## Three failures worth documenting

The image worked locally on the first try. Getting it running on Fargate took
three rounds, each with a different signature and a different diagnostic path.

### 1. Architecture mismatch

```
CannotPullContainerError: manifest does not contain descriptor
matching platform 'linux/amd64'
```

Built on Apple Silicon, so the image was `linux/arm64`, while the task
definition asked for x86_64. The task never started, so there were no logs at
all. The stopped reason was the only evidence available.

There are two ways out: rebuild with `docker build --platform linux/amd64`, or
change the task's runtime platform to ARM64 so it matches the image. I matched
the task to the image, since Fargate runs ARM64 on Graviton at a lower rate per
vCPU hour and this service has no x86 dependency. The tradeoff is that the
image now only runs on ARM hosts, which is fine for one service and would be a
problem for a shared base image.

The durable fix is not building release images on laptops at all. CI builds on
a known architecture, or `buildx` publishes a multi architecture manifest so
one tag serves both and the platform question stops mattering.

### 2. Read only filesystem versus gunicorn

This time the container started and then exited 255, so CloudWatch had output.

```
FileNotFoundError: [Errno 2] No usable temporary directory found in
['/tmp', '/var/tmp', '/usr/tmp', '/app']
```

Gunicorn creates a small heartbeat file per worker and had nowhere writable to
put it. Fixed by pointing it at `/dev/shm`, which is memory backed and writable
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

Exit code 2, which means bad arguments, and the log was a usage message rather
than a traceback.

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

* **The AWS side is clickops.** The ECR repository, task definition, and
  cluster were all created in the console. That is untracked infrastructure,
  which is the same drift problem this kind of work is supposed to solve.
  `aws_ecr_repository`, `aws_ecr_lifecycle_policy`, and
  `aws_ecs_task_definition` would bring it under code.
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
* **ECS Exec was not enabled.** It needs SSM messaging permissions on the task
  role specifically, and in a regulated environment it should log sessions to
  CloudWatch or S3, since shelling into a production container is an auditable
  event.
* **Not distroless.** The next step down in attack surface removes the shell
  and package manager entirely, at the cost of not being able to exec in and
  look around. That trade is worth making once the debugging story is handled.
