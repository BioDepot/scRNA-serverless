import subprocess
import os
import boto3
import json
import shutil
from s3transfer import S3Transfer, TransferConfig
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import urlparse

# AWS S3 buckets

S3_OUTPUT_BUCKET_NAME = os.getenv("S3_OUTPUT_BUCKET_NAME","")
S3_INPUT_BUCKET_NAME = os.getenv("S3_INPUT_BUCKET_NAME", "")
EXPECTED_INPUT_FILES_BUCKET = os.getenv("S3_INPUT_TXT_BUCKET_NAME", "")
S3_PREFIX = "piscem_output"

print(f"S3_OUTPUT_BUCKET_NAME : {S3_OUTPUT_BUCKET_NAME}")
print(f"S3_INPUT_BUCKET_NAME : {S3_INPUT_BUCKET_NAME}")
print(f"EXPECTED_INPUT_FILES_BUCKET : {EXPECTED_INPUT_FILES_BUCKET}")
s3_client = boto3.client('s3')

def download_files_from_input_txt(bucket, input_file_key, local_dir):
    os.makedirs(local_dir, exist_ok=True)
    transfer = S3Transfer(s3_client)
    downloaded_files = []

    # Download input.txt file
    input_file_local_path = os.path.join(local_dir, "input.txt")
    s3_client.download_file(bucket, input_file_key, input_file_local_path)

    # Read input.txt to get list of S3 keys for files to download
    with open(input_file_local_path, 'r') as f:
        s3_keys = f.read().splitlines()

    # Download each file listed in input.txt
    # Function to download a single file
    def download_file(s3_key, local_dir="/tmp"):
        """
        Downloads a file from S3 using only the S3 key (s3://bucket_name/object_key).
        Skips the download if the file already exists.
        """

        print(f"📥 Input S3 key: {s3_key}")

        # Parse S3 key to extract bucket and object key
        parsed_url = urlparse(s3_key)
        bucket_name = parsed_url.netloc  # Extracts the bucket name
        object_key = parsed_url.path.lstrip("/")  # Extracts the object key
        print(f"Bucket Name: {bucket_name}")
        print(f"Object Key: {object_key}")

        # Local path where the file will be downloaded
        local_file_path = os.path.join(local_dir, os.path.basename(object_key))

        # Skip if file already exists
        if os.path.exists(local_file_path):
            print(f"File {local_file_path} already exists, skipping download.")
            return local_file_path

        print(f"⬇️ Downloading {object_key} from {bucket_name} to {local_file_path}...")

        # Perform S3 download
        s3_client.download_file(bucket_name, object_key, local_file_path)

        print(f"Completed downloading {os.path.basename(object_key)}.")
        return local_file_path

    with ThreadPoolExecutor() as executor:
        futures = [executor.submit(download_file, s3_key) for s3_key in s3_keys]
        for future in as_completed(futures):
            result = future.result()
            if result:
                downloaded_files.append(result)

    return downloaded_files


def run_piscem(files_r1, files_r2, input_folder):
    home_dir = "/var/task"
    output_dir = "/tmp/output"
    os.makedirs(output_dir, exist_ok=True)

    command = [
        "/var/task/piscem", "map-sc",
        "-i", f"{home_dir}/index_output_transcriptome/index_output_transcriptome",
        "-g", "chromium_v3",
        "-1", ",".join(files_r1),
        "-2", ",".join(files_r2),
        "-t", "6",
        "-o", f"{output_dir}/split_map_output_transcriptome"
    ]

    try:
        print("Running command")
        print(f"{command}")
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode != 0:
            print("Error:", result.stderr)
            return

        print("Command completed successfully")
        print(f"uploading output files to folder {input_folder}")
        upload_files_with_completion_marker(output_dir, input_folder, S3_OUTPUT_BUCKET_NAME, S3_PREFIX)

    except Exception as e:
        print(f"Error running Piscem: {e}")


