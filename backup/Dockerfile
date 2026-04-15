FROM aterfax/pbs-client:latest

# Install Docker CLI to trigger mailcow backup scripts
RUN apt-get update && apt-get install -y docker.io && rm -rf /var/lib/apt/lists/*

COPY hooks/pre.d/  /hooks/pre.d/
COPY hooks/post.d/ /hooks/post.d/

RUN chmod +x /hooks/pre.d/*.sh /hooks/post.d/*.sh