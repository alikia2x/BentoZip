#include "bento7z/commands.hpp"
#include "bento7z/progress.hpp"
#include "compound_tar.hpp"
#include "format_utils.hpp"
#include "path_safety.hpp"
#include "zip_encoding.hpp"

#include <bit7z/bitarchiveeditor.hpp>
#include <bit7z/bitarchivereader.hpp>
#include <bit7z/bitarchivewriter.hpp>
#include <bit7z/biterror.hpp>
#include <bit7z/bitexception.hpp>
#include <bit7z/bitformat.hpp>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <unordered_set>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <sys/stat.h>
#endif

namespace bento7z {

namespace fs = std::filesystem;

namespace {

bool is_inplace_unsupported_error(const bit7z::BitException& ex) {
    return ex.code() == bit7z::BitFailureSource::OperationNotSupported ||
           ex.code() == bit7z::BitError::FormatFeatureNotSupported ||
           ex.code() == bit7z::BitError::UnsupportedOperation;
}

uint64_t file_size_or_zero(const std::string& path) {
    std::error_code ec;
    const auto sz = fs::file_size(fs::path(path), ec);
    return ec ? 0 : static_cast<uint64_t>(sz);
}

std::string format_volume_suffix(int index) {
    std::string s = std::to_string(index);
    if (s.size() < 3) {
        s.insert(0, 3 - s.size(), '0');
    }
    return "." + s;
}

void cleanup_split_volumes(const std::string& base_archive_path) {
    std::error_code ec;
    for (int i = 1; i <= 999; ++i) {
        const fs::path p(base_archive_path + format_volume_suffix(i));
        if (!fs::exists(p, ec)) {
            if (i > 1) break;
            continue;
        }
        fs::remove(p, ec);
    }
}

uint64_t sum_split_volume_sizes(const std::string& base_archive_path) {
    std::error_code ec;
    uint64_t total = 0;
    for (int i = 1; i <= 999; ++i) {
        const fs::path p(base_archive_path + format_volume_suffix(i));
        if (!fs::exists(p, ec)) {
            break;
        }
        const auto sz = fs::file_size(p, ec);
        if (!ec) {
            total += static_cast<uint64_t>(sz);
        }
    }
    return total;
}

std::string decoded_item_name(const ZipEncodingResolver& resolver,
                              const std::string& decoded_path,
                              const std::string& raw_name) {
    if (!resolver.has_remapping()) {
        return raw_name;
    }
    if (!decoded_path.empty()) {
        std::string trimmed = decoded_path;
        while (!trimmed.empty() && (trimmed.back() == '/' || trimmed.back() == '\\')) {
            trimmed.pop_back();
        }
        const size_t slash = trimmed.find_last_of("/\\");
        if (slash != std::string::npos && slash + 1 < trimmed.size()) {
            return trimmed.substr(slash + 1);
        }
        if (!trimmed.empty()) {
            return trimmed;
        }
    }
    return resolver.decode(raw_name);
}

bool is_same_lstat_entry(const fs::path& a, const fs::path& b) {
#ifndef _WIN32
    struct stat sa{};
    struct stat sb{};
    if (::lstat(a.c_str(), &sa) == 0 && ::lstat(b.c_str(), &sb) == 0) {
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
    }
#else
    std::error_code ec;
    if (fs::equivalent(a, b, ec) && !ec) {
        return true;
    }
#endif
    return false;
}

bool ensure_real_dir_under_base(const fs::path& base,
                                const fs::path& target_dir,
                                std::string& error_msg) {
    const fs::path rel = target_dir.lexically_relative(base);
    if (rel.empty() || starts_with(rel.generic_string(), "..")) {
        error_msg = "Unsafe decoded ZIP parent path";
        return false;
    }

    fs::path cur = base;
    for (const auto& comp : rel) {
        const std::string comp_str = comp.string();
        if (comp_str.empty() || comp_str == ".") {
            continue;
        }
        cur /= comp;
        std::error_code ec;
        const fs::file_status st = fs::symlink_status(cur, ec);
        if (!ec && fs::exists(st)) {
            if (fs::is_symlink(st) || !fs::is_directory(st)) {
                error_msg = "Unsafe symlink or non-directory in output path: " + cur.string();
                return false;
            }
        } else if (!ec || ec == std::errc::no_such_file_or_directory) {
            std::error_code mk_ec;
            if (!fs::create_directory(cur, mk_ec) && mk_ec) {
                error_msg = "Failed to create output directory: " + mk_ec.message();
                return false;
            }
        } else {
            error_msg = "Failed to inspect output directory: " + ec.message();
            return false;
        }
    }
    return true;
}

bool rename_extracted_zip_paths(const fs::path& output_dir,
                                const std::vector<std::pair<std::string, std::string>>& remaps,
                                const std::vector<std::pair<std::string, std::string>>& dir_remaps,
                                std::string& error_msg) {
    std::error_code ec;
    const fs::path base = fs::weakly_canonical(output_dir, ec);
    if (ec) {
        error_msg = "Failed to resolve extraction output directory";
        return false;
    }

    auto verify_under_base = [&base](const std::string& rel) -> std::optional<fs::path> {
        if (!is_safe_archive_path(rel)) {
            return std::nullopt;
        }
        const fs::path joined = (base / fs::path(rel)).lexically_normal();
        const fs::path rel_check = joined.lexically_relative(base);
        if (rel_check.empty() || starts_with(rel_check.generic_string(), "..")) {
            return std::nullopt;
        }
        return joined;
    };

    std::vector<fs::path> cleanup_dirs;
    for (const auto& [raw_rel, decoded_rel] : remaps) {
        auto src_opt = verify_under_base(raw_rel);
        auto dst_opt = verify_under_base(decoded_rel);
        if (!src_opt || !dst_opt) {
            error_msg = "Unsafe decoded ZIP filename path: " + decoded_rel;
            return false;
        }
        const fs::file_status src_status = fs::symlink_status(*src_opt, ec);
        if (ec || !fs::exists(src_status) || *src_opt == *dst_opt) {
            continue;
        }

        if (dst_opt->has_parent_path()) {
            if (!ensure_real_dir_under_base(base, dst_opt->parent_path(), error_msg)) {
                return false;
            }
        }

        const fs::file_status dst_status = fs::symlink_status(*dst_opt, ec);
        if (ec && ec != std::errc::no_such_file_or_directory) {
            error_msg = "Failed to inspect destination path: " + ec.message();
            return false;
        }
        if (!ec && fs::exists(dst_status) && !is_same_lstat_entry(*src_opt, *dst_opt)) {
            error_msg = "Destination already exists while restoring filename encoding: " + decoded_rel;
            return false;
        }

        fs::rename(*src_opt, *dst_opt, ec);
        if (ec) {
            error_msg = "Failed to restore ZIP filename encoding: " + ec.message();
            return false;
        }
        fs::path cur = src_opt->parent_path();
        while (cur != base && cur.string().size() > base.string().size()) {
            cleanup_dirs.push_back(cur);
            cur = cur.parent_path();
        }
    }

    for (const auto& [raw_rel, decoded_rel] : dir_remaps) {
        auto src_opt = verify_under_base(raw_rel);
        auto dst_opt = verify_under_base(decoded_rel);
        if (!src_opt || !dst_opt) {
            error_msg = "Unsafe decoded ZIP directory path: " + decoded_rel;
            return false;
        }
        const fs::file_status dst_status = fs::symlink_status(*dst_opt, ec);
        if (ec && ec != std::errc::no_such_file_or_directory) {
            error_msg = "Failed to inspect decoded directory path: " + ec.message();
            return false;
        }
        if (!ec && fs::exists(dst_status)) {
            if (fs::is_symlink(dst_status) || !fs::is_directory(dst_status)) {
                error_msg = "Unsafe non-directory at decoded directory path: " + decoded_rel;
                return false;
            }
        } else if (!ensure_real_dir_under_base(base, *dst_opt, error_msg)) {
            return false;
        }

        const fs::file_status src_status = fs::symlink_status(*src_opt, ec);
        if (!ec && fs::exists(src_status) && !fs::is_symlink(src_status) && fs::is_directory(src_status)) {
            cleanup_dirs.push_back(*src_opt);
        }
    }

    std::sort(cleanup_dirs.begin(), cleanup_dirs.end(), [](const fs::path& a, const fs::path& b) {
        return a.generic_string().size() > b.generic_string().size();
    });
    cleanup_dirs.erase(std::unique(cleanup_dirs.begin(), cleanup_dirs.end()), cleanup_dirs.end());

    for (const auto& dir : cleanup_dirs) {
        const fs::file_status dir_status = fs::symlink_status(dir, ec);
        if (!ec && fs::exists(dir_status) && !fs::is_symlink(dir_status) &&
            fs::is_directory(dir_status) && fs::is_empty(dir, ec)) {
            fs::remove(dir, ec);
        }
    }
    return true;
}

std::vector<std::string> normalize_entry_targets(const std::vector<std::string>& raw_entries) {
    std::vector<std::string> norm_entries;
    norm_entries.reserve(raw_entries.size());
    for (const auto& raw_entry : raw_entries) {
        std::string norm = normalize_archive_path(raw_entry);
        if (!norm.empty()) {
            norm_entries.push_back(std::move(norm));
        }
    }
    return norm_entries;
}

bool match_entry_in_set(std::string_view norm_item,
                        const std::unordered_set<std::string_view>& target_set) {
    if (target_set.find(norm_item) != target_set.end()) {
        return true;
    }
    size_t slash = norm_item.find('/');
    while (slash != std::string_view::npos) {
        if (target_set.find(norm_item.substr(0, slash)) != target_set.end()) {
            return true;
        }
        slash = norm_item.find('/', slash + 1);
    }
    return false;
}

nlohmann::json build_list_result(const bit7z::BitArchiveReader& reader,
                                 const std::string& archive_path,
                                 std::optional<uint64_t> override_packed_size,
                                 bool used_tar_cache,
                                 std::string_view forced_encoding = "") {
    nlohmann::json result;
    result["archive"] = archive_path;
    result["items_count"] = reader.itemsCount();
    result["files_count"] = reader.filesCount();
    result["folders_count"] = reader.foldersCount();
    result["size"] = reader.size();
    result["packed_size"] = override_packed_size.value_or(reader.packSize());
    result["used_tar_cache"] = used_tar_cache;

    nlohmann::json items_arr = nlohmann::json::array();
    const ZipEncodingResolver zip_encoding(reader, forced_encoding);
    for (const auto& item : reader) {
        const std::string raw_path = item.path();
        const std::string decoded_path = zip_encoding.has_remapping() ? zip_encoding.decode(raw_path) : raw_path;
        ArchiveItem entry;
        entry.index = item.index();
        entry.name = decoded_item_name(zip_encoding, decoded_path, item.name());
        entry.path = decoded_path;
        entry.extension = item.extension();
        entry.is_dir = item.isDir();
        entry.size = item.size();
        entry.packed_size = item.packSize();
        entry.crc = item.crc();
        entry.encrypted = item.isEncrypted();
        entry.modified_at = extract_item_mtime(item);
        items_arr.push_back(nlohmann::json(entry));
    }
    result["items"] = std::move(items_arr);
    return result;
}

} // namespace

std::string classify_bit7z_error(const bit7z::BitException& ex, bool password_provided) {
    if (ex.code() == bit7z::BitFailureSource::WrongPassword) {
        return password_provided ? "WRONG_PASSWORD" : "PASSWORD_REQUIRED";
    }
    return "BIT7Z_ERROR";
}

std::optional<int64_t> extract_item_mtime(const bit7z::BitArchiveItemOffset& item) {
    const auto mtime_prop = item.itemProperty(bit7z::BitProperty::MTime);
    if (mtime_prop.isFileTime()) {
        const auto ft = mtime_prop.getFileTime();
        if (ft.dwHighDateTime != 0 || ft.dwLowDateTime != 0) {
            const auto tp = item.lastWriteTime();
            const auto secs = std::chrono::duration_cast<std::chrono::seconds>(
                tp.time_since_epoch()).count();
            return static_cast<int64_t>(secs);
        }
    }
    return std::nullopt;
}

const bit7z::BitInOutFormat* resolve_inplace_format(
    const bit7z::Bit7zLibrary& lib,
    const std::string& archive,
    const std::string& format,
    const std::string& password,
    std::string& error_code,
    std::string& error_msg) {
    const std::string fmt_lower = to_lower_ascii(format);

    if (compound_from_format_name(fmt_lower) != CompoundTarType::None ||
        ((fmt_lower.empty() || fmt_lower == "auto") &&
         compound_from_path(archive) != CompoundTarType::None)) {
        error_code = "UNSUPPORTED_INPLACE";
        error_msg = "In-place editing is not supported for compound tar archives";
        return nullptr;
    }

    if (!fmt_lower.empty() && fmt_lower != "auto") {
        if (fmt_lower == "zip") return &bit7z::BitFormat::Zip;
        if (fmt_lower == "7z")  return &bit7z::BitFormat::SevenZip;
        if (fmt_lower == "tar") return &bit7z::BitFormat::Tar;
        error_code = "UNSUPPORTED_INPLACE";
        error_msg = "In-place editing is not supported for format '" + format + "'";
        return nullptr;
    }

    std::error_code ec;
    if (!fs::exists(archive, ec)) {
        error_code = "PATH_NOT_FOUND";
        error_msg = "Archive not found: " + archive;
        return nullptr;
    }

    const bool password_provided = !password.empty();
    try {
        bit7z::BitArchiveReader probe(lib, archive, bit7z::BitFormat::Auto, password);
        const auto& detected = probe.detectedFormat();
        if (detected == bit7z::BitFormat::Zip)      return &bit7z::BitFormat::Zip;
        if (detected == bit7z::BitFormat::SevenZip) return &bit7z::BitFormat::SevenZip;
        if (detected == bit7z::BitFormat::Tar)      return &bit7z::BitFormat::Tar;
        error_code = "UNSUPPORTED_INPLACE";
        error_msg = "In-place editing is only supported for zip, 7z, and tar archives";
        return nullptr;
    } catch (const bit7z::BitException& ex) {
        error_code = classify_bit7z_error(ex, password_provided);
        error_msg = ex.what();
        return nullptr;
    }
}

bool extract_from_reader(bit7z::BitArchiveReader& reader,
                         const ExtractParams& params,
                         const ProgressSink* progress_sink,
                         std::atomic<bool>* cancel_flag,
                         std::string& error_msg,
                         std::string& error_code,
                         uint8_t progress_stage) {
    if (is_cancelled(cancel_flag)) {
        error_code = "CANCELLED";
        error_msg = "Operation cancelled";
        return false;
    }

    const ZipEncodingResolver zip_encoding(reader, params.encoding);

    auto collect_zip_remaps = [&](const std::unordered_set<uint32_t>* only_indices,
                                  std::vector<std::pair<std::string, std::string>>& file_remaps,
                                  std::vector<std::pair<std::string, std::string>>& dir_remaps) -> bool {
        if (!zip_encoding.has_remapping()) {
            return true;
        }
        for (const auto& item : reader) {
            if (only_indices != nullptr && only_indices->find(item.index()) == only_indices->end()) {
                continue;
            }
            const std::string raw_norm = normalize_archive_path(item.path());
            if (raw_norm.empty()) continue;
            const std::string decoded_raw = zip_encoding.decode(item.path());
            if (!is_safe_archive_path(decoded_raw)) {
                error_code = "PATH_TRAVERSAL";
                error_msg = "Archive contains unsafe entry path: " + decoded_raw;
                return false;
            }
            const std::string decoded_norm = normalize_archive_path(decoded_raw);
            if (!decoded_norm.empty() && decoded_norm != raw_norm) {
                if (item.isDir()) {
                    dir_remaps.emplace_back(raw_norm, decoded_norm);
                } else {
                    file_remaps.emplace_back(raw_norm, decoded_norm);
                }
            }
        }
        return true;
    };

    if (params.entries.empty()) {
        if (!validate_archive_items_safe(reader, params.output, error_msg)) {
            error_code = "PATH_TRAVERSAL";
            return false;
        }

        std::vector<std::pair<std::string, std::string>> file_remaps;
        std::vector<std::pair<std::string, std::string>> dir_remaps;
        if (!collect_zip_remaps(nullptr, file_remaps, dir_remaps)) {
            return false;
        }

        ScopedHandlerCallbacks cb_guard(reader);
        ProgressSink sink = (progress_sink != nullptr) ? *progress_sink : ProgressSink{};
        ProgressAdapter progress(std::move(sink), progress_stage, cancel_flag, reader.size());
        progress.attach(reader);

        std::error_code ec;
        fs::create_directories(params.output, ec);
        reader.extractTo(params.output);
        if (is_cancelled(cancel_flag)) {
            error_code = "CANCELLED";
            error_msg = "Operation cancelled";
            return false;
        }
        progress.complete();

        if (!file_remaps.empty() || !dir_remaps.empty()) {
            if (!rename_extracted_zip_paths(fs::path(params.output), file_remaps, dir_remaps, error_msg)) {
                error_code = "INTERNAL_ERROR";
                return false;
            }
        }
        return true;
    }

    const std::vector<std::string> norm_entries = normalize_entry_targets(params.entries);
    std::unordered_set<std::string_view> target_set;
    target_set.reserve(norm_entries.size());
    for (const auto& entry : norm_entries) {
        target_set.insert(entry);
    }

    std::vector<uint32_t> indices;
    std::unordered_set<uint32_t> index_set;
    if (!target_set.empty()) {
        uint32_t scanned = 0;
        for (const auto& item : reader) {
            if ((++scanned & 0x3FFu) == 0 && is_cancelled(cancel_flag)) {
                error_code = "CANCELLED";
                error_msg = "Operation cancelled";
                return false;
            }
            const std::string norm_item = normalize_archive_path(item.path());
            if (norm_item.empty()) continue;

            bool matched = match_entry_in_set(norm_item, target_set);
            if (!matched && zip_encoding.has_remapping()) {
                const std::string decoded_norm = normalize_archive_path(zip_encoding.decode(item.path()));
                if (!decoded_norm.empty()) {
                    matched = match_entry_in_set(decoded_norm, target_set);
                }
            }

            if (matched) {
                indices.push_back(item.index());
                index_set.insert(item.index());
            }
        }
    }

    if (indices.empty()) {
        error_msg = "None of the requested entries were found in the archive";
        error_code = "PATH_NOT_FOUND";
        return false;
    }

    if (!validate_selected_items_safe(reader, indices, params.output, error_msg)) {
        error_code = "PATH_TRAVERSAL";
        return false;
    }

    std::vector<std::pair<std::string, std::string>> file_remaps;
    std::vector<std::pair<std::string, std::string>> dir_remaps;
    if (!collect_zip_remaps(&index_set, file_remaps, dir_remaps)) {
        return false;
    }

    ScopedHandlerCallbacks cb_guard(reader);
    ProgressSink sink = (progress_sink != nullptr) ? *progress_sink : ProgressSink{};
    ProgressAdapter progress(std::move(sink), progress_stage, cancel_flag);
    progress.attach(reader);

    std::error_code ec;
    fs::create_directories(params.output, ec);
    reader.extractTo(params.output, indices);
    if (is_cancelled(cancel_flag)) {
        error_code = "CANCELLED";
        error_msg = "Operation cancelled";
        return false;
    }
    progress.complete();

    if (!file_remaps.empty() || !dir_remaps.empty()) {
        if (!rename_extracted_zip_paths(fs::path(params.output), file_remaps, dir_remaps, error_msg)) {
            error_code = "INTERNAL_ERROR";
            return false;
        }
    }
    return true;
}

OperationOutcome run_compress(const bit7z::Bit7zLibrary& lib,
                              const CompressParams& params,
                              const ProgressSink* progress_sink,
                              std::atomic<bool>* cancel_flag) {
    OperationOutcome out;
    if (params.archive.empty()) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Invalid 'compress' parameters";
        return out;
    }
    if (params.paths.empty()) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Invalid 'compress' parameters: 'paths' must not be empty";
        return out;
    }

    std::string fmt_lower = to_lower_ascii(params.format);
    if (fmt_lower.empty() || fmt_lower == "auto") {
        fmt_lower = infer_compress_format_from_path(params.archive);
    }

    const CompoundTarType compound = compound_from_format_name(fmt_lower);
    if (compound == CompoundTarType::TarZst) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Creating Zstandard compound archives (.tar.zst) is not supported yet";
        return out;
    }
    const bit7z::BitInOutFormat* fmt = (compound == CompoundTarType::None)
        ? resolve_out_format(fmt_lower)
        : nullptr;
    if (compound == CompoundTarType::None && !fmt) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Unsupported compression format: " + params.format;
        return out;
    }

    if (params.volume_size_bytes > 0 && fmt_lower != "7z" && fmt_lower != "zip") {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Multi-volume splitting is only supported for 7z and zip archives";
        return out;
    }

    if (!params.password.empty() && !format_supports_password(fmt_lower)) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Password encryption is not supported for format '" + fmt_lower +
                        "' (supported formats: 7z, zip)";
        return out;
    }

    try {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
            return out;
        }

        if (params.volume_size_bytes > 0) {
            cleanup_split_volumes(params.archive);
        }

        std::string missing_path;
        if (compound != CompoundTarType::None) {
            if (!compress_compound_tar(lib, compound, params, progress_sink, cancel_flag, missing_path)) {
                out.error_code = "PATH_NOT_FOUND";
                out.error_msg = "Path not found: " + missing_path;
                return out;
            }
        } else {
            bit7z::BitArchiveWriter writer(lib, *fmt);
            writer.setThreadsCount(hardware_threads_or_one());
            writer.setCompressionLevel(resolve_level(params.level));
            writer.setRetainDirectories(false);

            if (params.volume_size_bytes > 0) {
                writer.setVolumeSize(params.volume_size_bytes);
            }

            if (!params.password.empty()) {
                const bool crypt_headers = (*fmt == bit7z::BitFormat::SevenZip);
                writer.setPassword(params.password, crypt_headers);
                if (*fmt == bit7z::BitFormat::Zip) {
                    const std::string em = to_lower_ascii(params.encryption_method);
                    if (em == "zipcrypto") {
                        writer.setFormatProperty(L"em", L"ZipCrypto");
                    } else if (em == "aes256" || em == "aes") {
                        writer.setFormatProperty(L"em", L"AES256");
                    }
                }
            }

            ProgressSink sink = (progress_sink != nullptr) ? *progress_sink : ProgressSink{};
            ProgressAdapter progress(std::move(sink), ProgressStage::Normal, cancel_flag);
            progress.attach(writer);

            if (!add_paths_to_writer(writer, params, missing_path, cancel_flag)) {
                if (params.volume_size_bytes > 0) cleanup_split_volumes(params.archive);
                out.error_code = "PATH_NOT_FOUND";
                out.error_msg = "Path not found: " + missing_path;
                return out;
            }
            writer.compressTo(params.archive);
            if (is_cancelled(cancel_flag)) {
                if (params.volume_size_bytes > 0) cleanup_split_volumes(params.archive);
                out.error_code = "CANCELLED";
                out.error_msg = "Operation cancelled";
                return out;
            }
            progress.flush();
        }

        out.ok = true;
        out.output_size = (params.volume_size_bytes > 0)
            ? sum_split_volume_sizes(params.archive)
            : file_size_or_zero(params.archive);
        return out;
    } catch (const OperationCancelled&) {
        if (params.volume_size_bytes > 0) cleanup_split_volumes(params.archive);
        out.error_code = "CANCELLED";
        out.error_msg = "Operation cancelled";
        return out;
    } catch (const bit7z::BitException& ex) {
        if (params.volume_size_bytes > 0) cleanup_split_volumes(params.archive);
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
        } else {
            out.error_code = "BIT7Z_ERROR";
            out.error_msg = ex.what();
        }
        return out;
    } catch (const std::exception& ex) {
        if (params.volume_size_bytes > 0) cleanup_split_volumes(params.archive);
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
        } else {
            out.error_code = "INTERNAL_ERROR";
            out.error_msg = ex.what();
        }
        return out;
    }
}

