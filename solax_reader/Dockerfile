FROM alpine:3.20

RUN apk add --no-cache bash curl jq postgresql-client

WORKDIR /app
COPY src/reader.sh /app/reader.sh
RUN chmod +x /app/reader.sh

# Invoke through bash so development bind mounts do not depend on the host
# executable bit of reader.sh.
CMD ["bash", "/app/reader.sh"]
