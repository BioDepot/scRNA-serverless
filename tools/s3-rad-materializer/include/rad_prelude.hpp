#pragma once

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace scrna::rad {

class NeedMoreData final : public std::runtime_error {
public:
    NeedMoreData();
};

class InvalidRad final : public std::runtime_error {
public:
    explicit InvalidRad(const std::string& message);
};

struct PreludeInfo {
    std::uint64_t num_chunks{};
    std::size_t num_chunks_offset{};
    std::size_t payload_offset{};
};

// Parse through the file-level tag values. payload_offset is the byte offset of
// the first record chunk. NeedMoreData means the prefix should be extended.
PreludeInfo parse_prelude(const std::vector<std::uint8_t>& bytes);

// RAD headers are compatible when their complete serialized preludes and
// file-level tag values match, except for the per-shard num_chunks value.
bool compatible_preludes(
    const std::vector<std::uint8_t>& lhs,
    const PreludeInfo& lhs_info,
    const std::vector<std::uint8_t>& rhs,
    const PreludeInfo& rhs_info);

void write_u64_le(
    std::vector<std::uint8_t>& bytes,
    std::size_t offset,
    std::uint64_t value);

}  // namespace scrna::rad
