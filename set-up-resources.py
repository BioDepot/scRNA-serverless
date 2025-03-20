import boto3
import subprocess
import os
import time
import argparse
from botocore.exceptions import ClientError
import json


def create_ecr_repo(ecr_repo_name, aws_region, aws_account_id):
    try:
        ecr_client = boto3.client('ecr', region_name=aws_region)
        response = ecr_client.create_repository(
            repositoryName=ecr_repo_name,
            imageScanningConfiguration={'scanOnPush': True}
        )
        print(f"ECR repository {ecr_repo_name} created.")
        return response['repository']['repositoryUri']
    except ecr_client.exceptions.RepositoryAlreadyExistsException:
        print(f"ECR repository {ecr_repo_name} already exists.")
        return f"{aws_account_id}.dkr.ecr.{aws_region}.amazonaws.com/{ecr_repo_name}"


def build_and_push_docker_image(ecr_repo_uri, docker_image_name, dockerfile_dir, aws_account_id, aws_region):
    subprocess.run(["docker", "build", "--platform", "linux/amd64", "-t", docker_image_name, "."], cwd=dockerfile_dir)
    docker_tag = f"{ecr_repo_uri}:{docker_image_name}"
    subprocess.run(["docker", "tag", docker_image_name, docker_tag])

    login_command = subprocess.run(
        ["aws", "ecr", "get-login-password", "--region", aws_region],
        stdout=subprocess.PIPE
    )
    subprocess.run(
        ["docker", "login", "--username", "AWS", "--password-stdin", f"{aws_account_id}.dkr.ecr.{aws_region}.amazonaws.com"],
        input=login_command.stdout
    )
    subprocess.run(["docker", "push", docker_tag])
    print(f"Docker image pushed to {docker_tag}")
    return docker_tag


def create_lambda_execution_role(role_name, aws_region):
    """Create an IAM role for Lambda function execution."""
    iam_client = boto3.client('iam', region_name=aws_region)

    try:
        # Check if the role already exists
        existing_role = iam_client.get_role(RoleName=role_name)
        print(f"Role '{role_name}' already exists.")
        return existing_role['Role']['Arn']

    except ClientError as e:
        if e.response['Error']['Code'] == 'NoSuchEntity':
            # If the role does not exist, create a new one
            assume_role_policy_document = {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Principal": {
                            "Service": ["lambda.amazonaws.com", "events.amazonaws.com"]
                        },
                        "Action": "sts:AssumeRole"
                    }
                ]
            }
            response = iam_client.create_role(
                RoleName=role_name,
                AssumeRolePolicyDocument=json.dumps(assume_role_policy_document),
                Description="Role for Lambda execution, allowing EventBridge to trigger it."
            )
            role_arn = response['Role']['Arn']
            print(f"Created role '{role_name}' with ARN: {role_arn}")
            return role_arn
        else:
            print(f"Error retrieving role: {e}")
            raise e


def attach_policies(role_name, aws_region, max_retries=5, retry_delay=5):
    iam_client = boto3.client('iam', region_name=aws_region)
    policies = [
        'arn:aws:iam::aws:policy/AmazonS3FullAccess',
        'arn:aws:iam::aws:policy/service-role/AmazonS3ObjectLambdaExecutionRolePolicy',
        'arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess'
    ]

    for policy_arn in policies:
        for attempt in range(max_retries):
            try:
                iam_client.attach_role_policy(RoleName=role_name, PolicyArn=policy_arn)
                print(f"Attached policy {policy_arn} to role {role_name}")
                break
            except ClientError as e:
                print(f"Error attaching policy {policy_arn} to role {role_name} (attempt {attempt + 1}/{max_retries}): {e}")
                if attempt < max_retries - 1:
                    time.sleep(retry_delay)
                    retry_delay *= 2  # Exponential backoff
                else:
                    print(f"Failed to attach policy {policy_arn} after {max_retries} attempts.")
                    raise


