#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace bit7z {
class BitArchiveReader;
}

namespace bento7z {

struct CompiledExcludes {
    std::vector<std::string> path_patterns;     // normalized patterns containing '/'
    std::vector<std::string> basename_patterns; // normalized patterns without '/'

    bool empty() const noexcept {
        return path_patterns.empty() && basename_patterns.empty();
    }
};

std::string normalize_archive_path(std::string s);

bool normalize_strict_archive_path(std::string_view raw_path,
                                 bool allow_empty,
                                 std::string& out_norm,
                                 std::string& reason);

bool is_safe_archive_path(std::string_view raw_path);

bool glob_match(std::string_view pattern, std::string_view text);

CompiledExcludes compile_excludes(const std::vector<std::string>& excludes);

bool is_excluded(const std::filesystem::path& item_path,
                 const std::filesystem::path& rel_path,
                 const CompiledExcludes& compiled);

bool is_excluded(const std::filesystem::path& item_path,
                 const std::filesystem::path& rel_path,
                 const std::vector<std::string>& excludes);

bool validate_archive_items_safe(const bit7z::BitArchiveReader& reader,
                                 const std::string& output_dir,
                                 std::string& reason);

bool validate_selected_items_safe(const bit7z::BitArchiveReader& reader,
                                  const std::vector<uint32_t>& indices,
                                  const std::string& output_dir,
                                  std::string& reason);

} // namespace bento7z
