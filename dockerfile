FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Зависимости
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Код
COPY etl/ ./etl/
COPY ml/ ./ml/
COPY tests/ ./tests/

CMD ["python", "-m", "etl.run"]