OperationOutcome run_add(const bit7z::Bit7zLibrary& lib,
                         const AddParams& params,
                         const ProgressSink* progress_sink,
                         std::atomic<bool>* cancel_flag) {
    OperationOutcome out;
    if (params.archive.empty() || params.paths.empty()) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Invalid 'add' parameters";
        return out;
    }

    std::string norm_prefix;
    std::string prefix_err;
    if (!normalize_strict_archive_path(params.target_prefix, /*allow_empty=*/true, norm_prefix, prefix_err)) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Invalid target_prefix: " + prefix_err;
        return out;
    }

    const bit7z::BitInOutFormat* fmt = resolve_inplace_format(
        lib, params.archive, params.format, params.password, out.error_code, out.error_msg);
    if (!fmt) {
        return out;
    }

    std::error_code ec;
    if (!fs::exists(params.archive, ec)) {
        out.error_code = "PATH_NOT_FOUND";
        out.error_msg = "Archive not found: " + params.archive;
        return out;
    }

    const bool password_provided = !params.password.empty();
    try {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
            return out;
        }

        bit7z::BitArchiveEditor editor(lib, params.archive, *fmt, params.password);
        editor.setUpdateMode(bit7z::UpdateMode::Update);
        editor.setThreadsCount(hardware_threads_or_one());
        editor.setRetainDirectories(false);

        ProgressSink sink = (progress_sink != nullptr) ? *progress_sink : ProgressSink{};
        ProgressAdapter progress(std::move(sink), ProgressStage::Normal, cancel_flag);
        progress.attach(editor);

        CompressParams add_as_compress;
        add_as_compress.archive = params.archive;
        add_as_compress.paths = params.paths;
        add_as_compress.preserve_paths = true;

        std::string missing_path;
        if (!add_paths_to_writer(editor, add_as_compress, missing_path, cancel_flag, norm_prefix)) {
            out.error_code = "PATH_NOT_FOUND";
            out.error_msg = "Path not found: " + missing_path;
            return out;
        }

        editor.applyChanges();
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
            return out;
        }
        progress.flush();

        out.ok = true;
        out.output_size = file_size_or_zero(params.archive);
        return out;
    } catch (const OperationCancelled&) {
        out.error_code = "CANCELLED";
        out.error_msg = "Operation cancelled";
        return out;
    } catch (const bit7z::BitException& ex) {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
        } else if (is_inplace_unsupported_error(ex)) {
            out.error_code = "UNSUPPORTED_INPLACE";
            out.error_msg = ex.what();
        } else {
            out.error_code = classify_bit7z_error(ex, password_provided);
            out.error_msg = ex.what();
        }
        return out;
    } catch (const std::exception& ex) {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
        } else {
            out.error_code = "INTERNAL_ERROR";
            out.error_msg = ex.what();
        }
        return out;
    }
}

