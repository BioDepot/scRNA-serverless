FROM debian:latest as builder

# Install dependencies for downloading
RUN apt-get update && \
    apt-get install -y wget

# Download and extract Piscem binary
WORKDIR /usr/local/bin
RUN wget https://github.com/COMBINE-lab/piscem/releases/download/v0.10.3/piscem-x86_64-unknown-linux-gnu.tar.gz && \
    tar -xzf piscem-x86_64-unknown-linux-gnu.tar.gz && \
    mv piscem-x86_64-unknown-linux-gnu/piscem . && \
    chmod +x piscem

# Install runtime interface emulator for local execution
RUN wget https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/download/v1.21/aws-lambda-rie -O /usr/local/bin/aws-lambda-rie && \
    chmod +x /usr/local/bin/aws-lambda-rie

# Stage 2: Create the runtime image with Python base
FROM python:3.12-slim

# Set the working directory in the container
WORKDIR /var/task

# Copy Piscem executable from the builder stage
COPY --from=builder /usr/local/bin/piscem /var/task/piscem
COPY --from=builder /usr/local/bin/aws-lambda-rie /usr/local/bin/aws-lambda-rie

COPY credentials /root/.aws/credentials

# Copy the Python script into the container
COPY map.py /var/task/map.py

# Copy the reference files directory into the container
COPY index_output_transcriptome /var/task/index_output_transcriptome

# Ensure the Python script is executable
RUN chmod +x /var/task/map.py

# Install AWS SDK for Python (Boto3)
RUN pip install boto3

# Install AWS Lambda Runtime Interface Client (awslambdaric)
RUN pip install awslambdaric

COPY entry_script.sh /entry_script.sh
RUN chmod +x /entry_script.sh

# Set RUST_BACKTRACE environment variable
ENV RUST_BACKTRACE=1

# Set the entrypoint to the custom script
ENTRYPOINT [ "/entry_script.sh" ]

# Set the command to your Lambda handler function
CMD [ "map.handler" ]