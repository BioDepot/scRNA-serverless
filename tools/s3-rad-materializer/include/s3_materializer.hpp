#pragma once

#include <cstddef>
#include <filesystem>
#include <string>

namespace scrna::materializer {

struct Options {
    std::filesystem::path manifest;
    std::filesystem::path output;
    std::string region;
    std::string profile;
    std::size_t threads{32};
    std::size_t buffer_size{8U * 1024U * 1024U};
    std::size_t initial_header_window{4U * 1024U * 1024U};
    std::size_t maximum_header_size{256U * 1024U * 1024U};
    unsigned int retries{4};
    bool overwrite{false};
    bool keep_partial{false};
    bool sync_output{false};
};

int run(const Options& options);

}  // namespace scrna::materializer