OperationOutcome run_delete(const bit7z::Bit7zLibrary& lib,
                            const DeleteParams& params,
                            const ProgressSink* progress_sink,
                            std::atomic<bool>* cancel_flag) {
    OperationOutcome out;
    if (params.archive.empty() || params.entries.empty()) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Invalid 'delete' parameters";
        return out;
    }

    const bit7z::BitInOutFormat* fmt = resolve_inplace_format(
        lib, params.archive, params.format, params.password, out.error_code, out.error_msg);
    if (!fmt) {
        return out;
    }

    std::error_code ec;
    if (!fs::exists(params.archive, ec)) {
        out.error_code = "PATH_NOT_FOUND";
        out.error_msg = "Archive not found: " + params.archive;
        return out;
    }

    const std::vector<std::string> norm_entries = normalize_entry_targets(params.entries);
    if (norm_entries.empty()) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "No valid entry paths specified for delete";
        return out;
    }

    std::unordered_set<std::string_view> target_set;
    target_set.reserve(norm_entries.size());
    for (const auto& entry : norm_entries) {
        target_set.insert(entry);
    }

    const bool password_provided = !params.password.empty();
    try {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
            return out;
        }

        uint32_t total_items = 0;
        std::vector<uint32_t> matched_indices;
        {
            bit7z::BitArchiveReader reader(lib, params.archive, *fmt, params.password);
            const ZipEncodingResolver zip_encoding(reader);
            total_items = reader.itemsCount();
            for (const auto& item : reader) {
                const std::string norm_raw = normalize_archive_path(item.path());
                if (norm_raw.empty()) continue;

                bool matched = match_entry_in_set(norm_raw, target_set);
                if (!matched && zip_encoding.has_remapping()) {
                    const std::string norm_decoded = normalize_archive_path(zip_encoding.decode(item.path()));
                    if (!norm_decoded.empty()) {
                        matched = match_entry_in_set(norm_decoded, target_set);
                    }
                }
                if (matched) {
                    matched_indices.push_back(item.index());
                }
            }
        }

        if (matched_indices.empty()) {
            out.error_code = "PATH_NOT_FOUND";
            out.error_msg = "None of the requested entries were found in the archive";
            return out;
        }

        if (matched_indices.size() >= total_items) {
            std::error_code rem_ec;
            fs::remove(params.archive, rem_ec);
            if (rem_ec) {
                out.error_code = "INTERNAL_ERROR";
                out.error_msg = "Failed to remove empty archive: " + rem_ec.message();
                return out;
            }
            out.ok = true;
            out.archive_deleted = true;
            out.output_size = 0;
            return out;
        }

        bit7z::BitArchiveEditor editor(lib, params.archive, *fmt, params.password);
        editor.setThreadsCount(hardware_threads_or_one());

        for (uint32_t idx : matched_indices) {
            editor.deleteItem(idx, bit7z::DeletePolicy::ItemOnly);
        }

        ProgressSink sink = (progress_sink != nullptr) ? *progress_sink : ProgressSink{};
        ProgressAdapter progress(std::move(sink), ProgressStage::Normal, cancel_flag);
        progress.attach(editor);

        editor.applyChanges();
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
            return out;
        }
        progress.flush();

        out.ok = true;
        out.archive_deleted = false;
        out.output_size = file_size_or_zero(params.archive);
        return out;
    } catch (const OperationCancelled&) {
        out.error_code = "CANCELLED";
        out.error_msg = "Operation cancelled";
        return out;
    } catch (const bit7z::BitException& ex) {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
        } else if (is_inplace_unsupported_error(ex)) {
            out.error_code = "UNSUPPORTED_INPLACE";
            out.error_msg = ex.what();
        } else {
            out.error_code = classify_bit7z_error(ex, password_provided);
            out.error_msg = ex.what();
        }
        return out;
    } catch (const std::exception& ex) {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
        } else {
            out.error_code = "INTERNAL_ERROR";
            out.error_msg = ex.what();
        }
        return out;
    }
}

