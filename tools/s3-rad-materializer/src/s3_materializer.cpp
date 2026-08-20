#include "s3_materializer.hpp"

#include "rad_prelude.hpp"

#include <aws/core/auth/AWSCredentialsProviderChain.h>
#include <aws/core/auth/AWSCredentialsProvider.h>
#include <aws/core/client/ClientConfiguration.h>
#include <aws/s3/S3Client.h>
#include <aws/s3/model/GetObjectRequest.h>
#include <aws/s3/model/HeadObjectRequest.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <unistd.h>
#include <utility>
#include <vector>

namespace scrna::materializer {
namespace {

using Clock = std::chrono::steady_clock;

struct S3Location {
    std::string bucket;
    std::string key;
};

struct Shard {
    S3Location location;
    std::string etag;
    std::string version_id;
    std::uint64_t object_size{};
    std::vector<std::uint8_t> header;
    rad::PreludeInfo prelude;
    std::uint64_t payload_size{};
    std::uint64_t destination_offset{};
};

class FileDescriptor {
public:
    explicit FileDescriptor(int fd) : fd_(fd) {}
    ~FileDescriptor() {
        if (fd_ >= 0) {
            ::close(fd_);
        }
    }
    FileDescriptor(const FileDescriptor&) = delete;
    FileDescriptor& operator=(const FileDescriptor&) = delete;
    int get() const { return fd_; }
    void close_checked() {
        if (fd_ >= 0) {
            if (::close(fd_) != 0) {
                fd_ = -1;
                throw std::system_error(errno, std::generic_category(), "close output");
            }
            fd_ = -1;
        }
    }

private:
    int fd_;
};

std::string trim(std::string value) {
    const auto begin = value.find_first_not_of(" \t\r\n");
    if (begin == std::string::npos) {
        return {};
    }
    const auto end = value.find_last_not_of(" \t\r\n");
    return value.substr(begin, end - begin + 1);
}

S3Location parse_s3_uri(const std::string& uri) {
    constexpr const char* scheme = "s3://";
    if (uri.rfind(scheme, 0) != 0) {
        throw std::invalid_argument("manifest entry is not an s3:// URI: " + uri);
    }
    const auto slash = uri.find('/', std::strlen(scheme));
    if (slash == std::string::npos || slash == std::strlen(scheme) || slash + 1 == uri.size()) {
        throw std::invalid_argument("manifest entry must contain a bucket and key: " + uri);
    }
    return {uri.substr(std::strlen(scheme), slash - std::strlen(scheme)), uri.substr(slash + 1)};
}

std::vector<Shard> read_manifest(const std::filesystem::path& path) {
    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("cannot open manifest: " + path.string());
    }

