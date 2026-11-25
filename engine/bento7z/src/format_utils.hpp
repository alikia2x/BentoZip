#pragma once

#include <bit7z/bitcompressionlevel.hpp>
#include <bit7z/bitformat.hpp>
#include <bit7z/bittypes.hpp>

#include <string>
#include <string_view>
#include <vector>

namespace bit7z {
class BitArchiveReader;
}

namespace bento7z {

enum class CompoundTarType {
    None,
    TarGz,
    TarBz2,
    TarXz,
    TarZst
};

struct SplitVolumeInfo {
    bool is_split = false;
    bool is_first_volume = true;
    bool is_numbered_001 = false; // .7z.001, .zip.001, .tar.001, .001
    std::string inner_format_hint; // e.g. "7z", "zip", "tar", "rar", ""
    std::string expected_first_volume;
};

std::string to_lower_ascii(std::string_view s);
bool starts_with(std::string_view s, std::string_view prefix);
bool ends_with_ci(std::string_view s, std::string_view suffix);

CompoundTarType compound_from_format_name(std::string_view fmt_lower);
CompoundTarType compound_from_path(std::string_view path);

const bit7z::BitInOutFormat& compound_outer_inout_format(CompoundTarType type);
const bit7z::BitInFormat& compound_outer_in_format(CompoundTarType type);

const bit7z::BitInOutFormat* resolve_out_format(std::string_view fmt_lower);
const bit7z::BitInFormat* resolve_in_format(std::string_view fmt_lower);
const bit7z::BitInFormat* resolve_outer_in_format(std::string_view fmt_lower);

std::string infer_compress_format_from_path(std::string_view archive_path);
std::string derive_inner_tar_name(const std::string& archive_path);
bit7z::BitCompressionLevel resolve_level(const std::string& level);

bool is_raw_single_stream_format(std::string_view fmt_lower);
bool format_supports_password(std::string_view fmt_lower);

SplitVolumeInfo detect_split_volume_info(const std::string& archive_path);
bool validate_split_archive_volumes(const std::string& archive_path,
                                    std::string& error_code,
                                    std::string& error_msg);
std::string find_missing_next_volume(const std::string& archive_path);

bool is_valid_tar_header(const std::vector<bit7z::byte_t>& buf);
bool is_inner_stream_tar(const bit7z::BitArchiveReader& outer_reader);

} // namespace bento7z