OperationOutcome run_rename(const bit7z::Bit7zLibrary& lib,
                            const RenameParams& params,
                            const ProgressSink* progress_sink,
                            std::atomic<bool>* cancel_flag) {
    OperationOutcome out;
    if (params.archive.empty() || params.old_path.empty() || params.new_path.empty()) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Invalid 'rename' parameters";
        return out;
    }

    std::string old_norm;
    std::string new_norm;
    std::string path_err;
    if (!normalize_strict_archive_path(params.old_path, /*allow_empty=*/false, old_norm, path_err)) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Invalid old_path: " + path_err;
        return out;
    }
    if (!normalize_strict_archive_path(params.new_path, /*allow_empty=*/false, new_norm, path_err)) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Invalid new_path: " + path_err;
        return out;
    }
    if (starts_with(new_norm, old_norm + "/")) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Cannot rename an entry into its own descendant path";
        return out;
    }

    const bit7z::BitInOutFormat* fmt = resolve_inplace_format(
        lib, params.archive, params.format, params.password, out.error_code, out.error_msg);
    if (!fmt) {
        return out;
    }

    std::error_code ec;
    if (!fs::exists(params.archive, ec)) {
        out.error_code = "PATH_NOT_FOUND";
        out.error_msg = "Archive not found: " + params.archive;
        return out;
    }

    const bool password_provided = !params.password.empty();
    try {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
            return out;
        }

        struct RenameTarget {
            uint32_t index;
            std::string orig_norm;
            std::string new_norm;
            bool is_dir;
            bool is_symlink;
        };
        std::vector<RenameTarget> renames;
        std::vector<uint32_t> matched_list;
        ScopedTempDir tar_temp_dir;
        {
            bit7z::BitArchiveReader reader(lib, params.archive, *fmt, params.password);
            const ZipEncodingResolver zip_encoding(reader);
            std::unordered_set<uint32_t> matched_indices;
            const std::string old_prefix = old_norm + "/";

            for (const auto& item : reader) {
                const std::string raw_norm = normalize_archive_path(item.path());
                if (raw_norm.empty()) continue;

                const std::string decoded_norm = zip_encoding.has_remapping()
                    ? normalize_archive_path(zip_encoding.decode(item.path()))
                    : raw_norm;

                std::optional<std::string> updated_path;
                if (raw_norm == old_norm) {
                    updated_path = new_norm;
                } else if (starts_with(raw_norm, old_prefix)) {
                    updated_path = new_norm + raw_norm.substr(old_norm.size());
                } else if (zip_encoding.has_remapping() && !decoded_norm.empty()) {
                    if (decoded_norm == old_norm) {
                        updated_path = new_norm;
                    } else if (starts_with(decoded_norm, old_prefix)) {
                        updated_path = new_norm + decoded_norm.substr(old_norm.size());
                    }
                }

                if (updated_path.has_value()) {
                    matched_indices.insert(item.index());
                    matched_list.push_back(item.index());
                    renames.push_back(RenameTarget{
                        item.index(), raw_norm, std::move(*updated_path), item.isDir(), item.isSymLink()});
                }
            }

            if (renames.empty()) {
                out.error_code = "PATH_NOT_FOUND";
                out.error_msg = "Path not found in archive: " + old_norm;
                return out;
            }

            if (old_norm == new_norm) {
                out.ok = true;
                out.archive_deleted = false;
                out.output_size = file_size_or_zero(params.archive);
                return out;
            }

            const std::string new_prefix = new_norm + "/";
            for (const auto& item : reader) {
                if (matched_indices.find(item.index()) != matched_indices.end()) {
                    continue;
                }
                const std::string other_raw = normalize_archive_path(item.path());
                if (other_raw.empty()) continue;
                const std::string other_decoded = zip_encoding.has_remapping()
                    ? normalize_archive_path(zip_encoding.decode(item.path()))
                    : other_raw;

                auto conflicts = [&](const std::string& candidate) -> bool {
                    if (candidate.empty()) return false;
                    return candidate == new_norm ||
                           starts_with(candidate, new_prefix) ||
                           (!item.isDir() && starts_with(new_norm, candidate + "/"));
                };

                if (conflicts(other_raw) || (zip_encoding.has_remapping() && conflicts(other_decoded))) {
                    out.error_code = "CONFLICT";
                    out.error_msg = "Target path already exists in archive: " + new_norm;
                    return out;
                }
            }

            if (*fmt == bit7z::BitFormat::Tar) {
                for (const auto& t : renames) {
                    if (t.is_symlink) {
                        out.error_code = "UNSUPPORTED_INPLACE";
                        out.error_msg = "In-place rename of symbolic links in TAR archives is not supported";
                        return out;
                    }
                }
                std::string safety_err;
                if (!validate_selected_items_safe(reader, matched_list, tar_temp_dir.string(), safety_err)) {
                    out.error_code = "PATH_TRAVERSAL";
                    out.error_msg = safety_err;
                    return out;
                }
                reader.extractTo(tar_temp_dir.string(), matched_list);
                if (is_cancelled(cancel_flag)) {
                    out.error_code = "CANCELLED";
                    out.error_msg = "Operation cancelled";
                    return out;
                }
            }
        }

        // bit7z's BitArchiveEditor::renameItem fails on TAR because 7-Zip's TAR handler
        // does not expose BitProperty::Attrib (kpidAttrib). Delete matched items and
        // re-add the extracted items under the new paths.
        if (*fmt == bit7z::BitFormat::Tar) {
            for (const auto& t : renames) {
                const fs::path extracted = tar_temp_dir.path() / fs::path(t.orig_norm);
                std::error_code item_ec;
                const fs::file_status st = fs::symlink_status(extracted, item_ec);
                if (!item_ec && fs::exists(st) && fs::is_symlink(st)) {
                    out.error_code = "UNSUPPORTED_INPLACE";
                    out.error_msg = "In-place rename of symbolic links in TAR archives is not supported";
                    return out;
                }
            }

            bit7z::BitArchiveEditor editor(lib, params.archive, *fmt, params.password);
            editor.setThreadsCount(hardware_threads_or_one());
            editor.setRetainDirectories(false);
            for (uint32_t idx : matched_list) {
                editor.deleteItem(idx, bit7z::DeletePolicy::ItemOnly);
            }
            for (const auto& t : renames) {
                const fs::path extracted = tar_temp_dir.path() / fs::path(t.orig_norm);
                std::error_code item_ec;
                const fs::file_status st = fs::symlink_status(extracted, item_ec);
                if (item_ec || !fs::exists(st) || fs::is_symlink(st)) {
                    continue;
                }
                if (!t.is_dir) {
                    editor.addFile(extracted.string(), t.new_norm);
                } else if (fs::is_empty(extracted, item_ec)) {
                    editor.addItems(std::vector<std::pair<std::string, std::string>>{
                        {extracted.string(), t.new_norm}
                    });
                }
            }

            ProgressSink sink = (progress_sink != nullptr) ? *progress_sink : ProgressSink{};
            ProgressAdapter progress(std::move(sink), ProgressStage::Normal, cancel_flag);
            progress.attach(editor);

            editor.applyChanges();
            if (is_cancelled(cancel_flag)) {
                out.error_code = "CANCELLED";
                out.error_msg = "Operation cancelled";
                return out;
            }
            progress.flush();

            out.ok = true;
            out.archive_deleted = false;
            out.output_size = file_size_or_zero(params.archive);
            return out;
        }

        bit7z::BitArchiveEditor editor(lib, params.archive, *fmt, params.password);
        editor.setThreadsCount(hardware_threads_or_one());
        for (const auto& t : renames) {
            editor.renameItem(t.index, t.new_norm);
        }

        ProgressSink sink = (progress_sink != nullptr) ? *progress_sink : ProgressSink{};
        ProgressAdapter progress(std::move(sink), ProgressStage::Normal, cancel_flag);
        progress.attach(editor);

        editor.applyChanges();
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
            return out;
        }
        progress.flush();

        out.ok = true;
        out.archive_deleted = false;
        out.output_size = file_size_or_zero(params.archive);
        return out;
    } catch (const OperationCancelled&) {
        out.error_code = "CANCELLED";
        out.error_msg = "Operation cancelled";
        return out;
    } catch (const bit7z::BitException& ex) {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
        } else if (is_inplace_unsupported_error(ex)) {
            out.error_code = "UNSUPPORTED_INPLACE";
            out.error_msg = ex.what();
        } else {
            out.error_code = classify_bit7z_error(ex, password_provided);
            out.error_msg = ex.what();
        }
        return out;
    } catch (const std::exception& ex) {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
        } else {
            out.error_code = "INTERNAL_ERROR";
            out.error_msg = ex.what();
        }
        return out;
    }
}

