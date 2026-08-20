#include "rad_prelude.hpp"

#include <algorithm>
#include <limits>
#include <sstream>

namespace scrna::rad {
namespace {

constexpr std::uint64_t kMaxReferences = 10'000'000;
constexpr std::uint16_t kMaxTags = 16'384;

struct TagType {
    std::uint8_t kind{};
    std::uint8_t length_kind{};
    std::uint8_t element_kind{};
};

class Cursor {
public:
    explicit Cursor(const std::vector<std::uint8_t>& bytes) : bytes_(bytes) {}

    std::size_t position() const { return position_; }

    std::uint8_t read_u8() {
        require(1);
        return bytes_[position_++];
    }

    std::uint16_t read_u16() {
        require(2);
        const auto value = static_cast<std::uint16_t>(bytes_[position_]) |
            (static_cast<std::uint16_t>(bytes_[position_ + 1]) << 8U);
        position_ += 2;
        return value;
    }

    std::uint64_t read_uint(std::size_t width) {
        if (width != 1 && width != 2 && width != 4 && width != 8) {
            throw InvalidRad("invalid RAD integer width");
        }
        require(width);
        std::uint64_t value = 0;
        for (std::size_t i = 0; i < width; ++i) {
            value |= static_cast<std::uint64_t>(bytes_[position_ + i]) << (8U * i);
        }
        position_ += width;
        return value;
    }

    std::uint64_t read_u64() { return read_uint(8); }

    void skip(std::uint64_t count) {
        if (count > std::numeric_limits<std::size_t>::max()) {
            throw InvalidRad("RAD field is too large for this platform");
        }
        const auto amount = static_cast<std::size_t>(count);
        require(amount);
        position_ += amount;
    }

private:
    void require(std::size_t count) const {
        if (position_ > bytes_.size() || count > bytes_.size() - position_) {
            throw NeedMoreData();
        }
    }

    const std::vector<std::uint8_t>& bytes_;
    std::size_t position_{0};
};

std::size_t integer_width(std::uint8_t kind) {
    switch (kind) {
        case 1: return 1;
        case 2: return 2;
        case 3: return 4;
        case 4: return 8;
        default: throw InvalidRad("invalid RAD integer type id " + std::to_string(kind));
    }
}

std::size_t fixed_atomic_width(std::uint8_t kind) {
    switch (kind) {
        case 0: return 1;  // bool
        case 1: return 1;  // u8
        case 2: return 2;  // u16
        case 3: return 4;  // u32
        case 4: return 8;  // u64
        case 5: return 4;  // f32
        case 6: return 8;  // f64
        case 8: throw InvalidRad("RAD strings do not have a fixed width");
        default: throw InvalidRad("invalid RAD atomic type id " + std::to_string(kind));
    }
}

TagType parse_tag_description(Cursor& cursor) {
    const auto name_length = cursor.read_u16();
    cursor.skip(name_length);

    TagType type;
    type.kind = cursor.read_u8();
    if (type.kind == 7) {
        type.length_kind = cursor.read_u8();
        type.element_kind = cursor.read_u8();
        (void)integer_width(type.length_kind);
        if (type.element_kind > 8 || type.element_kind == 7) {
            throw InvalidRad("invalid RAD array element type");
        }
    } else if (type.kind > 8 || type.kind == 7) {
        throw InvalidRad("invalid RAD tag type");
    }
    return type;
}

std::vector<TagType> parse_tag_section(Cursor& cursor) {
    const auto count = cursor.read_u16();
    if (count > kMaxTags) {
        throw InvalidRad("RAD tag count exceeds safety limit");
    }

    std::vector<TagType> tags;
    tags.reserve(count);
    for (std::uint16_t i = 0; i < count; ++i) {
        tags.push_back(parse_tag_description(cursor));
    }
    return tags;
}

void skip_string(Cursor& cursor) {
    const auto length = cursor.read_u16();
    cursor.skip(length);
}

void skip_tag_value(Cursor& cursor, const TagType& type) {
    if (type.kind == 8) {
        skip_string(cursor);
        return;
    }

    if (type.kind != 7) {
        cursor.skip(fixed_atomic_width(type.kind));
        return;
    }

    const auto length = cursor.read_uint(integer_width(type.length_kind));
    if (type.element_kind == 8) {
        for (std::uint64_t i = 0; i < length; ++i) {
            skip_string(cursor);
        }
        return;
    }

    const auto width = fixed_atomic_width(type.element_kind);
    if (length > std::numeric_limits<std::uint64_t>::max() / width) {
        throw InvalidRad("RAD array byte length overflow");
    }
    cursor.skip(length * width);
}

}  // namespace

NeedMoreData::NeedMoreData() : std::runtime_error("more RAD prefix data required") {}

InvalidRad::InvalidRad(const std::string& message) : std::runtime_error(message) {}

PreludeInfo parse_prelude(const std::vector<std::uint8_t>& bytes) {
    Cursor cursor(bytes);

    (void)cursor.read_u8();
    const auto reference_count = cursor.read_u64();
    if (reference_count > kMaxReferences) {
        throw InvalidRad("RAD reference count exceeds safety limit");
    }

    for (std::uint64_t i = 0; i < reference_count; ++i) {
        const auto name_length = cursor.read_u16();
        cursor.skip(name_length);
    }

    PreludeInfo info;
    info.num_chunks_offset = cursor.position();
    info.num_chunks = cursor.read_u64();

    const auto file_tags = parse_tag_section(cursor);
    (void)parse_tag_section(cursor);  // read-level tag descriptions
    (void)parse_tag_section(cursor);  // alignment-level tag descriptions

    for (const auto& tag : file_tags) {
        skip_tag_value(cursor, tag);
    }

    info.payload_offset = cursor.position();
    return info;
}

bool compatible_preludes(
    const std::vector<std::uint8_t>& lhs,
    const PreludeInfo& lhs_info,
    const std::vector<std::uint8_t>& rhs,
    const PreludeInfo& rhs_info) {
    if (lhs_info.payload_offset != rhs_info.payload_offset ||
        lhs_info.num_chunks_offset != rhs_info.num_chunks_offset ||
        lhs.size() < lhs_info.payload_offset || rhs.size() < rhs_info.payload_offset) {
        return false;
    }

    const auto chunks_begin = lhs_info.num_chunks_offset;
    const auto chunks_end = chunks_begin + sizeof(std::uint64_t);
    if (chunks_end > lhs_info.payload_offset) {
        return false;
    }

    return std::equal(lhs.begin(), lhs.begin() + static_cast<std::ptrdiff_t>(chunks_begin), rhs.begin()) &&
        std::equal(
            lhs.begin() + static_cast<std::ptrdiff_t>(chunks_end),
            lhs.begin() + static_cast<std::ptrdiff_t>(lhs_info.payload_offset),
            rhs.begin() + static_cast<std::ptrdiff_t>(chunks_end));
}

void write_u64_le(
    std::vector<std::uint8_t>& bytes,
    std::size_t offset,
    std::uint64_t value) {
    if (offset > bytes.size() || sizeof(value) > bytes.size() - offset) {
        throw InvalidRad("num_chunks offset is outside the RAD header");
    }
    for (std::size_t i = 0; i < sizeof(value); ++i) {
        bytes[offset + i] = static_cast<std::uint8_t>((value >> (8U * i)) & 0xffU);
    }
}

}  // namespace scrna::rad
