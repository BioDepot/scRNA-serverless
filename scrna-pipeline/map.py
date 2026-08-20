import boto3
import json
import os
import shutil
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from boto3.s3.transfer import S3Transfer
from botocore.exceptions import ClientError
from urllib.parse import urlparse

# AWS S3 buckets

S3_OUTPUT_BUCKET_NAME = os.getenv("S3_OUTPUT_BUCKET_NAME","")
S3_INPUT_BUCKET_NAME = os.getenv("S3_INPUT_BUCKET_NAME", "")
EXPECTED_INPUT_FILES_BUCKET = os.getenv("S3_INPUT_TXT_BUCKET_NAME", "")
S3_PREFIX = "piscem_output"
S3_CLAIM_PREFIX = os.getenv("S3_CLAIM_PREFIX", "piscem_claims").strip("/")
CLAIM_LEASE_SECONDS = int(os.getenv("CLAIM_LEASE_SECONDS", "180"))
CLAIM_HEARTBEAT_SECONDS = int(os.getenv("CLAIM_HEARTBEAT_SECONDS", "30"))

print(f"S3_OUTPUT_BUCKET_NAME : {S3_OUTPUT_BUCKET_NAME}")
print(f"S3_INPUT_BUCKET_NAME : {S3_INPUT_BUCKET_NAME}")
print(f"EXPECTED_INPUT_FILES_BUCKET : {EXPECTED_INPUT_FILES_BUCKET}")
s3_client = boto3.client('s3')


class ClaimBusyError(RuntimeError):
    """A different invocation currently owns this manifest."""


class ClaimLostError(RuntimeError):
    """This invocation no longer owns its conditional S3 claim."""


def utc_now_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def is_s3_error(error, *codes):
    if not isinstance(error, ClientError):
        return False
    response = error.response or {}
    code = str(response.get("Error", {}).get("Code", ""))
    status = str(response.get("ResponseMetadata", {}).get("HTTPStatusCode", ""))
    return code in codes or status in codes


def completion_marker_key(output_folder):
    return f"{S3_PREFIX}/{output_folder}/output.txt"


def completion_marker_exists(output_folder):
    try:
        s3_client.head_object(
            Bucket=S3_OUTPUT_BUCKET_NAME,
            Key=completion_marker_key(output_folder),
        )
        return True
    except ClientError as error:
        if is_s3_error(error, "404", "NoSuchKey", "NotFound"):
            return False
        raise


def claim_object_key(output_folder):
    return f"{S3_CLAIM_PREFIX}/{output_folder}.json"


def claim_document(owner, output_folder, input_file_key, state, now_epoch, **extra):
    document = {
        "version": 1,
        "owner": owner,
        "output_folder": output_folder,
        "input_file_key": input_file_key,
        "state": state,
        "updated_at": utc_now_iso(),
        "lease_expires_epoch": now_epoch + CLAIM_LEASE_SECONDS,
    }
    document.update(extra)
    return document


def put_claim_document(key, document, **conditions):
    response = s3_client.put_object(
        Bucket=S3_OUTPUT_BUCKET_NAME,
        Key=key,
        Body=json.dumps(document, sort_keys=True).encode("utf-8"),
        ContentType="application/json",
        **conditions,
    )
    etag = response.get("ETag")
    if not etag:
        etag = s3_client.head_object(
            Bucket=S3_OUTPUT_BUCKET_NAME,
            Key=key,
        )["ETag"]
    return etag


def read_claim_document(key):
    response = s3_client.get_object(Bucket=S3_OUTPUT_BUCKET_NAME, Key=key)
    body = response["Body"]
    try:
        document = json.loads(body.read().decode("utf-8"))
    finally:
        body.close()
    return document, response["ETag"], response.get("LastModified")