OperationOutcome run_test(const bit7z::Bit7zLibrary& lib,
                          const TestParams& params,
                          const ProgressSink* progress_sink,
                          std::atomic<bool>* cancel_flag) {
    OperationOutcome out;
    if (params.archive.empty()) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Invalid 'test' parameters";
        return out;
    }

    const std::string fmt_lower = to_lower_ascii(params.format);
    const bit7z::BitInFormat* outer_fmt = resolve_outer_in_format(fmt_lower);
    if (!outer_fmt) {
        out.error_code = "INVALID_PARAMS";
        out.error_msg = "Unsupported archive format: " + params.format;
        return out;
    }

    std::string split_err_code;
    std::string split_err_msg;
    if (!validate_split_archive_volumes(params.archive, split_err_code, split_err_msg)) {
        out.error_code = split_err_code;
        out.error_msg = split_err_msg;
        return out;
    }

    std::error_code ec;
    if (!fs::exists(params.archive, ec)) {
        out.error_code = "PATH_NOT_FOUND";
        out.error_msg = "Archive not found: " + params.archive;
        return out;
    }

    const bool password_provided = !params.password.empty();
    try {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
            return out;
        }

        bit7z::BitArchiveReader outer_reader(lib, params.archive, *outer_fmt, params.password);
        with_resolved_reader(
            lib, outer_reader, params.archive, fmt_lower, params.tar_cache_path,
            progress_sink, cancel_flag,
            [&](bit7z::BitArchiveReader& reader, std::optional<uint64_t> outer_pack_size, bool used_tar_cache) {
                if (used_tar_cache) {
                    ScopedHandlerCallbacks outer_cb(outer_reader);
                    ProgressSink outer_sink = (progress_sink != nullptr) ? *progress_sink : ProgressSink{};
                    ProgressAdapter outer_progress(
                        std::move(outer_sink),
                        ProgressStage::UnpackingOuter,
                        cancel_flag,
                        outer_pack_size.value_or(0));
                    outer_progress.attach(outer_reader);
                    outer_reader.test();
                    if (is_cancelled(cancel_flag)) {
                        throw OperationCancelled();
                    }
                    outer_progress.complete();
                }

                const uint8_t stage = outer_pack_size.has_value()
                    ? ProgressStage::ExtractingInner
                    : ProgressStage::Normal;
                ScopedHandlerCallbacks cb_guard(reader);
                ProgressSink sink = (progress_sink != nullptr) ? *progress_sink : ProgressSink{};
                ProgressAdapter progress(std::move(sink), stage, cancel_flag, reader.size());
                progress.attach(reader);

                reader.test();
                if (is_cancelled(cancel_flag)) {
                    throw OperationCancelled();
                }
                progress.complete();

                out.output_size = reader.itemsCount();
            });

        out.ok = true;
        out.archive_deleted = false;
        return out;
    } catch (const OperationCancelled&) {
        out.error_code = "CANCELLED";
        out.error_msg = "Operation cancelled";
        return out;
    } catch (const bit7z::BitException& ex) {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
        } else if (ex.code() == bit7z::BitFailureSource::WrongPassword) {
            out.error_code = password_provided ? "WRONG_PASSWORD" : "PASSWORD_REQUIRED";
            out.error_msg = ex.what();
        } else if (ex.code() == bit7z::BitFailureSource::CRCError ||
                   ex.code() == bit7z::BitFailureSource::DataError ||
                   ex.code() == bit7z::BitFailureSource::HeadersError ||
                   ex.code() == bit7z::BitFailureSource::UnexpectedEnd ||
                   ex.code() == bit7z::BitFailureSource::UnavailableData ||
                   ex.code() == bit7z::BitFailureSource::InvalidArchive ||
                   ex.code() == bit7z::BitFailureSource::DataAfterEnd) {
            out.error_code = "CORRUPT_ARCHIVE";
            out.error_msg = ex.what();
        } else {
            const std::string missing_vol = find_missing_next_volume(params.archive);
            if (!missing_vol.empty()) {
                out.error_code = "MISSING_VOLUME";
                out.error_msg = "Missing archive volume: " + missing_vol;
            } else {
                out.error_code = "BIT7Z_ERROR";
                out.error_msg = ex.what();
            }
        }
        return out;
    } catch (const std::exception& ex) {
        if (is_cancelled(cancel_flag)) {
            out.error_code = "CANCELLED";
            out.error_msg = "Operation cancelled";
        } else {
            out.error_code = "INTERNAL_ERROR";
            out.error_msg = ex.what();
        }
        return out;
    }
}