def upload_files_with_completion_marker(output_dir, output_folder, s3_bucket_name, s3_prefix):
    transfer = S3Transfer(s3_client)
    for root, _, files in os.walk(output_dir):
        for file in files:
            local_path = os.path.join(root, file)
            output_s3_key = os.path.join(s3_prefix, output_folder, file)
            print(f"s3 prefix is {s3_prefix}")
            print(f"output folder is {output_folder}")
            print(f"file is {file}")
            print(f"output s3 key is {output_s3_key}")
            transfer.upload_file(local_path, s3_bucket_name, output_s3_key)
            print(f"Uploaded {local_path} to S3://{s3_bucket_name}/{output_s3_key}")

    empty_file_path = os.path.join(output_dir, 'output.txt')
    with open(empty_file_path, 'w') as empty_file:
        empty_file.write('')
    empty_s3_key = os.path.join(s3_prefix, output_folder, 'output.txt')
    transfer.upload_file(empty_file_path, s3_bucket_name, empty_s3_key)
    os.remove(empty_file_path)


def handler(event, context):
    """
    AWS Lambda function to process S3 events received from EventBridge.
    It proceeds only if the uploaded file is in the specified bucket and ends with "_input.txt".
    """

    # Ensure /tmp is clean for processing
    tmp_dir = "/tmp"
    if os.path.exists(tmp_dir) and os.access(tmp_dir, os.W_OK):
        for item in os.listdir(tmp_dir):
            item_path = os.path.join(tmp_dir, item)
            try:
                if os.path.isfile(item_path) or os.path.islink(item_path):
                    os.remove(item_path)  # Remove files and symlinks
                elif os.path.isdir(item_path):
                    shutil.rmtree(item_path)  # Remove directories
            except Exception as e:
                print(f"Warning: Unable to delete {item_path} - {e}")

    print("🔹 Received Event from EventBridge:", json.dumps(event, indent=4))  # Debugging log

    # Extract S3 event details from EventBridge
    try:
        bucket = event['detail']['bucket']['name']
        input_file_key = event['detail']['object']['key']
    except KeyError as e:
        print(f"Missing expected key in event: {e}")
        return {'statusCode': 400, 'body': 'Invalid EventBridge event format'}

    print(f"Bucket: {bucket}")
    print(f"Input File Key: {input_file_key}")

    # Ensure the file is in the expected bucket and ends with "_input.txt"
    if bucket != EXPECTED_INPUT_FILES_BUCKET:
        print(f"Ignoring file: {input_file_key} (Uploaded to an unexpected bucket: {bucket})")
        return {'statusCode': 200, 'body': 'File is in a different bucket, skipping processing'}

    if not input_file_key.endswith("_input.txt"):
        print(f"Ignoring file: {input_file_key} (Does not match '_input.txt')")
        return {'statusCode': 200, 'body': 'File does not match required pattern, skipping processing'}

    # Extracting final folder name from the input file key
    final_folder_name = input_file_key.rsplit("_input.txt", 1)[0]
    final_folder_name = os.path.basename(final_folder_name)

    print("Processing File:", input_file_key)
    print("Extracted Folder Name:", final_folder_name)

    # Create a local temp directory to store the downloaded file
    local_dir = "/tmp/input_files"
    os.makedirs(local_dir, exist_ok=True)

    # function for downloading files
    downloaded_files = download_files_from_input_txt(bucket, input_file_key, local_dir)

    # Separate R1 and R2 files
    files_r1 = [f for f in downloaded_files if "_R1_" in f]
    files_r2 = [f for f in downloaded_files if "_R2_" in f]

    # Validate if both R1 and R2 files exist
    if not files_r1 or not files_r2:
        print("Missing R1 or R2 files")
        return {
            'statusCode': 400,
            'body': 'Missing R1 or R2 files!'
        }

    # Run Piscem processing
    run_piscem(files_r1, files_r2, final_folder_name)

    return {
        'statusCode': 200,
        'body': 'Piscem map is successful'
    }


# **Testing the Function with an EventBridge Event Format**
if __name__ == "__main__":
    event = {
        "version": "0",
        "id": "abcdefg-1234",
        "detail-type": "AWS API Call via CloudTrail",
        "source": "aws.s3",
        "account": "123456789012",
        "time": "2024-02-19T10:00:00Z",
        "region": "us-west-2",
        "resources": [],
        "detail": {
            "eventSource": "s3.amazonaws.com",
            "eventName": "PutObject",
            "requestParameters": {
                "bucketName": "your-input-bucket-name",
                "key": "dataset_L001_sample_input.txt"
            }
        }
    }

    print(handler(event, None))
