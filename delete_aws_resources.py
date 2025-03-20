import boto3
import argparse
import time
from botocore.exceptions import ClientError
from concurrent.futures import ThreadPoolExecutor

def bulk_delete_objects(s3_client, bucket_name, objects):
    """Helper function to delete up to 1000 objects at once."""
    try:
        s3_client.delete_objects(Bucket=bucket_name, Delete={'Objects': objects})
        print(f"Deleted {len(objects)} objects from {bucket_name}")
    except ClientError as e:
        print(f"Error deleting objects from {bucket_name}: {e}")

def delete_s3_bucket(bucket_name, aws_region, max_workers=10):
    """Delete all objects in an S3 bucket using bulk delete and multithreading, and then delete the bucket itself."""
    s3 = boto3.client('s3', region_name=aws_region)

    try:
        print(f"Deleting all objects in bucket: {bucket_name}...")

        # List all objects in the bucket
        response = s3.list_objects_v2(Bucket=bucket_name)
        i = 1

        while 'Contents' in response:
            objects_to_delete = [{'Key': obj['Key']} for obj in response['Contents']]

            # Split objects into chunks of 1000, since S3 DeleteObjects API can delete up to 1000 objects at once
            chunks = [objects_to_delete[x:x + 1000] for x in range(0, len(objects_to_delete), 1000)]

            # Use multithreading to delete chunks concurrently
            with ThreadPoolExecutor(max_workers=max_workers) as executor:
                for chunk in chunks:
                    executor.submit(bulk_delete_objects, s3, bucket_name, chunk)

            time.sleep(5)

            if response.get('IsTruncated'):
                print(f"Continuation token exists, calling {i} time")
                i += 1
                response = s3.list_objects_v2(Bucket=bucket_name, ContinuationToken=response['NextContinuationToken'])
            else:
                break

        # Wait for a moment to ensure all deletions are processed
        time.sleep(5)

        # Delete the bucket itself
        s3.delete_bucket(Bucket=bucket_name)
        print(f"Deleted bucket: {bucket_name}")

    except ClientError as e:
        print(f"Error deleting bucket {bucket_name}: {e}")


def delete_lambda_function(function_name, aws_region):
    """Delete the specified Lambda function."""
    lambda_client = boto3.client('lambda', region_name=aws_region)

    try:
        lambda_client.delete_function(FunctionName=function_name)
        print(f"Deleted Lambda function: {function_name}")

    except ClientError as e:
        print(f"Error deleting Lambda function {function_name}: {e}")

def delete_ecr_repository(repository_name, aws_region):
    """Delete the specified ECR repository."""
    ecr_client = boto3.client('ecr', region_name=aws_region)

    try:
        ecr_client.delete_repository(repositoryName=repository_name, force=True)
        print(f"Deleted ECR repository: {repository_name}")

    except ClientError as e:
        print(f"Error deleting ECR repository {repository_name}: {e}")

def detach_policies_from_role(role_name, aws_region):
    """Detach all attached policies from the IAM role."""
    iam_client = boto3.client('iam', region_name=aws_region)

    try:
        # List all attached policies
        response = iam_client.list_attached_role_policies(RoleName=role_name)
        attached_policies = response['AttachedPolicies']

        for policy in attached_policies:
            iam_client.detach_role_policy(RoleName=role_name, PolicyArn=policy['PolicyArn'])
            print(f"Detached policy {policy['PolicyArn']} from role {role_name}")

    except ClientError as e:
        print(f"Error detaching policies from role {role_name}: {e}")

def delete_iam_role(role_name, aws_region):
    """Delete the specified IAM role."""
    iam_client = boto3.client('iam', region_name=aws_region)

    try:
        # Detach any attached policies
        detach_policies_from_role(role_name, aws_region)

        # Delete the role
        iam_client.delete_role(RoleName=role_name)
        print(f"Deleted IAM role: {role_name}")

    except ClientError as e:
        print(f"Error deleting IAM role {role_name}: {e}")


def delete_eventbridge_rule(rule_name, aws_region):
    """Deletes an EventBridge rule and its associated targets."""
    eventbridge_client = boto3.client('events', region_name=aws_region)

    try:
        # Remove all targets associated with the rule
        targets = eventbridge_client.list_targets_by_rule(Rule=rule_name)
        target_ids = [target['Id'] for target in targets.get('Targets', [])]

        if target_ids:
            eventbridge_client.remove_targets(Rule=rule_name, Ids=target_ids)
            print(f"Removed {len(target_ids)} targets from rule: {rule_name}")

        # Delete the rule
        eventbridge_client.delete_rule(Name=rule_name, Force=True)
        print(f"Deleted EventBridge rule: {rule_name}")

    except ClientError as e:
        print(f"Error deleting EventBridge rule {rule_name}: {e}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Delete AWS resources: S3 buckets, Lambda function, and ECR repository.")
    parser.add_argument('--aws_region', required=True, help='AWS Region')
    parser.add_argument('--s3_output_bucket', required=True, help='Output S3 bucket name to delete')
    parser.add_argument('--s3_input_txt_bucket', required=True, help='Input txt S3 bucket name to delete')
    parser.add_argument('--lambda_execution_role_name', required=True, help='Lambda Execution Role Name')
    parser.add_argument('--lambda_function_name', required=True, help='Lambda function name to delete')
    parser.add_argument('--ecr_repository_name', required=True, help='ECR repository name to delete')

    args = parser.parse_args()

    # Delete S3 input and output buckets
    delete_s3_bucket(args.s3_output_bucket, args.aws_region)
    delete_s3_bucket(args.s3_input_txt_bucket, args.aws_region)

    # Delete Event Bridge Rule
    rule_name = f"{args.lambda_function_name}-rule"
    delete_eventbridge_rule(rule_name, args.aws_region)

    # Delete Lambda execution role
    delete_iam_role(args.lambda_execution_role_name, args.aws_region)

    # Delete Lambda function
    delete_lambda_function(args.lambda_function_name, args.aws_region)

    # Delete ECR repository
    delete_ecr_repository(args.ecr_repository_name, args.aws_region)