def acquire_processing_claim(output_folder, input_file_key, context):
    """Atomically acquire or take over an expired per-manifest S3 lease."""
    if completion_marker_exists(output_folder):
        print(f"CLAIM already_complete folder={output_folder}", flush=True)
        return {"status": "already_complete"}

    owner = getattr(context, "aws_request_id", None) or "unknown-request"
    key = claim_object_key(output_folder)
    now_epoch = int(time.time())
    document = claim_document(
        owner,
        output_folder,
        input_file_key,
        "processing",
        now_epoch,
        acquired_at=utc_now_iso(),
    )
    try:
        etag = put_claim_document(key, document, IfNoneMatch="*")
        print(f"CLAIM acquired key={key} owner={owner} etag={etag}", flush=True)
    except ClientError as error:
        if not is_s3_error(error, "409", "412", "ConditionalRequestConflict", "PreconditionFailed"):
            raise
        if completion_marker_exists(output_folder):
            print(f"CLAIM duplicate_complete folder={output_folder}", flush=True)
            return {"status": "already_complete"}

        existing, existing_etag, last_modified = read_claim_document(key)
        expires_epoch = int(existing.get("lease_expires_epoch", 0) or 0)
        if not expires_epoch and last_modified is not None:
            expires_epoch = int(last_modified.timestamp()) + CLAIM_LEASE_SECONDS
        if now_epoch < expires_epoch:
            existing_owner = existing.get("owner", "unknown")
            remaining = expires_epoch - now_epoch
            print(
                f"CLAIM busy key={key} owner={existing_owner} "
                f"lease_remaining_seconds={remaining}",
                flush=True,
            )
            raise ClaimBusyError(
                f"Manifest {input_file_key} is owned by {existing_owner} "
                f"for another {remaining}s"
            )

        document["takeover_of"] = existing.get("owner")
        document["takeover_at"] = utc_now_iso()
        try:
            etag = put_claim_document(key, document, IfMatch=existing_etag)
        except ClientError as takeover_error:
            if is_s3_error(
                takeover_error,
                "409",
                "412",
                "ConditionalRequestConflict",
                "PreconditionFailed",
            ):
                raise ClaimBusyError(
                    f"Another invocation took over {input_file_key}"
                ) from takeover_error
            raise
        print(
            f"CLAIM takeover key={key} owner={owner} previous={document.get('takeover_of')} "
            f"etag={etag}",
            flush=True,
        )

    claim = {
        "status": "acquired",
        "key": key,
        "owner": owner,
        "etag": etag,
        "document": document,
        "mutex": threading.Lock(),
        "stop": threading.Event(),
        "lost": threading.Event(),
        "heartbeat": None,
    }
    return claim


def refresh_processing_claim(claim):
    with claim["mutex"]:
        if claim["lost"].is_set():
            raise ClaimLostError(f"S3 claim lost: {claim['key']}")
        document = dict(claim["document"])
        now_epoch = int(time.time())
        document["updated_at"] = utc_now_iso()
        document["lease_expires_epoch"] = now_epoch + CLAIM_LEASE_SECONDS
        try:
            etag = put_claim_document(
                claim["key"], document, IfMatch=claim["etag"]
            )
        except ClientError as error:
            if is_s3_error(
                error,
                "409",
                "412",
                "ConditionalRequestConflict",
                "PreconditionFailed",
            ):
                claim["lost"].set()
                raise ClaimLostError(f"S3 claim lost: {claim['key']}") from error
            raise
        claim["etag"] = etag
        claim["document"] = document


def start_claim_heartbeat(claim):
    def heartbeat():
        while not claim["stop"].wait(CLAIM_HEARTBEAT_SECONDS):
            try:
                refresh_processing_claim(claim)
                print(
                    f"CLAIM heartbeat key={claim['key']} owner={claim['owner']}",
                    flush=True,
                )
            except ClaimLostError as error:
                print(f"CLAIM heartbeat_lost error={error}", flush=True)
                return
            except Exception as error:
                # A transient heartbeat failure is not proof of lost ownership.
                # The synchronous refresh before upload is authoritative.
                print(
                    f"CLAIM heartbeat_warning type={type(error).__name__} error={error}",
                    flush=True,
                )

    thread = threading.Thread(
        target=heartbeat,
        name="s3-claim-heartbeat",
        daemon=True,
    )
    claim["heartbeat"] = thread
    thread.start()


def stop_claim_heartbeat(claim):
    if not claim or claim.get("status") != "acquired":
        return
    claim["stop"].set()
    thread = claim.get("heartbeat")
    if thread is not None:
        thread.join(timeout=max(1, CLAIM_HEARTBEAT_SECONDS + 1))


def mark_claim_completed(claim, timings):
    stop_claim_heartbeat(claim)
    with claim["mutex"]:
        document = dict(claim["document"])
        document.update(
            state="completed",
            completed_at=utc_now_iso(),
            timings=timings,
        )
        document.pop("lease_expires_epoch", None)
        try:
            etag = put_claim_document(
                claim["key"], document, IfMatch=claim["etag"]
            )
        except ClientError as error:
            if is_s3_error(
                error,
                "409",
                "412",
                "ConditionalRequestConflict",
                "PreconditionFailed",
            ):
                claim["lost"].set()
                raise ClaimLostError(f"S3 claim lost: {claim['key']}") from error
            raise
        claim["etag"] = etag
        claim["document"] = document
        print(
            f"CLAIM completed key={claim['key']} owner={claim['owner']} etag={etag}",
            flush=True,
        )


