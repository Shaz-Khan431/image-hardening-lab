# build stage
FROM python:3.12-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# runtime stage
FROM python:3.12-slim
RUN groupadd -r app && useradd -r -g app -u 10001 app
WORKDIR /app
COPY --from=builder /install /usr/local
COPY --chown=app:app app.py .
USER 10001
EXPOSE 8000
HEALTHCHECK CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"
CMD ["gunicorn", "-b", "0.0.0.0:8000", "0.0.0.0:8000", "--worker-tmp-dir", "/dev/shm", "app:app"]

# Starts the stage from a slim image, and names it builder so a later stage can copy from it
# sets working directory, copies the requirements
# installing dependencies, --no-cache-dir stops pip from keeping downloaded wheels
# --prefix=/install installs the packages into /install instead of system location

# runtime stage, starts the FROM fresh, so nothing from builder carries over
# then creates a group and a user, -r marks them as system accounts, -g app puts the user in that group
# -u 10001 app fixes the numeric UID
# then pull /install from the builder stage, and puts it in /usr/local, which is already on Python's import path,
# so Flask and gunicorn are importable, only installed libraries come across
# Then COPY just the application file, not the whole directory, so nothing stray is picked up
# --chown sets ownership at copy time, avoiding a separate RUN chown that would add another layer
# app:app is from the user and group we created earlier so user:group
# everything after USER 10001 runs as the unpriviledged user. 
# High value hardening so if someon exploits the app, the land as UID 10001, with no ability to install packages
# or write to system paths. Note it's placed after the RUN and COPY steps, since those need root. 
# EXPOSE 8000 is just documentation, doesnt really do anything
# Docker runs HEALTHCHECK periodically inside the container. Exit 0 means healthy, non-zero means unhealthy
# docker ps shows the status. Using Python rather than curl avoids installing curl just for this, keeping package
# count down, and it hits the /healt endpoint from the app. 
# CMD is for the production WSGI server instead of Flask's dev server, bound to all interfaces on 8000
# exec form so gunicorn is PID 1 and handles SIGTERM properly
# the -b is what tells the kernel to listen on port 8000
# the app:app has to do with the app.py, so it's actually module:variable since we happened to name the variable and module app