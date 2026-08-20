#include "s3_materializer.hpp"

#include <aws/core/Aws.h>

#include <cstdlib>
#include <exception>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

namespace {

constexpr const char* kVersion = "0.1.0";

void usage(std::ostream& out) {
    out <<
        "Usage: s3-rad-materialize --manifest FILE --output FILE [options]\n"
        "\n"
        "Materialize compatible S3 RAD shards directly into one local map.rad.\n"
        "The manifest contains one ordered s3://bucket/key URI per line.\n"
        "\n"
        "Options:\n"
        "  --region REGION          AWS region (or AWS_REGION)\n"
        "  --profile PROFILE        AWS shared-configuration profile\n"
        "  --threads N              Concurrent S3 payload requests (default: 32)\n"
        "  --buffer-mib N           Per-worker transfer buffer (default: 8)\n"
        "  --header-window-mib N    Initial header range size (default: 4)\n"
        "  --max-header-mib N       Maximum accepted RAD header size (default: 256)\n"
        "  --retries N              Resume attempts per payload (default: 4)\n"
        "  --overwrite              Atomically replace an existing output\n"
        "  --keep-partial           Retain .partial output after an error\n"
        "  --fsync                  Force output to NVMe before the final rename\n"
        "  --version                Print version\n"
        "  --help                   Show this help\n";
}

std::size_t parse_positive(const std::string& name, const std::string& value) {
    std::size_t consumed = 0;
    unsigned long long parsed = 0;
    try {
        parsed = std::stoull(value, &consumed);
    } catch (const std::exception&) {
        throw std::invalid_argument(name + " must be a positive integer");
    }
    if (consumed != value.size() || parsed == 0 ||
        parsed > std::numeric_limits<std::size_t>::max()) {
        throw std::invalid_argument(name + " must be a positive integer");
    }
    return static_cast<std::size_t>(parsed);
}

std::size_t mib(const std::string& name, const std::string& value) {
    const auto amount = parse_positive(name, value);
    constexpr std::size_t unit = 1024U * 1024U;
    if (amount > std::numeric_limits<std::size_t>::max() / unit) {
        throw std::invalid_argument(name + " is too large");
    }
    return amount * unit;
}

scrna::materializer::Options parse_args(int argc, char** argv) {
    scrna::materializer::Options options;
    if (const char* region = std::getenv("AWS_REGION")) {
        options.region = region;
    } else if (const char* region = std::getenv("AWS_DEFAULT_REGION")) {
        options.region = region;
    }

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto require_value = [&]() -> std::string {
            if (++i >= argc) {
                throw std::invalid_argument(arg + " requires a value");
            }
            return argv[i];
        };

        if (arg == "--manifest") {
            options.manifest = require_value();
        } else if (arg == "--output") {
            options.output = require_value();
        } else if (arg == "--region") {
            options.region = require_value();
        } else if (arg == "--profile") {
            options.profile = require_value();
        } else if (arg == "--threads") {
            options.threads = parse_positive(arg, require_value());
        } else if (arg == "--buffer-mib") {
            options.buffer_size = mib(arg, require_value());
        } else if (arg == "--header-window-mib") {
            options.initial_header_window = mib(arg, require_value());
        } else if (arg == "--max-header-mib") {
            options.maximum_header_size = mib(arg, require_value());
        } else if (arg == "--retries") {
            const auto retries = parse_positive(arg, require_value());
            if (retries > std::numeric_limits<unsigned int>::max()) {
                throw std::invalid_argument(arg + " is too large");
            }
            options.retries = static_cast<unsigned int>(retries);
        } else if (arg == "--overwrite") {
            options.overwrite = true;
        } else if (arg == "--keep-partial") {
            options.keep_partial = true;
        } else if (arg == "--fsync") {
            options.sync_output = true;
        } else if (arg == "--version") {
            std::cout << "s3-rad-materialize " << kVersion << '\n';
            std::exit(0);
        } else if (arg == "--help" || arg == "-h") {
            usage(std::cout);
            std::exit(0);
        } else {
            throw std::invalid_argument("unknown argument: " + arg);
        }
    }

    if (options.manifest.empty()) {
        throw std::invalid_argument("--manifest is required");
    }
    if (options.output.empty()) {
        throw std::invalid_argument("--output is required");
    }
    if (options.region.empty()) {
        throw std::invalid_argument("--region or AWS_REGION is required");
    }
    if (options.initial_header_window > options.maximum_header_size) {
        throw std::invalid_argument("--header-window-mib cannot exceed --max-header-mib");
    }
    return options;
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const auto options = parse_args(argc, argv);

        Aws::SDKOptions sdk_options;
        Aws::InitAPI(sdk_options);
        int result = 1;
        try {
            result = scrna::materializer::run(options);
        } catch (...) {
            Aws::ShutdownAPI(sdk_options);
            throw;
        }
        Aws::ShutdownAPI(sdk_options);
        return result;
    } catch (const std::exception& error) {
        std::cerr << "error: " << error.what() << '\n';
        return 1;
    }
}
