import os
import argparse
import re
import boto3
import time
import multiprocessing
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from boto3.s3.transfer import TransferConfig
import subprocess

# Constants
NUM_THREADS = 20
S3_CONFIG = TransferConfig(multipart_threshold=5 * 1024**2, max_concurrency=32)


# Download File from S3
def download_file(bucket_name, s3_key, local_path):
    """Download file from S3 using AWS CLI."""
    print(f"Downloading {s3_key} from S3...")
    result = os.system(f"aws s3 cp s3://{bucket_name}/{s3_key} {local_path} --only-show-errors")
    if result != 0:
        print(f"ERROR: Failed to download {s3_key}")
        return False
    print(f"Downloaded {s3_key} -> {local_path}")
    return True


def upload_file_to_s3(bucket_name, file_path, s3_key):
    try:
        print("creating S3 Client")
        s3_client = boto3.client('s3', region_name="us-east-2")
        print(f"uploading file at {s3_key}")
        s3_client.upload_file(file_path, bucket_name, s3_key, Config=S3_CONFIG)

        # Verify if the upload succeeded
        response = s3_client.head_object(Bucket=bucket_name, Key=s3_key)
        if response['ContentLength'] == os.path.getsize(file_path):
            print(f"Successfully uploaded {file_path} to s3://{bucket_name}/{s3_key}")
        else:
            print(f"Upload may be incomplete: {file_path}")

    except Exception as e:
        print(f"Failed to upload {file_path}: {e}")


def split_and_upload(bucket_name, r1_file, r2_file, basename_with_lane, input_txt_bucket_name):
    """
    Calls the `split_and_upload.sh` shell script and returns the number of parts.
    """
    print(f"Running split_and_upload for {r1_file} and {r2_file}")
    print(f"R1 File: {r1_file}")
    print(f"R2 File: {r2_file}")
    print(f"Bucket Name: {bucket_name}")
    print(f"Basename with Lane: {basename_with_lane}")
    print(f"Input txt bucket Name: {input_txt_bucket_name}")
    start_time = datetime.now()

    try:
        # Call the Bash script and capture output
        result = subprocess.run(
            ["bash", "split_and_upload.sh", bucket_name, r1_file, r2_file, basename_with_lane, input_txt_bucket_name],
            capture_output=True, text=True, check=True
        )

        # Extract the last line from the output (PAIR_COUNT)
        output_lines = result.stdout.strip().split("\n")
        # Get last line where PAIR_COUNT is echoed
        num_parts = int(output_lines[-1])

        # Compute total execution time
        time_taken = (datetime.now() - start_time).total_seconds() / 60
        print(f"Process completed in {time_taken:.2f} minutes for {basename_with_lane}. Parts created: {num_parts}")

        # Return number of parts split
        return num_parts

    except subprocess.CalledProcessError as e:
        print(f"ERROR: Splitting failed for {r1_file}: {e}")
        return -1


def upload_input_files(file_pairs, input_folders):
    # Print each pair found and write to input file
    s3_client = boto3.client('s3', region_name=region)

    future_to_file = {}
    with ThreadPoolExecutor(max_workers=NUM_THREADS) as executor:
        for base_name_with_lane, files in file_pairs.items():
            if 'R1' in files and 'R2' in files:

                # Split base_name_with_lane into folder path and lane identifier
                base_folder, lane_identifier = os.path.split(base_name_with_lane)

                # If no '/' in base_name_with_lane, set lane_identifier as base_name_with_lane
                if not base_folder:
                    lane_identifier = base_name_with_lane

                r1_file = files['R1']
                r2_file = files['R2']
                print(f"Pair found in {base_name_with_lane}:\n  R1: {r1_file}\n  R2: {r2_file}\n")

                # Full S3 path to each file
                bucket_path_r1 = f"s3://{bucket_name}/{r1_file}"
                bucket_path_r2 = f"s3://{bucket_name}/{r2_file}"
                print(f"R1 file path is: {bucket_path_r1}")
                print(f"R2 file path is: {bucket_path_r2}")

                r1_file_size = get_s3_file_size_in_gb(s3_client, r1_file)
                r2_file_size = get_s3_file_size_in_gb(s3_client, r2_file)
                combined_size = r1_file_size + r2_file_size
                print(f"combined size of file pairs in GB: {combined_size:.2f}")

                if combined_size < 7:
                    # Create input.txt file in memory
                    print("File pairs size < 7GB → Uploading directly")
                    time.sleep(3)
                    create_and_upload_input_file(lane_identifier, bucket_path_r1, bucket_path_r2, base_folder, input_folders)
                else:
                    print(f"Queuing split_and_upload for {r1_file} and {r2_file}")
                    # Submit to ThreadPoolExecutor
                    future = executor.submit(
                        split_and_upload, bucket_name, r1_file, r2_file, base_name_with_lane, input_txt_bucket_name
                    )
                    future_to_file[future] = lane_identifier

    # Process completed futures
    for future in as_completed(future_to_file):
        lane_identifier = future_to_file[future]
        try:
            num_parts = future.result()
            if num_parts >= 0:
                print(f"Process completed for {lane_identifier}. Total parts created: {num_parts}")

                # Append p{idx} to input folders
                for idx in range(0, num_parts):
                    input_folder = f"{lane_identifier}_p{idx}"
                    input_folders.add(input_folder)
                    print(f"Added input folder: {input_folder}")

            else:
                print(f"ERROR: Splitting failed for {lane_identifier}")

        except Exception as e:
            print(f"ERROR processing {lane_identifier}: {str(e)}")
    print("All input files processed. Starting polling for outputs.")