def release_failed_claim(claim):
    stop_claim_heartbeat(claim)
    with claim["mutex"]:
        try:
            s3_client.delete_object(
                Bucket=S3_OUTPUT_BUCKET_NAME,
                Key=claim["key"],
                IfMatch=claim["etag"],
            )
            print(
                f"CLAIM released_after_failure key={claim['key']} owner={claim['owner']}",
                flush=True,
            )
        except ClientError as error:
            if not is_s3_error(
                error,
                "404",
                "409",
                "412",
                "NoSuchKey",
                "NotFound",
                "ConditionalRequestConflict",
                "PreconditionFailed",
            ):
                raise
            print(
                f"CLAIM release_skipped key={claim['key']} owner={claim['owner']}",
                flush=True,
            )

def read_input_manifest(bucket, input_file_key):
    """Read and validate the S3 URI manifest without materializing it in /tmp."""
    response = s3_client.get_object(Bucket=bucket, Key=input_file_key)
    body = response["Body"]
    try:
        contents = body.read().decode("utf-8")
    finally:
        body.close()

    uris = [line.strip() for line in contents.splitlines() if line.strip()]
    if not uris:
        raise ValueError(f"Input manifest s3://{bucket}/{input_file_key} is empty")
    return uris


def parse_fastq_uri(uri):
    parsed = urlparse(uri)
    if parsed.scheme != "s3" or not parsed.netloc or not parsed.path.lstrip("/"):
        raise ValueError(f"Invalid S3 FASTQ URI: {uri}")

    object_key = parsed.path.lstrip("/")
    lower_key = object_key.lower()
    if lower_key.endswith((".fastq.gz", ".fq.gz")):
        suffix = ".fastq.gz"
        compression = "gzip"
    elif lower_key.endswith((".fastq", ".fq")):
        suffix = ".fastq"
        compression = "none"
    else:
        raise ValueError(
            f"Unsupported FASTQ suffix for {uri}; expected .fastq, .fq, "
            ".fastq.gz, or .fq.gz"
        )

    basename = os.path.basename(object_key)
    if "_R1_" in basename:
        read = "R1"
    elif "_R2_" in basename:
        read = "R2"
    else:
        raise ValueError(f"Cannot classify FASTQ as R1 or R2: {uri}")

    return {
        "uri": uri,
        "bucket": parsed.netloc,
        "key": object_key,
        "read": read,
        "suffix": suffix,
        "compression": compression,
    }


def create_fastq_fifos(s3_uris, stream_dir):
    """Create format-preserving FIFO paths for a paired FASTQ manifest."""
    os.makedirs(stream_dir, exist_ok=True)
    specs = [parse_fastq_uri(uri) for uri in s3_uris]
    files_r1 = sorted(
        (spec for spec in specs if spec["read"] == "R1"),
        key=lambda spec: spec["uri"],
    )
    files_r2 = sorted(
        (spec for spec in specs if spec["read"] == "R2"),
        key=lambda spec: spec["uri"],
    )
    if not files_r1 or not files_r2 or len(files_r1) != len(files_r2):
        raise ValueError(
            f"Expected equal non-zero R1/R2 inputs, got "
            f"R1={len(files_r1)} R2={len(files_r2)}"
        )

    for read_specs in (files_r1, files_r2):
        for index, spec in enumerate(read_specs):
            fifo_path = os.path.join(
                stream_dir,
                f"{spec['read'].lower()}_{index:04d}{spec['suffix']}",
            )
            os.mkfifo(fifo_path, 0o600)
            spec["fifo_path"] = fifo_path

    return files_r1, files_r2