    std::vector<Shard> shards;
    std::string line;
    std::size_t line_number = 0;
    while (std::getline(input, line)) {
        ++line_number;
        line = trim(std::move(line));
        if (line.empty() || line[0] == '#') {
            continue;
        }
        try {
            Shard shard;
            shard.location = parse_s3_uri(line);
            shards.push_back(std::move(shard));
        } catch (const std::exception& error) {
            throw std::runtime_error(
                path.string() + ":" + std::to_string(line_number) + ": " + error.what());
        }
    }
    if (!input.eof()) {
        throw std::runtime_error("failed while reading manifest: " + path.string());
    }
    if (shards.empty()) {
        throw std::runtime_error("manifest contains no S3 objects: " + path.string());
    }
    return shards;
}

std::shared_ptr<Aws::S3::S3Client> make_s3_client(const Options& options) {
    Aws::Client::ClientConfiguration config;
    config.region = options.region.c_str();
    config.maxConnections = static_cast<unsigned int>(std::max<std::size_t>(options.threads + 4, 16));
    config.connectTimeoutMs = 10'000;
    config.requestTimeoutMs = 0;  // permit large streaming responses

    if (!options.profile.empty()) {
        auto credentials = std::make_shared<Aws::Auth::ProfileConfigFileAWSCredentialsProvider>(
            options.profile.c_str());
        return std::make_shared<Aws::S3::S3Client>(
            credentials,
            config,
            Aws::Client::AWSAuthV4Signer::PayloadSigningPolicy::Never,
            true);
    }

    auto credentials = std::make_shared<Aws::Auth::DefaultAWSCredentialsProviderChain>();
    return std::make_shared<Aws::S3::S3Client>(
        credentials,
        config,
        Aws::Client::AWSAuthV4Signer::PayloadSigningPolicy::Never,
        true);
}

std::string describe(const Shard& shard) {
    return "s3://" + shard.location.bucket + "/" + shard.location.key;
}

std::string aws_error(const Aws::Client::AWSError<Aws::S3::S3Errors>& error) {
    return std::string(error.GetExceptionName().c_str()) + ": " + error.GetMessage().c_str();
}

void head_shard(Aws::S3::S3Client& client, Shard& shard) {
    Aws::S3::Model::HeadObjectRequest request;
    request.SetBucket(shard.location.bucket.c_str());
    request.SetKey(shard.location.key.c_str());

    const auto outcome = client.HeadObject(request);
    if (!outcome.IsSuccess()) {
        throw std::runtime_error("HeadObject failed for " + describe(shard) + ": " +
            aws_error(outcome.GetError()));
    }
    const auto& result = outcome.GetResult();
    if (result.GetContentLength() <= 0) {
        throw std::runtime_error("empty RAD object: " + describe(shard));
    }
    shard.object_size = static_cast<std::uint64_t>(result.GetContentLength());
    shard.etag = result.GetETag().c_str();
    shard.version_id = result.GetVersionId().c_str();
}

void pin_request(Aws::S3::Model::GetObjectRequest& request, const Shard& shard) {
    if (!shard.version_id.empty()) {
        request.SetVersionId(shard.version_id.c_str());
    } else if (!shard.etag.empty()) {
        request.SetIfMatch(shard.etag.c_str());
    }
}

std::vector<std::uint8_t> get_range(
    Aws::S3::S3Client& client,
    const Shard& shard,
    std::uint64_t begin,
    std::uint64_t end) {
    if (begin > end || end >= shard.object_size) {
        throw std::logic_error("invalid S3 range for " + describe(shard));
    }

    Aws::S3::Model::GetObjectRequest request;
    request.SetBucket(shard.location.bucket.c_str());
    request.SetKey(shard.location.key.c_str());
    request.SetRange(("bytes=" + std::to_string(begin) + "-" + std::to_string(end)).c_str());
    pin_request(request, shard);

    auto outcome = client.GetObject(request);
    if (!outcome.IsSuccess()) {
        throw std::runtime_error("GetObject range failed for " + describe(shard) + ": " +
            aws_error(outcome.GetError()));
    }

    const auto expected = end - begin + 1;
    if (expected > std::numeric_limits<std::size_t>::max()) {
        throw std::runtime_error("header range is too large");
    }
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(expected));
    auto result = outcome.GetResultWithOwnership();
    auto& body = result.GetBody();
    std::size_t offset = 0;
    while (offset < bytes.size() && body) {
        body.read(
            reinterpret_cast<char*>(bytes.data() + offset),
            static_cast<std::streamsize>(bytes.size() - offset));
        offset += static_cast<std::size_t>(body.gcount());
    }
    if (offset != bytes.size()) {
        throw std::runtime_error(
            "short header range for " + describe(shard) + ": expected " +
            std::to_string(bytes.size()) + ", received " + std::to_string(offset));
    }
    return bytes;
}

void inspect_shard(Aws::S3::S3Client& client, Shard& shard, const Options& options) {
    head_shard(client, shard);

    std::uint64_t fetched = 0;
    std::uint64_t window = std::min<std::uint64_t>(options.initial_header_window, shard.object_size);
    while (fetched < shard.object_size && fetched < options.maximum_header_size) {
        const auto remaining_limit = static_cast<std::uint64_t>(options.maximum_header_size) - fetched;
        const auto amount = std::min({window, shard.object_size - fetched, remaining_limit});
        const auto range = get_range(client, shard, fetched, fetched + amount - 1);
        shard.header.insert(shard.header.end(), range.begin(), range.end());
        fetched += amount;

        try {
            shard.prelude = rad::parse_prelude(shard.header);
            shard.header.resize(shard.prelude.payload_offset);
            if (shard.prelude.payload_offset >= shard.object_size) {
                throw std::runtime_error("RAD object has no record payload: " + describe(shard));
            }
            shard.payload_size = shard.object_size - shard.prelude.payload_offset;
            return;
        } catch (const rad::NeedMoreData&) {
            if (fetched == shard.object_size || fetched == options.maximum_header_size) {
                break;
            }
            window = std::min<std::uint64_t>(window * 2, options.maximum_header_size - fetched);
        } catch (const rad::InvalidRad& error) {
            throw std::runtime_error("invalid RAD prelude in " + describe(shard) + ": " + error.what());
        }
    }
    throw std::runtime_error(
        "RAD prelude exceeds --max-header-mib or object is truncated: " + describe(shard));
}

