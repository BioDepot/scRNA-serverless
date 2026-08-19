#include "rad_prelude.hpp"

#include <algorithm>
#include <cstdint>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void append_u8(std::vector<std::uint8_t>& out, std::uint8_t value) {
    out.push_back(value);
}

void append_u16(std::vector<std::uint8_t>& out, std::uint16_t value) {
    out.push_back(static_cast<std::uint8_t>(value));
    out.push_back(static_cast<std::uint8_t>(value >> 8U));
}

void append_u32(std::vector<std::uint8_t>& out, std::uint32_t value) {
    for (unsigned int i = 0; i < 4; ++i) {
        out.push_back(static_cast<std::uint8_t>(value >> (8U * i)));
    }
}

void append_u64(std::vector<std::uint8_t>& out, std::uint64_t value) {
    for (unsigned int i = 0; i < 8; ++i) {
        out.push_back(static_cast<std::uint8_t>(value >> (8U * i)));
    }
}

void append_string(std::vector<std::uint8_t>& out, const std::string& value) {
    append_u16(out, static_cast<std::uint16_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}

void append_tag(
    std::vector<std::uint8_t>& out,
    const std::string& name,
    std::uint8_t kind,
    std::uint8_t length_kind = 0,
    std::uint8_t element_kind = 0) {
    append_string(out, name);
    append_u8(out, kind);
    if (kind == 7) {
        append_u8(out, length_kind);
        append_u8(out, element_kind);
    }
}

std::vector<std::uint8_t> make_rad(std::uint64_t chunks, std::uint8_t payload_seed = 0xa0) {
    std::vector<std::uint8_t> out;
    append_u8(out, 1);  // paired
    append_u64(out, 2);
    append_string(out, "tx0");
    append_string(out, "transcript-1");
    append_u64(out, chunks);

    append_u16(out, 2);  // file tags
    append_tag(out, "ref_lengths", 7, 3, 3);  // u32-length array of u32
    append_tag(out, "producer", 8);           // string

    append_u16(out, 1);  // read tags
    append_tag(out, "barcode", 3);

    append_u16(out, 1);  // alignment tags
    append_tag(out, "reference", 3);

    append_u32(out, 2);  // ref_lengths array length
    append_u32(out, 100);
    append_u32(out, 200);
    append_string(out, "piscem-test");

    for (std::uint8_t i = 0; i < 32; ++i) {
        append_u8(out, static_cast<std::uint8_t>(payload_seed + i));
    }
    return out;
}

void require(bool condition, const std::string& message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

void test_parse_and_patch() {
    auto bytes = make_rad(7);
    const auto info = scrna::rad::parse_prelude(bytes);
    require(info.num_chunks == 7, "num_chunks was not parsed");
    require(info.payload_offset + 32 == bytes.size(), "payload offset is incorrect");

    scrna::rad::write_u64_le(bytes, info.num_chunks_offset, 1234);
    const auto reparsed = scrna::rad::parse_prelude(bytes);
    require(reparsed.num_chunks == 1234, "num_chunks patch failed");
}

void test_need_more_data() {
    auto bytes = make_rad(1);
    bytes.resize(20);
    try {
        (void)scrna::rad::parse_prelude(bytes);
    } catch (const scrna::rad::NeedMoreData&) {
        return;
    }
    throw std::runtime_error("truncated prefix did not request more data");
}

void test_compatibility() {
    const auto first = make_rad(4, 0x10);
    const auto second = make_rad(9, 0x80);
    const auto first_info = scrna::rad::parse_prelude(first);
    const auto second_info = scrna::rad::parse_prelude(second);
    require(
        scrna::rad::compatible_preludes(first, first_info, second, second_info),
        "compatible preludes were rejected");

    auto incompatible = second;
    incompatible[0] = 0;  // change paired status
    const auto incompatible_info = scrna::rad::parse_prelude(incompatible);
    require(
        !scrna::rad::compatible_preludes(first, first_info, incompatible, incompatible_info),
        "incompatible preludes were accepted");
}

}  // namespace

int main() {
    try {
        test_parse_and_patch();
        test_need_more_data();
        test_compatibility();
        std::cout << "rad prelude tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "test failure: " << error.what() << '\n';
        return 1;
    }
}