def write_s3_object_to_fifo(spec):
    """Copy one complete S3 object, in order, into a Piscem input FIFO."""
    started = time.perf_counter()
    response = None
    body = None
    bytes_written = 0
    first_byte_seconds = None
    try:
        # Opening first lets the FIFO apply backpressure before an S3 body is held.
        with open(spec["fifo_path"], "wb", buffering=0) as output:
            response = s3_client.get_object(Bucket=spec["bucket"], Key=spec["key"])
            expected_bytes = int(response["ContentLength"])
            body = response["Body"]
            while True:
                chunk = body.read(8 * 1024 * 1024)
                if not chunk:
                    break
                if first_byte_seconds is None:
                    first_byte_seconds = time.perf_counter() - started
                remaining = memoryview(chunk)
                while remaining:
                    written = output.write(remaining)
                    if not written:
                        raise IOError(f"Zero-byte FIFO write for {spec['uri']}")
                    bytes_written += written
                    remaining = remaining[written:]
    finally:
        if body is not None:
            body.close()

    if bytes_written != expected_bytes:
        raise IOError(
            f"Truncated S3 stream for {spec['uri']}: "
            f"wrote {bytes_written}, expected {expected_bytes} bytes"
        )

    result = {
        "uri": spec["uri"],
        "read": spec["read"],
        "compression": spec["compression"],
        "bytes": bytes_written,
        "seconds": round(time.perf_counter() - started, 6),
        "first_byte_seconds": round(first_byte_seconds or 0.0, 6),
    }
    print("S3_STREAM " + json.dumps(result, sort_keys=True), flush=True)
    return result


def close_fds(fds):
    while fds:
        try:
            os.close(fds.pop())
        except OSError:
            pass


def close_fifo_keeper(keeper_fds, fifo_path):
    fd = keeper_fds.pop(fifo_path, None)
    if fd is not None:
        close_fds([fd])


def close_fifo_keepers(keeper_fds):
    close_fds(list(keeper_fds.values()))
    keeper_fds.clear()


def run_piscem_streaming(files_r1, files_r2):
    home_dir = "/var/task"
    output_dir = "/tmp/output"
    os.makedirs(output_dir, exist_ok=True)

    # Thread scaling policy:
    # - 3008MB Lambda: use 2 threads
    # - 10240MB Lambda: use up to 6 threads
    # Also cap by visible CPUs in the runtime.
    cpu_count = os.cpu_count() or 2
    try:
        lambda_memory_mb = int(os.getenv("LAMBDA_MEMORY_MB", "0"))
    except ValueError:
        lambda_memory_mb = 0
    thread_cap = 2 if 0 < lambda_memory_mb <= 3008 else 6
    num_threads = max(2, min(cpu_count, thread_cap))
    print(
        f"Thread selection: cpu_count={cpu_count}, "
        f"LAMBDA_MEMORY_MB={lambda_memory_mb}, threads={num_threads}"
    )

    command = [
        "/var/task/piscem", "map-sc",
        "-i", f"{home_dir}/index_output_transcriptome/index_output_transcriptome",
        "-g", "chromium_v3",
        "-1", ",".join(spec["fifo_path"] for spec in files_r1),
        "-2", ",".join(spec["fifo_path"] for spec in files_r2),
        "-t", str(num_threads),
        "-o", f"{output_dir}/split_map_output_transcriptome"
    ]

    all_specs = files_r1 + files_r2
    # Keep every FIFO open until its producer finishes. This prevents an early
    # EOF race between FIFO creation, producer startup, and Piscem opening it.
    keeper_fds = {
        spec["fifo_path"]: os.open(
            spec["fifo_path"], os.O_RDWR | os.O_NONBLOCK
        )
        for spec in all_specs
    }
    executor = ThreadPoolExecutor(
        max_workers=len(all_specs), thread_name_prefix="s3-fastq"
    )
    futures = []
    process = None
    started = time.perf_counter()
    try:
        future_specs = {
            executor.submit(write_s3_object_to_fifo, spec): spec
            for spec in all_specs
        }
        futures = list(future_specs)
        print("Running command")
        print(f"{command}")
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        producer_failure = None
        while process.poll() is None:
            for future, spec in future_specs.items():
                if future.done():
                    # Deliver EOF independently for R1 and R2. Waiting for all
                    # producers before closing every keeper can deadlock a
                    # paired reader when one byte stream finishes first.
                    close_fifo_keeper(keeper_fds, spec["fifo_path"])
                    if future.exception() is not None:
                        producer_failure = future.exception()
                        break
            if producer_failure is not None or all(future.done() for future in futures):
                break
            time.sleep(0.05)

        close_fifo_keepers(keeper_fds)
        if producer_failure is not None:
            process.terminate()

        stdout, stderr = process.communicate(timeout=30)
        if stdout:
            print(stdout, end="")
        if stderr:
            print(stderr, end="")

        stream_results = [future.result() for future in futures]
        if process.returncode != 0:
            raise RuntimeError(
                f"Piscem exited with status {process.returncode}: {stderr[-4000:]}"
            )

        output_prefix = os.path.join(output_dir, "split_map_output_transcriptome")
        map_rad = os.path.join(output_prefix, "map.rad")
        map_info_path = os.path.join(output_prefix, "map_info.json")
        if not os.path.isfile(map_rad) or not os.path.isfile(map_info_path):
            raise RuntimeError("Piscem completed without map.rad and map_info.json")
        with open(map_info_path, "r") as map_info_file:
            map_info = json.load(map_info_file)

        result = {
            "seconds": round(time.perf_counter() - started, 6),
            "threads": num_threads,
            "input_bytes": sum(item["bytes"] for item in stream_results),
            "inputs": stream_results,
            "map_rad_bytes": os.path.getsize(map_rad),
            "num_reads": map_info.get("num_reads"),
            "num_mapped": map_info.get("num_mapped"),
        }
        print("PISCEM_STREAMING " + json.dumps(result, sort_keys=True), flush=True)
        return result
    except Exception:
        close_fifo_keepers(keeper_fds)
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
        raise
    finally:
        close_fifo_keepers(keeper_fds)
        executor.shutdown(wait=True, cancel_futures=True)