def create_and_upload_input_file(lane_identifier, bucket_path_r1, bucket_path_r2, base_folder, input_folders):
    input_file_path = f"{lane_identifier}_p0_input.txt"

    print(f"writing to input file {input_file_path}")
    print(f"{bucket_path_r1}")
    print(f"{bucket_path_r2}")
    with open(input_file_path, 'w') as f:
        f.write(f"{bucket_path_r1}\n")
        f.write(f"{bucket_path_r2}\n")
    print(f"Wrote input file to {input_file_path}")

    # Upload R1, R2, and input.txt files to S3
    output_path = os.path.join(base_folder,input_file_path)
    print(f"output path is {output_path}")
    upload_file_to_s3(input_txt_bucket_name, input_file_path, output_path)
    os.remove(input_file_path)
    input_folders.add(f"{lane_identifier}_p0")
    print(f"added {len(input_folders)} input files to S3 in bucket {input_txt_bucket_name}")
    print(f"adding {lane_identifier}_p0 to input_folders")


def find_pairs_from_s3():
    # Dictionary to store R1 and R2 file pairs organized by base name and lane
    file_pairs = {}
    s3_client = boto3.client('s3', region_name=region)

    # Pagination logic to fetch all objects
    paginator = s3_client.get_paginator('list_objects_v2')
    operation_parameters = {'Bucket': bucket_name}

    for page in paginator.paginate(**operation_parameters):
        if 'Contents' in page:
            for obj in page['Contents']:
                file_name = obj['Key']
                if not file_name.endswith('.fastq.gz') or '_I1_' in file_name or '_I2_' in file_name:
                    continue  # Ignore files without .fastq or with _I1_/_I2_

                # Regex pattern to match files with _Lxxx_ (lane) and _R1_/_R2_

                pattern = re.compile(r'(.+_L\d{3})_(R[12])_\d{3}(_p\d+)?\.fastq\.gz$')
                match = pattern.match(file_name)

                if match:
                    base_name_with_lane, read_type, p_suffix = match.groups()
                    key = f"{base_name_with_lane}"
                    if key not in file_pairs:
                        file_pairs[key] = {}
                    file_pairs[key][read_type] = file_name
    return file_pairs


def get_s3_file_size_in_gb(s3_client, s3_key):
    response = s3_client.head_object(Bucket=bucket_name, Key=s3_key)
    file_size_bytes = response['ContentLength']
    # Convert bytes to GB
    file_size_gb = file_size_bytes / (1024 ** 3)
    return file_size_gb


