FROM python:3.13-alpine

WORKDIR /app
COPY src/controller.py /app/controller.py

# ENTRYPOINT keeps ad-hoc controller reads ergonomic:
#   docker compose run --rm controller get min_soc
# while the default command remains the long-running service.
ENTRYPOINT ["python", "-u", "/app/controller.py"]
CMD ["serve"]
