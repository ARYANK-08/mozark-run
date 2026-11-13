FROM alpine:3.20
RUN apk add --no-cache bash curl jq python3 ca-certificates
COPY run.sh /usr/local/bin/mozark-run
COPY summary.py /usr/local/bin/summary.py
LABEL org.opencontainers.image.source="https://github.com/ARYANK-08/mozark-run" \
      org.opencontainers.image.description="Run a Mozark App Studio suite on real devices from any CI" \
      org.opencontainers.image.licenses="MIT"
CMD ["mozark-run"]
