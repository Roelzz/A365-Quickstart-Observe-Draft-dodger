# Python Sample Agent - Azure Container Apps Deployment
FROM python:3.12-slim

# Set working directory
WORKDIR /app

# Suppress apt-get warnings in Docker
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies (gcc needed for some Python packages)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Copy requirements first for caching
COPY requirements.txt .

# Upgrade pip and install Python dependencies (suppress root user warning)
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir --root-user-action=ignore -r requirements.txt

# Copy application code
COPY . .

# Expose port (Container Apps will route to this)
EXPOSE 3978

# Set environment variables
ENV PORT=3978
ENV PYTHONUNBUFFERED=1

# Health check (use 0.0.0.0 since we bind to all interfaces)
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3978/api/health')" || exit 1

# Run the agent
CMD ["python", "start_with_generic_host.py"]