CommandHandler::CommandHandler(const std::string& lib_path)
    : lib_(lib_path) {}

void CommandHandler::execute(const Request& req) {
    try {
        if (req.command == "list") {
            handle_list(req);
        } else if (req.command == "compress") {
            handle_compress(req);
        } else if (req.command == "extract") {
            handle_extract(req);
        } else if (req.command == "add") {
            handle_add(req);
        } else if (req.command == "delete") {
            handle_delete(req);
        } else if (req.command == "rename") {
            handle_rename(req);
        } else if (req.command == "test") {
            handle_test(req);
        } else {
            make_error(req.id, "Unknown command: " + req.command, "UNKNOWN_COMMAND")
                .write(std::cout);
        }
    } catch (const bit7z::BitException& ex) {
        make_error(req.id, ex.what(), "BIT7Z_ERROR").write(std::cout);
    } catch (const std::exception& ex) {
        make_error(req.id, ex.what(), "INTERNAL_ERROR").write(std::cout);
    }
}

void CommandHandler::handle_list(const Request& req) {
    auto params = req.as_list();
    if (!params || params->archive.empty()) {
        make_error(req.id, "Invalid 'list' parameters", "INVALID_PARAMS").write(std::cout);
        return;
    }

    const std::string fmt_lower = to_lower_ascii(params->format);
    const bit7z::BitInFormat* outer_fmt = resolve_outer_in_format(fmt_lower);
    if (!outer_fmt) {
        make_error(req.id, "Unsupported archive format: " + params->format, "INVALID_PARAMS")
            .write(std::cout);
        return;
    }

    const bool password_provided = !params->password.empty();
    const ProgressSink sink = make_jsonl_progress_sink(req.id);
    std::string split_err_code;
    std::string split_err_msg;
    if (!validate_split_archive_volumes(params->archive, split_err_code, split_err_msg)) {
        make_error(req.id, split_err_msg, split_err_code).write(std::cout);
        return;
    }
    try {
        bit7z::BitArchiveReader outer_reader(lib_, params->archive, *outer_fmt, params->password);
        with_resolved_reader(
            lib_, outer_reader, params->archive, fmt_lower, params->tar_cache_path, &sink, nullptr,
            [&](bit7z::BitArchiveReader& reader, std::optional<uint64_t> outer_pack_size, bool used_tar_cache) {
                auto result = build_list_result(
                    reader, params->archive, outer_pack_size, used_tar_cache, params->encoding);
                make_result(req.id, std::move(result)).write(std::cout);
            });
    } catch (const bit7z::BitException& ex) {
        const std::string code = classify_bit7z_error(ex, password_provided);
        if (code == "BIT7Z_ERROR") {
            const std::string missing_vol = find_missing_next_volume(params->archive);
            if (!missing_vol.empty()) {
                make_error(req.id, "Missing archive volume: " + missing_vol, "MISSING_VOLUME")
                    .write(std::cout);
                return;
            }
        }
        make_error(req.id, ex.what(), code).write(std::cout);
    }
}

