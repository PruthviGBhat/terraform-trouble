FROM python:3.12-slim

WORKDIR /app

# Install system dependencies (if needed by PyTorch or Transformers)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

# Install CPU-only torch FIRST from the PyTorch CPU index. Otherwise
# sentence-transformers pulls the full CUDA build (~9 GB of nvidia-* / cuda
# packages) producing a 12 GB image — useless on a CPU-only t3.medium and too
# large to push/pull. CPU torch keeps the image ~2.5 GB with no functional change.
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu && \
    pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application code
COPY . .

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