def create_lambda_function(lambda_function_name, lambda_execution_role, image_uri, aws_region,
                           s3_output_bucket, s3_input_bucket, s3_input_txt_bucket, max_retries=5, retry_delay=5):
    lambda_client = boto3.client('lambda', region_name=aws_region)
    print(f"Lambda execution role ARN: {lambda_execution_role}")

    for attempt in range(max_retries):
        try:
            response = lambda_client.create_function(
                FunctionName=lambda_function_name,
                Role=lambda_execution_role,
                Code={'ImageUri': image_uri},
                PackageType='Image',
                MemorySize=10240,  # 10 GB
                EphemeralStorage={'Size': 10240},  # 10 GB
                Timeout=900,  # 15 minutes
                Architectures=['x86_64'],
                Environment={
                    "Variables": {
                        "S3_OUTPUT_BUCKET_NAME": s3_output_bucket,
                        "S3_INPUT_BUCKET_NAME": s3_input_bucket,
                        "S3_INPUT_TXT_BUCKET_NAME": s3_input_txt_bucket
                    }
                }
            )
            print(f"Lambda function {lambda_function_name} created.")
            return response['FunctionArn']
        except lambda_client.exceptions.ResourceConflictException:
            print(f"Lambda function {lambda_function_name} already exists.")
            existing_function = lambda_client.get_function(FunctionName=lambda_function_name)
            return existing_function['Configuration']['FunctionArn']
        except ClientError as e:
            print(f"Error creating Lambda function (attempt {attempt + 1}/{max_retries}): {e}")
            if attempt < max_retries - 1:
                time.sleep(retry_delay)
                retry_delay *= 2  # Exponential backoff
            else:
                print(f"Failed to create Lambda function after {max_retries} attempts.")
                raise


def create_s3_bucket(bucket_name, aws_region):
    s3_client = boto3.client('s3', region_name=aws_region)
    try:
        s3_client.create_bucket(Bucket=bucket_name, CreateBucketConfiguration={'LocationConstraint': aws_region})
        print(f"Bucket '{bucket_name}' created.")
    except s3_client.exceptions.BucketAlreadyOwnedByYou:
        print(f"Bucket '{bucket_name}' already exists and owned by you.")
    except Exception as e:
        print(f"Error creating bucket: {e}")


def create_eventbridge_rule(rule_name, s3_bucket_name, aws_region):
    client = boto3.client('events', region_name=aws_region)

    # Event pattern to filter only for files ending with "_input.txt"
    event_pattern = {
        "source": ["aws.s3"],
        "detail-type": ["Object Created"],
        "detail": {
            "bucket": {
                "name": [s3_bucket_name]
            }
        }
    }

    response = client.put_rule(
        Name=rule_name,
        EventPattern=json.dumps(event_pattern),
        State="ENABLED"
    )
    print(f"EventBridge Rule '{rule_name}' created.")
    return response['RuleArn']


def add_lambda_target_to_eventbridge(rule_name, lambda_function_arn, aws_region):
    client = boto3.client('events', region_name=aws_region)

    response = client.put_targets(
        Rule=rule_name,
        Targets=[
            {
                "Id": "LambdaTarget",
                "Arn": lambda_function_arn
            }
        ]
    )
    print(f"Lambda function added as a target to EventBridge Rule '{rule_name}'.")


