import boto3
import argparse
import re

def delete_input_files(bucket_name):
    s3_client = boto3.client('s3')

    # Initialize paginator to handle large numbers of files
    paginator = s3_client.get_paginator('list_objects_v2')
    page_iterator = paginator.paginate(Bucket=bucket_name)

    # Track deleted file count
    deleted_files = 0

    # Regex pattern to match *_p<number>.fastq files
    fastq_pattern = re.compile(r'.*_p\d+.*\.fastq$')

    for page in page_iterator:
        if 'Contents' in page:
            # Collect objects matching the deletion patterns
            input_files = [
                {'Key': obj['Key']}
                for obj in page['Contents']
                if fastq_pattern.match(obj['Key'])
            ]

            if input_files:
                # Delete the files in batches
                response = s3_client.delete_objects(
                    Bucket=bucket_name,
                    Delete={'Objects': input_files}
                )
                # Count deleted files
                deleted_files += len(response.get('Deleted', []))
                print(f"Deleted {len(response.get('Deleted', []))} files in this batch")

    print(f"Total *_input.txt and *_p<number>.fastq files deleted from bucket '{bucket_name}': {deleted_files}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Delete specific files from an S3 bucket.")
    parser.add_argument("bucket_name", help="Name of the S3 bucket")
    args = parser.parse_args()

    delete_input_files(args.bucket_name)