def upload_files_with_completion_marker(output_dir, output_folder, s3_bucket_name, s3_prefix):
    # Do not reuse the streaming client's HTTP connection pool for uploads.
    # A warm invocation once inherited a malformed/reused S3 response and spent
    # 30 seconds recovering while uploading a tiny companion file. Closing both
    # the transfer manager and this dedicated client also prevents its worker
    # pool from surviving into the next warm invocation.
    upload_client = boto3.client("s3")
    try:
        with S3Transfer(upload_client) as transfer:
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
    finally:
        upload_client.close()


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

    claim = None
    total_started = time.perf_counter()
    try:
        claim = acquire_processing_claim(final_folder_name, input_file_key, context)
        if claim["status"] == "already_complete":
            return {
                'statusCode': 200,
                'body': 'Piscem output already complete; duplicate event ignored',
                'idempotent': True,
            }
        start_claim_heartbeat(claim)

        manifest_started = time.perf_counter()
        s3_uris = read_input_manifest(bucket, input_file_key)
        manifest_seconds = time.perf_counter() - manifest_started

        stream_dir = "/tmp/input_streams"
        files_r1, files_r2 = create_fastq_fifos(s3_uris, stream_dir)
        formats = sorted({spec["compression"] for spec in files_r1 + files_r2})
        print(
            f"Streaming {len(files_r1)} R1/R2 pair(s); formats={formats}",
            flush=True,
        )

        piscem_result = run_piscem_streaming(files_r1, files_r2)

        # Prove ownership immediately before publishing output. A stale owner
        # must not race a takeover and write the same deterministic prefix.
        refresh_processing_claim(claim)
        upload_started = time.perf_counter()
        print(f"uploading output files to folder {final_folder_name}")
        upload_files_with_completion_marker(
            "/tmp/output", final_folder_name, S3_OUTPUT_BUCKET_NAME, S3_PREFIX
        )
        upload_seconds = time.perf_counter() - upload_started

        timings = {
            "manifest_seconds": round(manifest_seconds, 6),
            "stream_and_piscem_seconds": piscem_result["seconds"],
            "upload_seconds": round(upload_seconds, 6),
            "total_seconds": round(time.perf_counter() - total_started, 6),
            "formats": formats,
            "num_reads": piscem_result["num_reads"],
            "num_mapped": piscem_result["num_mapped"],
            "input_bytes": piscem_result["input_bytes"],
            "map_rad_bytes": piscem_result["map_rad_bytes"],
        }
        print("PIPELINE_TIMING " + json.dumps(timings, sort_keys=True), flush=True)
        try:
            mark_claim_completed(claim, timings)
        except Exception as claim_error:
            # output.txt is the durable completion contract. A claim-audit
            # update must not turn a successfully published shard into a retry.
            print(
                f"CLAIM completion_warning type={type(claim_error).__name__} "
                f"error={claim_error}",
                flush=True,
            )
        return {
            'statusCode': 200,
            'body': 'Piscem map is successful',
            'timings': timings,
        }
    except Exception as error:
        if claim and claim.get("status") == "acquired":
            try:
                if not completion_marker_exists(final_folder_name):
                    release_failed_claim(claim)
            except Exception as release_error:
                print(
                    f"CLAIM release_warning type={type(release_error).__name__} "
                    f"error={release_error}",
                    flush=True,
                )
        print(f"Mapper failed: {type(error).__name__}: {error}", flush=True)
        # An asynchronous Lambda invocation treats a returned HTTP-style 500
        # dictionary as success. Re-raise so Lambda records a failed invocation
        # and applies the configured retry/dead-letter behavior.
        raise
    finally:
        stop_claim_heartbeat(claim)


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