def add_lambda_invocation_permission(lambda_function_name, aws_region, max_retries=10, retry_delay=5):
    """
    Grants EventBridge permission to invoke the Lambda function.
    Adds retry logic to wait for Lambda to be available before granting permission.
    """
    lambda_client = boto3.client('lambda', region_name=aws_region)
    events_client = boto3.client('events', region_name=aws_region)

    statement_id = f"EventBridgeInvoke-{lambda_function_name}"

    # Correct SourceArn Format
    account_id = boto3.client("sts").get_caller_identity()["Account"]
    source_arn = f"arn:aws:events:{aws_region}:{account_id}:rule/{lambda_function_name}-rule"

    for attempt in range(1, max_retries + 1):
        try:
            # Check if Lambda exists before adding permission
            lambda_client.get_function(FunctionName=lambda_function_name)

            # Check if the EventBridge rule exists
            rules = events_client.list_rules(NamePrefix=lambda_function_name)
            if not any(rule['Arn'] == source_arn for rule in rules['Rules']):
                print(f"EventBridge Rule '{lambda_function_name}-rule' not found. Retrying...")
                time.sleep(retry_delay)
                continue  # Retry if rule isn't available

            # Add permission to allow EventBridge to invoke Lambda
            lambda_client.add_permission(
                FunctionName=lambda_function_name,
                StatementId=statement_id,
                Action="lambda:InvokeFunction",
                Principal="events.amazonaws.com",
                SourceArn=source_arn
            )
            print(f"Permission granted for EventBridge to invoke '{lambda_function_name}'.")
            return True

        except ClientError as e:
            error_code = e.response["Error"]["Code"]

            if error_code == "ResourceNotFoundException":
                print(f"Lambda '{lambda_function_name}' not found yet. Retrying in {retry_delay} seconds...")
            elif error_code == "ValidationException":
                print(f"Validation issue: {e}. Retrying...")
            elif error_code == "ResourceConflictException":
                print(f"Permission already exists for EventBridge to invoke Lambda '{lambda_function_name}'.")
                return True  # No need to retry if permission already exists
            else:
                print(f"Error granting permission: {e}")
                return False  # Stop retrying for unexpected errors

        time.sleep(retry_delay)
        retry_delay *= 2  # Exponential backoff

    print(f"Failed to grant EventBridge permission after {max_retries} retries.")
    return False


def verify_lambda_eventbridge_permission(lambda_function_name, aws_region):
    lambda_client = boto3.client('lambda', region_name=aws_region)

    try:
        response = lambda_client.get_policy(FunctionName=lambda_function_name)
        policy = json.loads(response['Policy'])

        for statement in policy["Statement"]:
            if statement["Principal"].get("Service") == "events.amazonaws.com":
                print(f"EventBridge is allowed to invoke Lambda '{lambda_function_name}'.")
                return True

        print(f"EventBridge does NOT have permission to invoke Lambda '{lambda_function_name}'.")
        return False

    except lambda_client.exceptions.ResourceNotFoundException:
        print(f"Lambda function '{lambda_function_name}' not found.")
        return False

    except ClientError as e:
        print(f"Error checking Lambda policy: {e}")
        return False


def enable_eventbridge_notifications(bucket_name, max_retries=10, retry_delay=5):
    """
    Enables Amazon EventBridge notifications for an S3 bucket and verifies activation with retries.
    Returns True if EventBridge is confirmed active, False otherwise.
    """
    s3_client = boto3.client('s3')

    try:
        # Enable EventBridge notifications on the bucket
        s3_client.put_bucket_notification_configuration(
            Bucket=bucket_name,
            NotificationConfiguration={"EventBridgeConfiguration": {}}
        )
        print(f"EventBridge notifications ENABLED for bucket '{bucket_name}'.")

        # Retry logic to verify activation
        for attempt in range(1, max_retries + 1):
            try:
                config = s3_client.get_bucket_notification_configuration(Bucket=bucket_name)

                # Check if EventBridge is enabled
                if "EventBridgeConfiguration" in config:
                    print(f"EventBridge is ACTIVE for bucket '{bucket_name}' (Attempt {attempt}/{max_retries}).")
                    return True

                print(f"Waiting for EventBridge activation... (Attempt {attempt}/{max_retries})")
                time.sleep(retry_delay)
                retry_delay *= 2  # Exponential backoff

            except Exception as e:
                print(f"Error checking EventBridge status: {e} (Attempt {attempt}/{max_retries})")
                time.sleep(retry_delay)
                retry_delay *= 2  # Exponential backoff

        print(f"EventBridge was NOT activated after {max_retries} attempts.")
        return False

    except Exception as e:
        print(f"Error enabling EventBridge notifications: {e}")
        return False


