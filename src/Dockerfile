FROM golang:1.24.4-alpine3.22 AS builder

WORKDIR /app

RUN wget -q -O ocb https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/cmd%2Fbuilder%2Fv0.129.0/ocb_0.129.0_linux_amd64 && \
    chmod +x ocb

COPY builder-config.yaml .

RUN CGO_ENABLED=0 ./ocb --config=builder-config.yaml

FROM gcr.io/distroless/static-debian12

COPY --from=builder --chown=nonroot:nonroot /app/_build/otelcol /otelcol
COPY collector-config.yaml /etc/otelcol/collector-config.yaml

USER nonroot

ENTRYPOINT ["/otelcol"]
CMD ["--config", "/etc/otelcol/collector-config.yaml"]
EXPOSE 4318
