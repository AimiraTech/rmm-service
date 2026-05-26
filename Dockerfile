FROM alpine:3.20
WORKDIR /app
COPY docker-compose.yml Makefile .env.example ./
COPY scripts/ ./scripts/
COPY deploy/ ./deploy/
COPY README.md ./
RUN chmod +x scripts/*.sh deploy/*.sh
