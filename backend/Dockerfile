FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg unzip curl && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://github.com/denoland/deno/releases/latest/download/deno-x86_64-unknown-linux-gnu.zip -o /tmp/deno.zip \
    && unzip -o /tmp/deno.zip -d /usr/local/bin && rm /tmp/deno.zip \
    && chmod +x /usr/local/bin/deno
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
RUN mkdir -p /data/downloads
ENV OFFLINETUBE_DATA_DIR=/data
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]