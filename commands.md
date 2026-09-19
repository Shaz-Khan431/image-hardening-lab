# This file shows the commands that we run to build the images from the 2 Dockerfiles for comparison
# and the commands to scan the images 

docker build -f Dockerfile.bad -t demo:bad .
docker build -t demo:good .
docker images | grep demo                      # compare sizes

demo:bad               d41f136debe4       1.63GB          407MB        
demo:good              190acf97fadb        213MB         45.7MB        


# Scanners 
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy image --severity HIGH,CRITICAL demo:bad

Prints a very very long list of CVEs


docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy image --severity HIGH,CRITICAL demo:good

Prints a much shorter list

# --rm deletes container when it exits
# -v is volume mount, colon separates the volume on my mac vs where it apears on the container
# Purpose for choosing the Docker socket is because the images live on my Docker daemon's local storage


docker run --rm -i hadolint/hadolint < Dockerfile.bad

-:4 DL3042 warning: Avoid use of cache directory with pip. Use `pip install --no-cache-dir <package>`

# -i keeps stdin open and wires it through to the container, to reach hadolint, redirecting to the needed file
# if -no-cache-dir flag is not added, the pip cache otherwise sits in the image adding size or no benefit


docker run --rm -v /var/run/docker.sock:/var/run/docker.sock anchore/syft demo:good -o table   # SBOM

# Generated the software bill of materials using anchor/syft and outputting it in table format

docker run --rm -d -p 8000:8000 --name demo demo:good

# run the good docker image, naming the container demo, -d to properly run in the background (detach)
# forwards anything on my local hitting port 8000 to the container's 8000 port on the good docker build, and running in the background


curl localhost:8000/health

{"status":"ok"}

# succesful response


docker exec demo whoami   # should not be root

app

# the process is running as the app user, as part of the hardening we implemented
# docker exec is just to execute commands from inside of running containers
