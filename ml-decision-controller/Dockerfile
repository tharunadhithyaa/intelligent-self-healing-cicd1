FROM python:3.12-slim AS builder

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libc-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim AS runner

WORKDIR /app

COPY --from=builder /install /usr/local
COPY app/ /app/app/

RUN addgroup --gid 10001 appgroup && \
    adduser --uid 10001 --ingroup appgroup --disabled-password --gecos "" appuser && \
    chown -R appuser:appgroup /app

USER appuser

EXPOSE 5000

ENV PYTHONUNBUFFERED=1 \
    PORT=5000

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "5000"]