void CommandHandler::handle_compress(const Request& req) {
    auto params = req.as_compress();
    if (!params) {
        make_error(req.id, "Invalid 'compress' parameters", "INVALID_PARAMS").write(std::cout);
        return;
    }

    const ProgressSink sink = make_jsonl_progress_sink(req.id);
    const OperationOutcome out = run_compress(lib_, *params, &sink, nullptr);
    if (!out.ok) {
        make_error(req.id, out.error_msg, out.error_code).write(std::cout);
        return;
    }

    nlohmann::json result;
    result["archive"] = params->archive;
    result["paths_count"] = params->paths.size();
    result["output_size"] = out.output_size;
    make_result(req.id, std::move(result)).write(std::cout);
}

void CommandHandler::handle_extract(const Request& req) {
    auto params = req.as_extract();
    if (!params || params->archive.empty() || params->output.empty()) {
        make_error(req.id, "Invalid 'extract' parameters", "INVALID_PARAMS").write(std::cout);
        return;
    }

    const std::string fmt_lower = to_lower_ascii(params->format);
    const bit7z::BitInFormat* outer_fmt = resolve_outer_in_format(fmt_lower);
    if (!outer_fmt) {
        make_error(req.id, "Unsupported archive format: " + params->format, "INVALID_PARAMS")
            .write(std::cout);
        return;
    }

    const bool password_provided = !params->password.empty();
    const ProgressSink sink = make_jsonl_progress_sink(req.id);
    std::string split_err_code;
    std::string split_err_msg;
    if (!validate_split_archive_volumes(params->archive, split_err_code, split_err_msg)) {
        make_error(req.id, split_err_msg, split_err_code).write(std::cout);
        return;
    }
    try {
        bit7z::BitArchiveReader outer_reader(lib_, params->archive, *outer_fmt, params->password);

        std::string error_msg;
        std::string error_code = "PATH_NOT_FOUND";
        bool ok = false;
        with_resolved_reader(
            lib_, outer_reader, params->archive, fmt_lower, params->tar_cache_path, &sink, nullptr,
            [&](bit7z::BitArchiveReader& reader, std::optional<uint64_t> outer_pack_size, bool used_tar_cache) {
                const uint8_t stage = (outer_pack_size.has_value() && !used_tar_cache)
                    ? ProgressStage::ExtractingInner
                    : ProgressStage::Normal;
                ok = extract_from_reader(reader, *params, &sink, nullptr, error_msg, error_code, stage);
            });

        if (!ok) {
            make_error(req.id, error_msg, error_code).write(std::cout);
            return;
        }

        nlohmann::json result;
        result["archive"] = params->archive;
        result["output_dir"] = params->output;
        make_result(req.id, std::move(result)).write(std::cout);
    } catch (const bit7z::BitException& ex) {
        const std::string code = classify_bit7z_error(ex, password_provided);
        if (code == "BIT7Z_ERROR") {
            const std::string missing_vol = find_missing_next_volume(params->archive);
            if (!missing_vol.empty()) {
                make_error(req.id, "Missing archive volume: " + missing_vol, "MISSING_VOLUME")
                    .write(std::cout);
                return;
            }
        }
        make_error(req.id, ex.what(), code).write(std::cout);
    }
}

