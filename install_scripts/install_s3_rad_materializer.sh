#!/usr/bin/env bash

set -euo pipefail

AWS_SDK_VERSION="${AWS_SDK_VERSION:-1.11.873}"
SDK_PREFIX="${SDK_PREFIX:-/opt/scrna-s3-rad/aws-sdk-cpp-${AWS_SDK_VERSION}}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
INSTALL_DEPENDENCIES="${INSTALL_DEPENDENCIES:-1}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
SOURCE_DIR="$REPO_DIR/tools/s3-rad-materializer"
BUILD_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/s3-rad-materializer.XXXXXX")

cleanup() {
    rm -rf -- "$BUILD_ROOT"
}
trap cleanup EXIT

if [[ "$INSTALL_DEPENDENCIES" == "1" ]]; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        build-essential cmake git ninja-build \
        libcurl4-gnutls-dev libssl-dev zlib1g-dev uuid-dev
fi

if [[ ! -f "$SDK_PREFIX/lib/cmake/AWSSDK/AWSSDKConfig.cmake" && \
      ! -f "$SDK_PREFIX/lib64/cmake/AWSSDK/AWSSDKConfig.cmake" ]]; then
    echo "Building AWS SDK for C++ ${AWS_SDK_VERSION} (S3 only)..."
    git clone --quiet --depth 1 --branch "$AWS_SDK_VERSION" --recurse-submodules \
        --shallow-submodules \
        https://github.com/aws/aws-sdk-cpp.git "$BUILD_ROOT/aws-sdk-cpp"

    cmake -S "$BUILD_ROOT/aws-sdk-cpp" -B "$BUILD_ROOT/aws-sdk-build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$SDK_PREFIX" \
        -DBUILD_ONLY=s3 \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_TESTING=OFF \
        -DAUTORUN_UNIT_TESTS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    cmake --build "$BUILD_ROOT/aws-sdk-build" --parallel "$BUILD_JOBS"
    sudo cmake --install "$BUILD_ROOT/aws-sdk-build"
else
    echo "Using existing AWS SDK for C++ at $SDK_PREFIX"
fi

echo "Building s3-rad-materialize..."
cmake -S "$SOURCE_DIR" -B "$BUILD_ROOT/materializer-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$SDK_PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
cmake --build "$BUILD_ROOT/materializer-build" --parallel "$BUILD_JOBS"
ctest --test-dir "$BUILD_ROOT/materializer-build" --output-on-failure
sudo cmake --install "$BUILD_ROOT/materializer-build"

"$INSTALL_PREFIX/bin/s3-rad-materialize" --version
