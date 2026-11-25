#include "format_utils.hpp"

#include <bit7z/bitarchivereader.hpp>
#include <bit7z/bitexception.hpp>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <filesystem>

namespace bento7z {

namespace fs = std::filesystem;

std::string to_lower_ascii(std::string_view s) {
    std::string out;
    out.reserve(s.size());
    for (unsigned char c : s) {
        out.push_back(static_cast<char>(std::tolower(c)));
    }
    return out;
}

bool starts_with(std::string_view s, std::string_view prefix) {
    return s.size() >= prefix.size() && s.substr(0, prefix.size()) == prefix;
}

bool ends_with_ci(std::string_view s, std::string_view suffix) {
    if (s.size() < suffix.size()) return false;
    const auto tail = s.substr(s.size() - suffix.size());
    for (size_t i = 0; i < suffix.size(); ++i) {
        if (std::tolower(static_cast<unsigned char>(tail[i])) !=
            std::tolower(static_cast<unsigned char>(suffix[i]))) {
            return false;
        }
    }
    return true;
}

CompoundTarType compound_from_format_name(std::string_view fmt_lower) {
    if (fmt_lower == "tar.gz" || fmt_lower == "tgz") return CompoundTarType::TarGz;
    if (fmt_lower == "tar.bz2" || fmt_lower == "tbz2" || fmt_lower == "tbz") return CompoundTarType::TarBz2;
    if (fmt_lower == "tar.xz" || fmt_lower == "txz") return CompoundTarType::TarXz;
    if (fmt_lower == "tar.zst" || fmt_lower == "tzst") return CompoundTarType::TarZst;
    return CompoundTarType::None;
}

CompoundTarType compound_from_path(std::string_view path) {
    if (ends_with_ci(path, ".tar.gz") || ends_with_ci(path, ".tgz")) return CompoundTarType::TarGz;
    if (ends_with_ci(path, ".tar.bz2") || ends_with_ci(path, ".tbz2") || ends_with_ci(path, ".tbz")) {
        return CompoundTarType::TarBz2;
    }
    if (ends_with_ci(path, ".tar.xz") || ends_with_ci(path, ".txz")) return CompoundTarType::TarXz;
    if (ends_with_ci(path, ".tar.zst") || ends_with_ci(path, ".tzst")) return CompoundTarType::TarZst;
    return CompoundTarType::None;
}

const bit7z::BitInOutFormat& compound_outer_inout_format(CompoundTarType type) {
    switch (type) {
        case CompoundTarType::TarGz:  return bit7z::BitFormat::GZip;
        case CompoundTarType::TarBz2: return bit7z::BitFormat::BZip2;
        case CompoundTarType::TarXz:  return bit7z::BitFormat::Xz;
        case CompoundTarType::TarZst:
        case CompoundTarType::None:   break;
    }
    return bit7z::BitFormat::GZip;
}

const bit7z::BitInFormat& compound_outer_in_format(CompoundTarType type) {
    if (type == CompoundTarType::TarZst) {
        return bit7z::BitFormat::Zstd;
    }
    return compound_outer_inout_format(type);
}

const bit7z::BitInOutFormat* resolve_out_format(std::string_view fmt_lower) {
    if (fmt_lower == "7z")                          return &bit7z::BitFormat::SevenZip;
    if (fmt_lower == "zip")                         return &bit7z::BitFormat::Zip;
    if (fmt_lower == "tar")                         return &bit7z::BitFormat::Tar;
    if (fmt_lower == "gz" || fmt_lower == "gzip")   return &bit7z::BitFormat::GZip;
    if (fmt_lower == "bz2" || fmt_lower == "bzip2") return &bit7z::BitFormat::BZip2;
    if (fmt_lower == "xz")                          return &bit7z::BitFormat::Xz;
    if (fmt_lower == "wim")                         return &bit7z::BitFormat::Wim;
    return nullptr;
}

const bit7z::BitInFormat* resolve_in_format(std::string_view fmt_lower) {
    if (fmt_lower.empty() || fmt_lower == "auto")   return &bit7z::BitFormat::Auto;
    if (fmt_lower == "7z")                          return &bit7z::BitFormat::SevenZip;
    if (fmt_lower == "zip")                         return &bit7z::BitFormat::Zip;
    if (fmt_lower == "tar")                         return &bit7z::BitFormat::Tar;
    if (fmt_lower == "gz" || fmt_lower == "gzip")   return &bit7z::BitFormat::GZip;
    if (fmt_lower == "bz2" || fmt_lower == "bzip2") return &bit7z::BitFormat::BZip2;
    if (fmt_lower == "xz")                          return &bit7z::BitFormat::Xz;
    if (fmt_lower == "wim")                         return &bit7z::BitFormat::Wim;
    if (fmt_lower == "rar")                         return &bit7z::BitFormat::Rar;
    if (fmt_lower == "rar5")                        return &bit7z::BitFormat::Rar5;
    if (fmt_lower == "iso")                         return &bit7z::BitFormat::Iso;
    if (fmt_lower == "cab")                         return &bit7z::BitFormat::Cab;
    if (fmt_lower == "dmg")                         return &bit7z::BitFormat::Dmg;
    if (fmt_lower == "xar" || fmt_lower == "pkg")   return &bit7z::BitFormat::Xar;
    if (fmt_lower == "zst" || fmt_lower == "zstd")  return &bit7z::BitFormat::Zstd;
    if (fmt_lower == "lzma")                        return &bit7z::BitFormat::Lzma;
    if (fmt_lower == "cpio")                        return &bit7z::BitFormat::Cpio;
    if (fmt_lower == "rpm")                         return &bit7z::BitFormat::Rpm;
    if (fmt_lower == "deb")                         return &bit7z::BitFormat::Deb;
    if (fmt_lower == "arj")                         return &bit7z::BitFormat::Arj;
    if (fmt_lower == "lzh" || fmt_lower == "lha")   return &bit7z::BitFormat::Lzh;
    if (fmt_lower == "chm")                         return &bit7z::BitFormat::Chm;
    if (fmt_lower == "udf")                         return &bit7z::BitFormat::Udf;
    if (fmt_lower == "nsis")                        return &bit7z::BitFormat::Nsis;
    if (fmt_lower == "vhd")                         return &bit7z::BitFormat::Vhd;
    if (fmt_lower == "vhdx")                        return &bit7z::BitFormat::Vhdx;
    if (fmt_lower == "vmdk")                        return &bit7z::BitFormat::VMDK;
    if (fmt_lower == "vdi")                         return &bit7z::BitFormat::VDI;
    if (fmt_lower == "qcow" || fmt_lower == "qcow2") return &bit7z::BitFormat::QCow;
    if (fmt_lower == "ext")                         return &bit7z::BitFormat::Ext;
    if (fmt_lower == "fat")                         return &bit7z::BitFormat::Fat;
    if (fmt_lower == "ntfs")                        return &bit7z::BitFormat::Ntfs;
    if (fmt_lower == "hfs")                         return &bit7z::BitFormat::Hfs;
    if (fmt_lower == "apfs")                        return &bit7z::BitFormat::APFS;
    if (fmt_lower == "split" || fmt_lower == "001") return &bit7z::BitFormat::Split;
    return nullptr;
}

const bit7z::BitInFormat* resolve_outer_in_format(std::string_view fmt_lower) {
    const CompoundTarType explicit_compound = compound_from_format_name(fmt_lower);
    if (explicit_compound != CompoundTarType::None) {
        return &compound_outer_in_format(explicit_compound);
    }
    return resolve_in_format(fmt_lower);
}

std::string infer_compress_format_from_path(std::string_view archive_path) {
    switch (compound_from_path(archive_path)) {
        case CompoundTarType::TarGz:  return "tar.gz";
        case CompoundTarType::TarBz2: return "tar.bz2";
        case CompoundTarType::TarXz:  return "tar.xz";
        case CompoundTarType::TarZst: return "tar.zst";
        case CompoundTarType::None:   break;
    }
    if (ends_with_ci(archive_path, ".zip"))  return "zip";
    if (ends_with_ci(archive_path, ".tar"))  return "tar";
    if (ends_with_ci(archive_path, ".gz"))   return "gz";
    if (ends_with_ci(archive_path, ".bz2"))  return "bz2";
    if (ends_with_ci(archive_path, ".xz"))   return "xz";
    if (ends_with_ci(archive_path, ".wim"))  return "wim";
    return "7z";
}

std::string derive_inner_tar_name(const std::string& archive_path) {
    std::string filename = fs::path(archive_path).filename().string();
    static constexpr std::string_view compound_suffixes[] = {
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tgz", ".tbz2", ".tbz", ".txz", ".tzst"
    };
    for (const auto suffix : compound_suffixes) {
        if (ends_with_ci(filename, suffix) && filename.size() > suffix.size()) {
            return filename.substr(0, filename.size() - suffix.size()) + ".tar";
        }
    }
    std::string stem = fs::path(filename).stem().string();
    return (stem.empty() ? std::string("archive") : stem) + ".tar";
}

bit7z::BitCompressionLevel resolve_level(const std::string& level) {
    const std::string l = to_lower_ascii(level);
    if (l == "none")    return bit7z::BitCompressionLevel::None;
    if (l == "fastest") return bit7z::BitCompressionLevel::Fastest;
    if (l == "fast")    return bit7z::BitCompressionLevel::Fast;
    if (l == "normal")  return bit7z::BitCompressionLevel::Normal;
    if (l == "max")     return bit7z::BitCompressionLevel::Max;
    if (l == "ultra")   return bit7z::BitCompressionLevel::Ultra;
    return bit7z::BitCompressionLevel::Normal;
}

bool is_raw_single_stream_format(std::string_view fmt_lower) {
    return fmt_lower == "gz" || fmt_lower == "gzip" ||
           fmt_lower == "bz2" || fmt_lower == "bzip2" ||
           fmt_lower == "xz" ||
           fmt_lower == "zst" || fmt_lower == "zstd";
}

bool format_supports_password(std::string_view fmt_lower) {
    return fmt_lower == "7z" || fmt_lower == "zip";
}

namespace {

bool is_all_digits(std::string_view s) {
    if (s.empty()) return false;
    for (unsigned char c : s) {
        if (!std::isdigit(c)) return false;
    }
    return true;
}

std::string format_padded_index(int index, size_t width) {
    std::string num = std::to_string(index);
    if (num.size() < width) {
        num.insert(0, width - num.size(), '0');
    }
    return num;
}

} // namespace

SplitVolumeInfo detect_split_volume_info(const std::string& archive_path) {
    SplitVolumeInfo info;
    const fs::path p(archive_path);
    const std::string fname = p.filename().string();
    const std::string lower = to_lower_ascii(fname);

    // 1. Numbered split volumes: *.001, *.002, ...
    if (fname.size() > 4) {
        const size_t dot = fname.find_last_of('.');
        if (dot != std::string::npos) {
            const std::string_view ext(fname.data() + dot + 1, fname.size() - dot - 1);
            if (ext.size() >= 3 && is_all_digits(ext)) {
                const int vol_num = std::stoi(std::string(ext));
                const std::string base = archive_path.substr(0, archive_path.size() - ext.size());
                const std::string lower_base = to_lower_ascii(fname.substr(0, dot));

                info.is_split = true;
                info.is_numbered_001 = true;
                info.is_first_volume = (vol_num == 1);
                info.expected_first_volume = base + format_padded_index(1, ext.size());
                if (ends_with_ci(lower_base, ".7z")) {
                    info.inner_format_hint = "7z";
                } else if (ends_with_ci(lower_base, ".zip")) {
                    info.inner_format_hint = "zip";
                } else if (ends_with_ci(lower_base, ".tar")) {
                    info.inner_format_hint = "tar";
                }
                return info;
            }
        }
    }

    // 2. RAR partN.rar split volumes
    if (ends_with_ci(lower, ".rar") && lower.size() > 9) {
        const size_t stem_end = lower.size() - 4;
        const size_t part_pos = lower.rfind(".part", stem_end);
        if (part_pos != std::string::npos) {
            const std::string_view digits(lower.data() + part_pos + 5, stem_end - (part_pos + 5));
            if (is_all_digits(digits)) {
                const int part_num = std::stoi(std::string(digits));
                info.is_split = true;
                info.is_first_volume = (part_num == 1);
                info.inner_format_hint = "rar";
                const std::string prefix = archive_path.substr(0, archive_path.size() - lower.size() + part_pos + 5);
                info.expected_first_volume = prefix + format_padded_index(1, digits.size()) + ".rar";
                return info;
            }
        }
    }

    // 3. Legacy RAR secondary volumes (.r00, .r01, ...)
    if (fname.size() > 4) {
        const size_t dot = lower.find_last_of('.');
        if (dot != std::string::npos && lower.size() - dot == 4 && lower[dot + 1] == 'r') {
            const std::string_view digits(lower.data() + dot + 2, 2);
            if (is_all_digits(digits)) {
                info.is_split = true;
                info.is_first_volume = false;
                info.inner_format_hint = "rar";
                info.expected_first_volume = archive_path.substr(0, archive_path.size() - 3) + "rar";
                return info;
            }
        }
    }

    return info;
}

bool validate_split_archive_volumes(const std::string& archive_path,
                                    std::string& error_code,
                                    std::string& error_msg) {
    const SplitVolumeInfo info = detect_split_volume_info(archive_path);
    if (!info.is_split) {
        return true;
    }

    if (!info.is_first_volume) {
        error_code = "SPLIT_NOT_FIRST_VOLUME";
        error_msg = "Please open the first volume (" +
                    fs::path(info.expected_first_volume).filename().string() +
                    ") of this split archive.";
        return false;
    }

    if (info.is_numbered_001) {
        const size_t dot = archive_path.find_last_of('.');
        const std::string prefix = archive_path.substr(0, dot + 1);
        const size_t width = archive_path.size() - dot - 1;

        std::error_code ec;
        const fs::path parent = fs::path(archive_path).parent_path();
        const std::string base_name = fs::path(archive_path).filename().string().substr(
            0, fs::path(archive_path).filename().string().find_last_of('.') + 1);
        int max_found = 1;
        for (const auto& entry : fs::directory_iterator(parent.empty() ? fs::current_path() : parent, ec)) {
            const std::string ename = entry.path().filename().string();
            if (ename.size() > base_name.size() &&
                ename.compare(0, base_name.size(), base_name) == 0) {
                const std::string_view suffix(ename.data() + base_name.size(), ename.size() - base_name.size());
                if (suffix.size() == width && is_all_digits(suffix)) {
                    max_found = std::max(max_found, std::stoi(std::string(suffix)));
                }
            }
        }

        for (int idx = 1; idx <= max_found; ++idx) {
            const fs::path expected(prefix + format_padded_index(idx, width));
            if (!fs::exists(expected, ec)) {
                error_code = "MISSING_VOLUME";
                error_msg = "Missing archive volume: " + expected.filename().string();
                return false;
            }
        }
    }

    return true;
}

std::string find_missing_next_volume(const std::string& archive_path) {
    const SplitVolumeInfo info = detect_split_volume_info(archive_path);
    if (!info.is_split || !info.is_first_volume) {
        return {};
    }

    std::error_code ec;
    if (info.is_numbered_001) {
        const size_t dot = archive_path.find_last_of('.');
        const std::string prefix = archive_path.substr(0, dot + 1);
        const size_t width = archive_path.size() - dot - 1;
        for (int idx = 2; idx <= 999; ++idx) {
            const fs::path candidate(prefix + format_padded_index(idx, width));
            if (!fs::exists(candidate, ec)) {
                return candidate.filename().string();
            }
        }
    } else if (info.inner_format_hint == "rar") {
        const std::string lower = to_lower_ascii(archive_path);
        const size_t part_pos = lower.rfind(".part");
        if (part_pos != std::string::npos) {
            const size_t stem_end = lower.size() - 4;
            const size_t width = stem_end - (part_pos + 5);
            const std::string prefix = archive_path.substr(0, part_pos + 5);
            for (int idx = 2; idx <= 999; ++idx) {
                const fs::path candidate(prefix + format_padded_index(idx, width) + ".rar");
                if (!fs::exists(candidate, ec)) {
                    return candidate.filename().string();
                }
            }
        }
    }
    return {};
}

bool is_valid_tar_header(const std::vector<bit7z::byte_t>& buf) {
    if (buf.size() < 512 || buf[0] == 0) {
        return false;
    }

    uint64_t expected_sum = 0;
    bool has_digit = false;
    for (size_t i = 148; i < 156; ++i) {
        const auto c = static_cast<unsigned char>(buf[i]);
        if (c == 0 || c == ' ') {
            if (has_digit) {
                break;
            }
            continue;
        }
        if (c < '0' || c > '7') {
            return false;
        }
        has_digit = true;
        expected_sum = (expected_sum << 3) + static_cast<uint64_t>(c - '0');
    }
    if (!has_digit) {
        return false;
    }

    uint64_t actual_sum = 0;
    for (size_t i = 0; i < 512; ++i) {
        actual_sum += (i >= 148 && i < 156)
            ? static_cast<uint64_t>(' ')
            : static_cast<uint64_t>(buf[i]);
    }
    if (actual_sum != expected_sum) {
        return false;
    }

    const bool has_ustar = (buf[257] == 'u' && buf[258] == 's' && buf[259] == 't' &&
                            buf[260] == 'a' && buf[261] == 'r');
    if (has_ustar) {
        return true;
    }

    auto is_octal_field = [&buf](size_t start, size_t len) {
        bool digit = false;
        for (size_t i = start; i < start + len; ++i) {
            const auto c = static_cast<unsigned char>(buf[i]);
            if (c == 0 || c == ' ') {
                continue;
            }
            if (c < '0' || c > '7') {
                return false;
            }
            digit = true;
        }
        return digit;
    };
    return is_octal_field(100, 8) && is_octal_field(124, 12);
}

bool is_inner_stream_tar(const bit7z::BitArchiveReader& outer_reader) {
    if (outer_reader.itemsCount() != 1 || outer_reader.isItemFolder(0)) {
        return false;
    }
    if (ends_with_ci(outer_reader.itemAt(0).path(), ".tar")) {
        return true;
    }

    std::vector<bit7z::byte_t> header;
    header.reserve(512);
    try {
        const std::vector<uint32_t> indices = {0};
        outer_reader.extractTo(
            [&header](const bit7z::byte_t* data, std::size_t size) -> bool {
                const size_t needed = 512 - header.size();
                const size_t to_copy = std::min(needed, size);
                header.insert(header.end(), data, data + to_copy);
                return header.size() < 512;
            },
            indices);
    } catch (const bit7z::BitException&) {
        // Returning false aborts extraction cleanly once 512 bytes are collected.
    }
    return is_valid_tar_header(header);
}

} // namespace bento7z