template <typename Function>
void parallel_for(std::size_t count, std::size_t threads, Function function) {
    std::atomic<std::size_t> next{0};
    std::atomic<bool> cancelled{false};
    std::exception_ptr failure;
    std::mutex failure_mutex;

    const auto worker_count = std::min(count, threads);
    std::vector<std::thread> workers;
    workers.reserve(worker_count);
    for (std::size_t worker = 0; worker < worker_count; ++worker) {
        workers.emplace_back([&] {
            while (!cancelled.load(std::memory_order_relaxed)) {
                const auto index = next.fetch_add(1, std::memory_order_relaxed);
                if (index >= count) {
                    return;
                }
                try {
                    function(index);
                } catch (...) {
                    {
                        std::lock_guard<std::mutex> lock(failure_mutex);
                        if (!failure) {
                            failure = std::current_exception();
                        }
                    }
                    cancelled.store(true, std::memory_order_relaxed);
                    return;
                }
            }
        });
    }
    for (auto& worker : workers) {
        worker.join();
    }
    if (failure) {
        std::rethrow_exception(failure);
    }
}

std::uint64_t checked_add(std::uint64_t lhs, std::uint64_t rhs, const char* label) {
    if (rhs > std::numeric_limits<std::uint64_t>::max() - lhs) {
        throw std::overflow_error(std::string(label) + " exceeds 64-bit file size");
    }
    return lhs + rhs;
}

void pwrite_all(int fd, const char* data, std::size_t size, std::uint64_t offset) {
    while (size > 0) {
        if (offset > static_cast<std::uint64_t>(std::numeric_limits<off_t>::max())) {
            throw std::overflow_error("destination offset exceeds off_t");
        }
        const auto written = ::pwrite(fd, data, size, static_cast<off_t>(offset));
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            throw std::system_error(errno, std::generic_category(), "pwrite output");
        }
        if (written == 0) {
            throw std::runtime_error("pwrite returned zero");
        }
        data += written;
        size -= static_cast<std::size_t>(written);
        offset += static_cast<std::uint64_t>(written);
    }
}

void copy_payload(
    Aws::S3::S3Client& client,
    const Shard& shard,
    int output_fd,
    const Options& options) {
    std::vector<char> buffer(options.buffer_size);
    std::uint64_t completed = 0;
    unsigned int attempts = 0;

    while (completed < shard.payload_size) {
        Aws::S3::Model::GetObjectRequest request;
        request.SetBucket(shard.location.bucket.c_str());
        request.SetKey(shard.location.key.c_str());
        const auto source = static_cast<std::uint64_t>(shard.prelude.payload_offset) + completed;
        request.SetRange(("bytes=" + std::to_string(source) + "-").c_str());
        pin_request(request, shard);

        auto outcome = client.GetObject(request);
        if (!outcome.IsSuccess()) {
            if (++attempts > options.retries) {
                throw std::runtime_error("payload GetObject failed for " + describe(shard) + ": " +
                    aws_error(outcome.GetError()));
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(200U * attempts));
            continue;
        }

        auto result = outcome.GetResultWithOwnership();
        auto& body = result.GetBody();
        bool made_progress = false;
        while (completed < shard.payload_size && body) {
            const auto wanted = static_cast<std::streamsize>(
                std::min<std::uint64_t>(buffer.size(), shard.payload_size - completed));
            body.read(buffer.data(), wanted);
            const auto received = body.gcount();
            if (received <= 0) {
                break;
            }
            pwrite_all(
                output_fd,
                buffer.data(),
                static_cast<std::size_t>(received),
                shard.destination_offset + completed);
            completed += static_cast<std::uint64_t>(received);
            made_progress = true;
        }

        if (completed == shard.payload_size) {
            return;
        }
        if (++attempts > options.retries) {
            throw std::runtime_error(
                "short payload response for " + describe(shard) + " after " +
                std::to_string(completed) + " of " + std::to_string(shard.payload_size) + " bytes");
        }
        if (!made_progress) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200U * attempts));
        }
    }
}

double seconds_since(const Clock::time_point& start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}

}  // namespace