def verify_eventbridge_rule(rule_name, lambda_function_arn, aws_region, max_retries=5, retry_delay=5):
    """
    Verify if the EventBridge rule is active and Lambda function is attached.
    """
    client = boto3.client('events', region_name=aws_region)

    for attempt in range(max_retries):
        try:
            # Check if rule is active
            rule_state = client.describe_rule(Name=rule_name)['State']
            if rule_state != "ENABLED":
                print(f"Waiting for EventBridge rule '{rule_name}' to be enabled (Attempt {attempt+1}/{max_retries})...")
                time.sleep(retry_delay)
                continue

            # Check if Lambda function is attached as a target
            targets = client.list_targets_by_rule(Rule=rule_name)['Targets']
            if any(target['Arn'] == lambda_function_arn for target in targets):
                print(f"EventBridge rule '{rule_name}' is ACTIVE and correctly attached to Lambda.")
                return True

        except Exception as e:
            print(f"Error verifying EventBridge rule: {e}")

        time.sleep(retry_delay)

    print(f"EventBridge rule '{rule_name}' did not fully configure after {max_retries} retries.")
    return False


def main():
    # Parse command line arguments
    parser = argparse.ArgumentParser(description='Set up AWS resources for serverless pipeline.')
    parser.add_argument('--aws_region', required=True, help='AWS Region')
    parser.add_argument('--aws_account_id', required=True, help='AWS Account ID')
    parser.add_argument('--ecr_repo_name', required=True, help='ECR Repository Name')
    parser.add_argument('--docker_image_name', required=True, help='Docker Image Name')
    parser.add_argument('--lambda_function_name', required=True, help='Lambda Function Name')
    parser.add_argument('--lambda_execution_role_name', required=True, help='Lambda Execution Role Name')
    parser.add_argument('--s3_bucket_name', required=True, help='S3 Input Bucket Name')
    parser.add_argument('--s3_input_files_bucket_name', required=True, help='S3 Bucket Name to add input .txt files')
    parser.add_argument('--s3_output_bucket_name', required=True, help='S3 Output Bucket Name')
    parser.add_argument('--final_output_bucket_name', required=True, help='Final Output Bucket Name')
    parser.add_argument('--dockerfile_dir', required=True, help='Dockerfile Directory')

    args = parser.parse_args()

    # Create ECR Repository
    ecr_repo_uri = create_ecr_repo(args.ecr_repo_name, args.aws_region, args.aws_account_id)

    # Build Docker image and push to ECR Repository
    image_uri = build_and_push_docker_image(ecr_repo_uri, args.docker_image_name, args.dockerfile_dir, args.aws_account_id, args.aws_region)

    # Create Lambda execution role
    lambda_execution_role = create_lambda_execution_role(args.lambda_execution_role_name, args.aws_region)

    # Step 2: Attach necessary policies
    attach_policies(args.lambda_execution_role_name, args.aws_region)

    # Create Lambda function
    lambda_function_arn = create_lambda_function(args.lambda_function_name, lambda_execution_role, image_uri, args.aws_region, args.s3_output_bucket_name, args.s3_bucket_name, args.s3_input_files_bucket_name)

    # Create S3 output bucket
    create_s3_bucket(args.s3_output_bucket_name, args.aws_region)
    create_s3_bucket(args.s3_input_files_bucket_name, args.aws_region)
    create_s3_bucket(args.final_output_bucket_name, args.aws_region)
    enable_eventbridge_notifications(args.s3_input_files_bucket_name)

    # Step 1: Create EventBridge Rule with Filtering
    rule_name = f"{args.lambda_function_name}-rule"
    rule_arn = create_eventbridge_rule(rule_name, args.s3_input_files_bucket_name, args.aws_region)
    print(f"event bridge rule created {rule_arn}")

    # Step 3: Add Lambda as Target
    add_lambda_target_to_eventbridge(rule_name, lambda_function_arn, args.aws_region)

    # ✅ One function to verify everything
    if verify_eventbridge_rule(rule_name, lambda_function_arn, args.aws_region):
        print(f"EventBridge is properly configured to trigger Lambda '{args.lambda_function_name}'.")
    else:
        print(f"ERROR: EventBridge verification failed. Exiting.")

    time.sleep(30)
    # Step 4: Grant Permission to EventBridge
    add_lambda_invocation_permission(args.lambda_function_name, args.aws_region)

    if verify_lambda_eventbridge_permission(args.lambda_function_name, args.aws_region):
        print(f"EventBridge and Lambda permissions are correctly set up.")
    else:
        print(f"ERROR: EventBridge does not have permission to trigger Lambda.")
        return


if __name__ == "__main__":
    main()