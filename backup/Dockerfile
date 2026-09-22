FROM docker:cli AS docker-cli

FROM aterfax/pbs-client:latest

# Copy only the Docker CLI; the backup container uses the host Docker socket.
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker

COPY hooks/pre.d/  /hooks/pre.d/
COPY hooks/post.d/ /hooks/post.d/
COPY hooks/bin/    /hooks/bin/

RUN chmod +x /hooks/pre.d/*.sh /hooks/post.d/*.sh /hooks/bin/*.sh