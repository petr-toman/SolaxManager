FROM python:3.13-alpine

RUN pip install --no-cache-dir "psycopg[binary]>=3.2,<3.3"

WORKDIR /app
COPY src/reporter.py /app/reporter.py

CMD ["python", "-u", "/app/reporter.py"]
