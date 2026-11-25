#include "path_safety.hpp"

#include <bit7z/bitarchivereader.hpp>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <utility>

namespace bento7z {

namespace fs = std::filesystem;

namespace {

bool is_windows_drive_prefix(std::string_view p) {
    return p.size() >= 2 &&
           std::isalpha(static_cast<unsigned char>(p[0])) != 0 &&
           p[1] == ':';
}

fs::path normalize_lexical_dir(const fs::path& input) {
    fs::path p = input.lexically_normal();
    while (p.has_relative_path() && (p.filename().empty() || p.filename() == ".")) {
        p = p.parent_path();
    }
    return p;
}

fs::path normalize_output_base(const std::string& output) {
    std::error_code ec;
    fs::path abs = fs::absolute(fs::path(output), ec);
    if (ec || abs.empty()) {
        abs = fs::path(output);
    }
    return normalize_lexical_dir(abs);
}

bool is_lexically_inside(const fs::path& candidate, const fs::path& base) {
    const fs::path norm_cand = normalize_lexical_dir(candidate);
    const fs::path norm_base = normalize_lexical_dir(base);

    for (const auto& comp : norm_cand) {
        if (comp == "..") {
            return false;
        }
    }

    auto b_it = norm_base.begin();
    auto c_it = norm_cand.begin();
    for (; b_it != norm_base.end(); ++b_it, ++c_it) {
        if (c_it == norm_cand.end() || *b_it != *c_it) {
            return false;
        }
    }
    return true;
}

bool validate_relative_item_path(std::string_view raw_path,
                                 const fs::path& output_base,
                                 fs::path& out_rel_path,
                                 std::string& reason) {
    if (raw_path.find('\0') != std::string_view::npos) {
        reason = "Archive item path contains a null byte";
        return false;
    }

    std::string norm(raw_path);
    std::replace(norm.begin(), norm.end(), '\\', '/');

    if (!norm.empty() && norm.front() == '/') {
        reason = "Unsafe absolute archive item path: " + std::string(raw_path);
        return false;
    }

    if (is_windows_drive_prefix(norm)) {
        reason = "Unsafe drive-qualified archive item path: " + std::string(raw_path);
        return false;
    }

    fs::path rel_path;
    size_t pos = 0;
    while (pos <= norm.size()) {
        const size_t next = norm.find('/', pos);
        const std::string_view comp = (next == std::string_view::npos)
            ? std::string_view(norm).substr(pos)
            : std::string_view(norm).substr(pos, next - pos);
        if (comp == "..") {
            reason = "Unsafe path traversal component '..' in archive item: " + std::string(raw_path);
            return false;
        }
        if (!comp.empty() && comp != ".") {
            rel_path /= fs::path(comp);
        }
        if (next == std::string_view::npos) {
            break;
        }
        pos = next + 1;
    }

    if (!rel_path.empty()) {
        const fs::path target = (output_base / rel_path).lexically_normal();
        if (!is_lexically_inside(target, output_base)) {
            reason = "Archive item path escapes output directory: " + std::string(raw_path);
            return false;
        }
    }

    out_rel_path = std::move(rel_path);
    return true;
}

bool validate_symlink_target(std::string_view raw_target,
                             std::string_view item_path,
                             const fs::path& item_rel_path,
                             const fs::path& output_base,
                             std::string& reason) {
    if (raw_target.empty()) {
        reason = "Empty symlink target in archive item: " + std::string(item_path);
        return false;
    }
    if (raw_target.find('\0') != std::string_view::npos) {
        reason = "Symlink target contains null byte in archive item: " + std::string(item_path);
        return false;
    }

    std::string norm(raw_target);
    std::replace(norm.begin(), norm.end(), '\\', '/');

    if (norm.front() == '/' || is_windows_drive_prefix(norm)) {
        reason = "Unsafe absolute symlink target '" + std::string(raw_target) +
                 "' in archive item: " + std::string(item_path);
        return false;
    }

    fs::path sym_parent = (output_base / item_rel_path).parent_path();
    fs::path target_rel;
    size_t pos = 0;
    while (pos <= norm.size()) {
        const size_t next = norm.find('/', pos);
        const std::string_view comp = (next == std::string_view::npos)
            ? std::string_view(norm).substr(pos)
            : std::string_view(norm).substr(pos, next - pos);
        if (!comp.empty()) {
            target_rel /= fs::path(comp);
        }
        if (next == std::string_view::npos) {
            break;
        }
        pos = next + 1;
    }

    const fs::path resolved = (sym_parent / target_rel).lexically_normal();
    if (!is_lexically_inside(resolved, output_base)) {
        reason = "Symlink target '" + std::string(raw_target) +
                 "' escapes output directory in archive item: " + std::string(item_path);
        return false;
    }
    return true;
}

bool validate_single_item_safe(const bit7z::BitArchiveReader& reader,
                               const bit7z::BitArchiveItemOffset& item,
                               const fs::path& output_base,
                               std::string& reason) {
    const std::string item_path = item.path();
    fs::path item_rel_path;
    if (!validate_relative_item_path(item_path, output_base, item_rel_path, reason)) {
        return false;
    }

    if (item.isSymLink()) {
        const auto sym_prop = item.itemProperty(bit7z::BitProperty::SymLink);
        if (sym_prop.isString()) {
            if (!validate_symlink_target(
                    sym_prop.getString(), item_path, item_rel_path, output_base, reason)) {
                return false;
            }
        } else if (!item.isDir()) {
            constexpr uint64_t kMaxSymlinkTargetBytes = 4096;
            if (item.size() == 0 || item.size() > kMaxSymlinkTargetBytes) {
                reason = "Unsafe symlink item without verifiable target: " + item_path;
                return false;
            }
            bit7z::buffer_t target_buf;
            reader.extractTo(target_buf, item.index());
            std::string target_str(
                reinterpret_cast<const char*>(target_buf.data()), target_buf.size());
            if (!validate_symlink_target(
                    target_str, item_path, item_rel_path, output_base, reason)) {
                return false;
            }
        }
    }
    return true;
}

} // namespace

std::string normalize_archive_path(std::string s) {
    std::replace(s.begin(), s.end(), '\\', '/');
    std::string collapsed;
    collapsed.reserve(s.size());
    for (char c : s) {
        if (c == '/' && !collapsed.empty() && collapsed.back() == '/') {
            continue;
        }
        collapsed.push_back(c);
    }
    while (collapsed.size() >= 2 && collapsed[0] == '.' && collapsed[1] == '/') {
        collapsed.erase(0, 2);
    }
    while (!collapsed.empty() && collapsed.front() == '/') {
        collapsed.erase(collapsed.begin());
    }
    while (!collapsed.empty() && collapsed.back() == '/') {
        collapsed.pop_back();
    }
    return collapsed;
}

bool is_safe_archive_path(std::string_view raw_path) {
    const fs::path dummy_base = normalize_output_base("safe_root");
    fs::path rel_out;
    std::string reason;
    return validate_relative_item_path(raw_path, dummy_base, rel_out, reason);
}

bool glob_match(std::string_view pattern, std::string_view text) {
    size_t p = 0;
    size_t t = 0;
    size_t star_p = std::string_view::npos;
    size_t star_t = 0;

    while (t < text.size()) {
        if (p < pattern.size() && (pattern[p] == '?' || pattern[p] == text[t])) {
            ++p;
            ++t;
        } else if (p < pattern.size() && pattern[p] == '*') {
            star_p = p++;
            star_t = t;
        } else if (star_p != std::string_view::npos) {
            p = star_p + 1;
            t = ++star_t;
        } else {
            return false;
        }
    }

    while (p < pattern.size() && pattern[p] == '*') {
        ++p;
    }
    return p == pattern.size();
}

CompiledExcludes compile_excludes(const std::vector<std::string>& excludes) {
    CompiledExcludes compiled;
    for (const auto& raw_pat : excludes) {
        if (raw_pat.empty()) continue;
        std::string pat = raw_pat;
        std::replace(pat.begin(), pat.end(), '\\', '/');
        while (!pat.empty() && pat.front() == '/') {
            pat.erase(pat.begin());
        }
        while (!pat.empty() && pat.back() == '/') {
            pat.pop_back();
        }
        if (pat.empty()) continue;

        if (pat.find('/') != std::string::npos) {
            compiled.path_patterns.push_back(std::move(pat));
        } else {
            compiled.basename_patterns.push_back(std::move(pat));
        }
    }
    return compiled;
}

bool is_excluded(const fs::path& item_path,
                 const fs::path& rel_path,
                 const CompiledExcludes& compiled) {
    if (compiled.empty()) return false;

    if (!compiled.path_patterns.empty()) {
        const std::string rel_generic = normalize_archive_path(rel_path.generic_string());
        for (const auto& pat : compiled.path_patterns) {
            if (glob_match(pat, rel_generic)) {
                return true;
            }
        }
    }

    if (!compiled.basename_patterns.empty()) {
        const std::string filename = item_path.filename().string();
        if (!filename.empty()) {
            for (const auto& pat : compiled.basename_patterns) {
                if (glob_match(pat, filename)) {
                    return true;
                }
            }
        }
        for (const auto& comp : rel_path) {
            const std::string comp_str = comp.string();
            if (comp_str.empty() || comp_str == "/") {
                continue;
            }
            for (const auto& pat : compiled.basename_patterns) {
                if (glob_match(pat, comp_str)) {
                    return true;
                }
            }
        }
    }

    return false;
}

bool is_excluded(const fs::path& item_path,
                 const fs::path& rel_path,
                 const std::vector<std::string>& excludes) {
    if (excludes.empty()) return false;
    return is_excluded(item_path, rel_path, compile_excludes(excludes));
}

bool validate_archive_items_safe(const bit7z::BitArchiveReader& reader,
                                 const std::string& output_dir,
                                 std::string& reason) {
    const fs::path output_base = normalize_output_base(output_dir);
    for (const auto& item : reader) {
        if (!validate_single_item_safe(reader, item, output_base, reason)) {
            return false;
        }
    }
    return true;
}

bool validate_selected_items_safe(const bit7z::BitArchiveReader& reader,
                                  const std::vector<uint32_t>& indices,
                                  const std::string& output_dir,
                                  std::string& reason) {
    const fs::path output_base = normalize_output_base(output_dir);
    for (uint32_t idx : indices) {
        const auto item = reader.itemAt(idx);
        if (!validate_single_item_safe(reader, item, output_base, reason)) {
            return false;
        }
    }
    return true;
}

} // namespace bento7z
