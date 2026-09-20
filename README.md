# Image Hardening Lab

Building the same Flask app two ways, a naive Dockerfile and a hardened one, 
then comparing size and CVE count, and verifying the hardening actually held.

## Building both images

```bash
docker build -f Dockerfile.bad -t demo:bad .
docker build -t demo:good .
```

`-f` specifies a filename; without it Docker looks for a file literally named
`Dockerfile`. The `.` is the build context, the directory whose contents get
sent to the daemon and are available to `COPY`.

## Size comparison

```bash
docker images | grep demo
```

```
demo:bad    d41f136debe4    1.63GB
demo:good   190acf97fadb     213MB
```

Roughly an 8x difference, from the slim base image and from multi-stage
building so the build tooling never lands in the final image.

## Vulnerability scanning

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image --severity HIGH,CRITICAL demo:bad
```

Prints a very long list of CVEs.

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy image --severity HIGH,CRITICAL demo:good
```

Prints a much shorter one. Fewer packages means less to patch and less to
exploit.

- `--rm` deletes the container when it exits.
- `-v` is a volume mount; the colon separates the host path from where it
  appears inside the container.
- The Docker socket is mounted because the images live in the local Docker
  daemon's storage, which the Trivy container otherwise can't see. Worth
  noting this is a privileged act, anything that can reach the socket can
  effectively become root on the host. Fine locally; a finding on a shared
  build agent. In CI you'd scan from the registry instead and skip the socket
  entirely.

## Dockerfile linting

```bash
docker run --rm -i hadolint/hadolint < Dockerfile.bad
```

```
-:4 DL3042 warning: Avoid use of cache directory with pip.
Use `pip install --no-cache-dir <package>`
```

Without `--no-cache-dir`, the pip cache persists in the image layer, adding
size for no benefit.

`-i` keeps stdin open so the `<` redirect reaches hadolint inside the
container. Hadolint reads from stdin when given no filename, which is why the
output says `-:4` — stdin, line 4.

Note what hadolint *didn't* flag: running as root, copying the whole build
context, using the full base image. It's a recipe linter, not a hardening
auditor. Different tools cover different layers.

## SBOM

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  anchore/syft demo:good -o table
```

Generates a software bill of materials, an inventory of every package in the
image — output as a table. The point is answering "which of our images contain
package X?" without rebuilding everything to find out.

## Running it

```bash
docker run --rm -d -p 8000:8000 --name demo demo:good
curl localhost:8000/health
```

```
{"status":"ok"}
```

`-d` detaches so it runs in the background, `--name` saves looking up container
IDs, and `-p` forwards host port 8000 to the container's 8000.

## Verifying the hardening

```bash
docker exec demo whoami
```

```
app
```

The process is running as the non-root `app` user, as intended. `docker exec`
runs a command inside an already-running container.
