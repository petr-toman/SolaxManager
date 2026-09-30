FROM alpine:3.22

RUN apk add --no-cache bash curl jq postgresql-client

WORKDIR /app
COPY src/reader.sh /app/reader.sh
RUN chmod +x /app/reader.sh

CMD ["bash", "/app/reader.sh"]
