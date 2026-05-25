FROM alpine:3.20
WORKDIR /app
COPY docker-compose.yml Makefile .env.example ./
COPY caddy/ ./caddy/
COPY crowdsec/ ./crowdsec/
COPY scripts/ ./scripts/
COPY README.md ./
RUN chmod +x scripts/*.sh