def poll_output_bucket(output_bucket_name, output_dir, polling_interval, start_time):
    s3 = boto3.client('s3', region_name=region)
    output_folders = set()
    input_folder_count = len(input_folders)
    print(f"input folder count is: {input_folder_count}")

    while len(output_folders) < input_folder_count:
        print(f"Polling bucket {output_bucket_name} for output folders...")

        continuation_token = None

        # Loop to handle paginated S3 responses
        while True:
            list_kwargs = {
                'Bucket': output_bucket_name,
                'Prefix': "piscem_output/",
                'MaxKeys': 1000
            }
            if continuation_token:
                list_kwargs['ContinuationToken'] = continuation_token
                print(f"Using continuation token: {continuation_token}")

            response = s3.list_objects_v2(**list_kwargs)

            if 'Contents' in response:
                for obj in response['Contents']:
                    key_parts = obj['Key'].split('/')

                    # Ensure the key format matches "piscem_output/{folder_name}/output.txt"
                    if len(key_parts) >= 3:
                        folder_name = key_parts[1]
                        file_name = key_parts[2]
                        # Check if folder_name is in input_folders and file is output.txt
                        if folder_name in input_folders and file_name == 'output.txt':
                            output_folders.add(folder_name)

            print(f"Found output for {len(output_folders)} out of {input_folder_count} input folders.")

            # Check if more results need to be fetched (pagination)
            if response.get('IsTruncated'):
                continuation_token = response['NextContinuationToken']
            else:
                break

        if len(output_folders) < input_folder_count:
            print(f"Retrying in {polling_interval} seconds...")
            time.sleep(polling_interval)

    print(f"All {len(output_folders)} output folders are generated")

    end_time = datetime.now()
    elapsed_time = (end_time - start_time).total_seconds() / 60
    print(f"Total time elapsed for running piscem map: {elapsed_time:.2f} minutes")

    download_start_time = datetime.now()
    download_output_files(output_bucket_name, output_folders, output_dir)
    download_end_time = datetime.now()
    duration = (download_end_time - download_start_time).total_seconds() /60
    print(f"Downloading output files completed in {duration:.2f} minutes")


def download_output_files(bucket_name, output_folders, output_dir):
    """Download all output files from S3 to the local directory using multithreading."""
    s3 = boto3.client('s3', region_name=region)

    with ThreadPoolExecutor() as executor:
        futures = []

        for folder_name in output_folders:
            print(f"Downloading files from {folder_name}...")

            # List files in the output folder
            response = s3.list_objects_v2(Bucket=bucket_name, Prefix=f"piscem_output/{folder_name}/")
            if 'Contents' in response:
                for obj in response['Contents']:
                    file_key = obj['Key']
                    local_file_path = os.path.join(output_dir, file_key)

                    # Ensure the local directory exists
                    local_dir = os.path.dirname(local_file_path)
                    if not os.path.exists(local_dir):
                        os.makedirs(local_dir)

                    # Submit a download task to the executor
                    futures.append(executor.submit(download_file, bucket_name, file_key, local_file_path))

        # Wait for all downloads to complete and handle any exceptions
        for future in as_completed(futures):
            try:
                future.result()
            except Exception as e:
                print(f"An error occurred: {e}")


if __name__ == '__main__':
    # Command-line argument parser
    parser = argparse.ArgumentParser(description="Upload _input.txt files to S3 and poll for outputs.")
    parser.add_argument('--aws_region', required=True, help='AWS Region')
    parser.add_argument('--bucket_name', required=True, help='S3 bucket name for input files')
    parser.add_argument('--s3_input_files_bucket_name', required=True, help='S3 Bucket Name to add input .txt files')
    parser.add_argument('--output_bucket_name', required=True, help='Output S3 bucket name')
    parser.add_argument('--output_dir', required=True, help='Local directory to save downloaded files')
    parser.add_argument('--polling_interval', type=int, default=30, help='Polling interval in seconds')

    multiprocessing.set_start_method("spawn")
    processing_start_time = datetime.now()
    args = parser.parse_args()
    time.sleep(30)
    bucket_name = args.bucket_name
    input_txt_bucket_name = args.s3_input_files_bucket_name
    region = args.aws_region
    s3_file_pairs = find_pairs_from_s3()
    input_folders = set()
    time.sleep(30)
    upload_start_time = datetime.now()
    upload_input_files(s3_file_pairs, input_folders)
    upload_end_time = (datetime.now() - upload_start_time).total_seconds() / 60
    print(f"Total time taken to upload input files is {upload_end_time:.2f} minutes")

    start_time = datetime.now()
    # Start polling the output bucket once all input folders are uploaded
    poll_output_bucket(args.output_bucket_name, args.output_dir, args.polling_interval, start_time)
    processing_elapsed_time = (datetime.now() - processing_start_time).total_seconds() / 60
    print(f"Total time taken to process files is {processing_elapsed_time:.2f} minutes")