int run(const Options& options) {
    const auto total_start = Clock::now();
    auto shards = read_manifest(options.manifest);
    auto client = make_s3_client(options);
    const auto setup_seconds = seconds_since(total_start);

    std::cerr << "Inspecting " << shards.size() << " RAD shards with "
              << std::min(options.threads, shards.size()) << " workers\n";
    const auto inspect_start = Clock::now();
    parallel_for(shards.size(), options.threads, [&](std::size_t index) {
        inspect_shard(*client, shards[index], options);
    });
    const auto inspect_seconds = seconds_since(inspect_start);
    const auto prepare_start = Clock::now();

    const auto& canonical = shards.front();
    std::uint64_t total_chunks = 0;
    std::uint64_t final_size = canonical.prelude.payload_offset;
    for (std::size_t i = 0; i < shards.size(); ++i) {
        auto& shard = shards[i];
        if (!rad::compatible_preludes(
                canonical.header, canonical.prelude, shard.header, shard.prelude)) {
            throw std::runtime_error("incompatible RAD prelude: " + describe(shard));
        }
        total_chunks = checked_add(total_chunks, shard.prelude.num_chunks, "RAD chunk count");
        shard.destination_offset = final_size;
        final_size = checked_add(final_size, shard.payload_size, "combined RAD");
    }
    if (final_size > static_cast<std::uint64_t>(std::numeric_limits<off_t>::max())) {
        throw std::overflow_error("combined RAD exceeds off_t");
    }

    auto combined_header = canonical.header;
    rad::write_u64_le(combined_header, canonical.prelude.num_chunks_offset, total_chunks);

    const auto parent = options.output.parent_path();
    if (!parent.empty()) {
        std::filesystem::create_directories(parent);
    }
    if (std::filesystem::exists(options.output) && !options.overwrite) {
        throw std::runtime_error("output already exists (use --overwrite): " + options.output.string());
    }
    auto partial = options.output;
    partial += ".partial";
    if (std::filesystem::exists(partial)) {
        if (!options.overwrite) {
            throw std::runtime_error("partial output already exists: " + partial.string());
        }
        std::filesystem::remove(partial);
    }

    const int raw_fd = ::open(partial.c_str(), O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0644);
    if (raw_fd < 0) {
        throw std::system_error(errno, std::generic_category(), "create " + partial.string());
    }
    FileDescriptor output(raw_fd);

    try {
        if (::ftruncate(output.get(), static_cast<off_t>(final_size)) != 0) {
            throw std::system_error(errno, std::generic_category(), "size output");
        }
        pwrite_all(
            output.get(),
            reinterpret_cast<const char*>(combined_header.data()),
            combined_header.size(),
            0);

        const auto payload_bytes = final_size - combined_header.size();
        const auto prepare_seconds = seconds_since(prepare_start);
        std::cerr << "Writing " << payload_bytes << " payload bytes directly from S3\n";
        const auto transfer_start = Clock::now();
        parallel_for(shards.size(), options.threads, [&](std::size_t index) {
            copy_payload(*client, shards[index], output.get(), options);
        });
        const auto transfer_seconds = seconds_since(transfer_start);
        const auto finalize_start = Clock::now();

        if (options.sync_output && ::fdatasync(output.get()) != 0) {
            throw std::system_error(errno, std::generic_category(), "fdatasync output");
        }
        output.close_checked();

        std::filesystem::rename(partial, options.output);

        const auto finalize_seconds = seconds_since(finalize_start);
        const auto total_seconds = seconds_since(total_start);
        const auto mib = static_cast<double>(payload_bytes) / (1024.0 * 1024.0);
        std::cout << std::fixed << std::setprecision(3)
                  << "shards=" << shards.size() << '\n'
                  << "chunks=" << total_chunks << '\n'
                  << "header_bytes=" << combined_header.size() << '\n'
                  << "payload_bytes=" << payload_bytes << '\n'
                  << "output_bytes=" << final_size << '\n'
                  << "setup_seconds=" << setup_seconds << '\n'
                  << "inspect_seconds=" << inspect_seconds << '\n'
                  << "prepare_seconds=" << prepare_seconds << '\n'
                  << "transfer_seconds=" << transfer_seconds << '\n'
                  << "finalize_seconds=" << finalize_seconds << '\n'
                  << "total_seconds=" << total_seconds << '\n'
                  << "payload_mib_per_second=" << (transfer_seconds > 0 ? mib / transfer_seconds : 0.0)
                  << '\n';
        return 0;
    } catch (...) {
        if (!options.keep_partial) {
            std::error_code ignored;
            std::filesystem::remove(partial, ignored);
        }
        throw;
    }
}

}  // namespace scrna::materializer
