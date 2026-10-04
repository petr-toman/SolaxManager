FROM python:3.13-alpine

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY src/ /app/

# ENTRYPOINT keeps ad-hoc controller reads ergonomic while the default command
# starts the long-running REST controller service.
ENTRYPOINT ["python", "-u", "/app/controller.py"]
CMD ["serve"]