void CommandHandler::handle_add(const Request& req) {
    auto params = req.as_add();
    if (!params) {
        make_error(req.id, "Invalid 'add' parameters", "INVALID_PARAMS").write(std::cout);
        return;
    }

    const ProgressSink sink = make_jsonl_progress_sink(req.id);
    const OperationOutcome out = run_add(lib_, *params, &sink, nullptr);
    if (!out.ok) {
        make_error(req.id, out.error_msg, out.error_code).write(std::cout);
        return;
    }

    nlohmann::json result;
    result["archive"] = params->archive;
    result["paths_count"] = params->paths.size();
    result["output_size"] = out.output_size;
    make_result(req.id, std::move(result)).write(std::cout);
}

void CommandHandler::handle_delete(const Request& req) {
    auto params = req.as_delete();
    if (!params) {
        make_error(req.id, "Invalid 'delete' parameters", "INVALID_PARAMS").write(std::cout);
        return;
    }

    const ProgressSink sink = make_jsonl_progress_sink(req.id);
    const OperationOutcome out = run_delete(lib_, *params, &sink, nullptr);
    if (!out.ok) {
        make_error(req.id, out.error_msg, out.error_code).write(std::cout);
        return;
    }

    nlohmann::json result;
    result["archive"] = params->archive;
    result["archive_deleted"] = out.archive_deleted;
    result["output_size"] = out.output_size;
    make_result(req.id, std::move(result)).write(std::cout);
}

void CommandHandler::handle_rename(const Request& req) {
    auto params = req.as_rename();
    if (!params) {
        make_error(req.id, "Invalid 'rename' parameters", "INVALID_PARAMS").write(std::cout);
        return;
    }

    const ProgressSink sink = make_jsonl_progress_sink(req.id);
    const OperationOutcome out = run_rename(lib_, *params, &sink, nullptr);
    if (!out.ok) {
        make_error(req.id, out.error_msg, out.error_code).write(std::cout);
        return;
    }

    nlohmann::json result;
    result["archive"] = params->archive;
    result["old_path"] = params->old_path;
    result["new_path"] = params->new_path;
    result["output_size"] = out.output_size;
    make_result(req.id, std::move(result)).write(std::cout);
}

void CommandHandler::handle_test(const Request& req) {
    auto params = req.as_test();
    if (!params) {
        make_error(req.id, "Invalid 'test' parameters", "INVALID_PARAMS").write(std::cout);
        return;
    }

    const ProgressSink sink = make_jsonl_progress_sink(req.id);
    const OperationOutcome out = run_test(lib_, *params, &sink, nullptr);
    if (!out.ok) {
        make_error(req.id, out.error_msg, out.error_code).write(std::cout);
        return;
    }

    nlohmann::json result;
    result["archive"] = params->archive;
    result["items_tested"] = out.output_size;
    result["output_size"] = out.output_size;
    make_result(req.id, std::move(result)).write(std::cout);
}

} // namespace bento7z
