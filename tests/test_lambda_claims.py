import importlib.util
import io
import json
import os
import pathlib
import unittest
from datetime import datetime, timezone

from botocore.exceptions import ClientError


os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "test")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "test")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-2")

MODULE_PATH = pathlib.Path(__file__).parents[1] / "scrna-pipeline" / "map.py"
SPEC = importlib.util.spec_from_file_location("lambda_map", MODULE_PATH)
lambda_map = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lambda_map)


def client_error(code, operation, status=412):
    return ClientError(
        {
            "Error": {"Code": code, "Message": code},
            "ResponseMetadata": {"HTTPStatusCode": status},
        },
        operation,
    )


class FakeBody(io.BytesIO):
    pass


class FakeS3:
    def __init__(self):
        self.objects = {}
        self.etag_counter = 0
        self.deleted = []

    def _etag(self):
        self.etag_counter += 1
        return f'"etag-{self.etag_counter}"'

    def head_object(self, Bucket, Key, **_kwargs):
        if Key not in self.objects:
            raise client_error("404", "HeadObject", 404)
        item = self.objects[Key]
        return {"ETag": item["ETag"], "LastModified": item["LastModified"]}

    def get_object(self, Bucket, Key):
        if Key not in self.objects:
            raise client_error("NoSuchKey", "GetObject", 404)
        item = self.objects[Key]
        return {
            "Body": FakeBody(item["Body"]),
            "ETag": item["ETag"],
            "LastModified": item["LastModified"],
            "ContentLength": len(item["Body"]),
        }

    def put_object(self, Bucket, Key, Body, IfNoneMatch=None, IfMatch=None, **_kwargs):
        current = self.objects.get(Key)
        if IfNoneMatch == "*" and current is not None:
            raise client_error("PreconditionFailed", "PutObject")
        if IfMatch is not None and (current is None or current["ETag"] != IfMatch):
            raise client_error("PreconditionFailed", "PutObject")
        etag = self._etag()
        self.objects[Key] = {
            "Body": bytes(Body),
            "ETag": etag,
            "LastModified": datetime.now(timezone.utc),
        }
        return {"ETag": etag}

    def delete_object(self, Bucket, Key, IfMatch=None):
        current = self.objects.get(Key)
        if current is None:
            raise client_error("NoSuchKey", "DeleteObject", 404)
        if IfMatch is not None and current["ETag"] != IfMatch:
            raise client_error("PreconditionFailed", "DeleteObject")
        self.deleted.append((Key, IfMatch))
        del self.objects[Key]
        return {}


class Context:
    def __init__(self, request_id):
        self.aws_request_id = request_id


class ClaimTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeS3()
        self.original_client = lambda_map.s3_client
        self.original_bucket = lambda_map.S3_OUTPUT_BUCKET_NAME
        self.original_lease = lambda_map.CLAIM_LEASE_SECONDS
        lambda_map.s3_client = self.fake
        lambda_map.S3_OUTPUT_BUCKET_NAME = "output"
        lambda_map.CLAIM_LEASE_SECONDS = 180

    def tearDown(self):
        lambda_map.s3_client = self.original_client
        lambda_map.S3_OUTPUT_BUCKET_NAME = self.original_bucket
        lambda_map.CLAIM_LEASE_SECONDS = self.original_lease

    def acquire(self, owner="request-1"):
        return lambda_map.acquire_processing_claim(
            "lane_p0", "dataset/lane_p0_input.txt", Context(owner)
        )

    def test_first_writer_atomically_acquires_claim(self):
        claim = self.acquire()
        self.assertEqual("acquired", claim["status"])
        stored = json.loads(self.fake.objects[claim["key"]]["Body"])
        self.assertEqual("request-1", stored["owner"])
        self.assertEqual("processing", stored["state"])

    def test_duplicate_completed_event_is_a_successful_noop(self):
        marker = lambda_map.completion_marker_key("lane_p0")
        self.fake.put_object(Bucket="output", Key=marker, Body=b"")
        claim = self.acquire("duplicate")
        self.assertEqual("already_complete", claim["status"])

    def test_live_claim_rejects_duplicate_owner(self):
        self.acquire("request-1")
        with self.assertRaises(lambda_map.ClaimBusyError):
            self.acquire("request-2")

    def test_expired_claim_is_taken_over_conditionally(self):
        first = self.acquire("request-1")
        stored = json.loads(self.fake.objects[first["key"]]["Body"])
        stored["lease_expires_epoch"] = 1
        self.fake.objects[first["key"]]["Body"] = json.dumps(stored).encode()

        second = self.acquire("request-2")
        self.assertEqual("acquired", second["status"])
        self.assertEqual("request-1", second["document"]["takeover_of"])
        self.assertNotEqual(first["etag"], second["etag"])

    def test_failure_release_is_conditional_on_owned_etag(self):
        claim = self.acquire()
        lambda_map.release_failed_claim(claim)
        self.assertNotIn(claim["key"], self.fake.objects)
        self.assertEqual([(claim["key"], claim["etag"])], self.fake.deleted)


if __name__ == "__main__":
    unittest.main()
