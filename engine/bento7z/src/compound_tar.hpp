#pragma once

#include "bento7z/progress.hpp"
#include "bento7z/protocol.hpp"
#include "format_utils.hpp"

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <string_view>

namespace bit7z {
class Bit7zLibrary;
class BitArchiveReader;
class BitArchiveWriter;
}

namespace bento7z {

class ScopedTempFile {
public:
    explicit ScopedTempFile(const std::string& extension);
    ~ScopedTempFile();

    ScopedTempFile(const ScopedTempFile&) = delete;
    ScopedTempFile& operator=(const ScopedTempFile&) = delete;

    const std::filesystem::path& path() const { return path_; }
    std::string string() const { return path_.string(); }

private:
    std::filesystem::path path_;
};

class ScopedTempDir {
public:
    ScopedTempDir();
    ~ScopedTempDir();

    ScopedTempDir(const ScopedTempDir&) = delete;
    ScopedTempDir& operator=(const ScopedTempDir&) = delete;

    const std::filesystem::path& path() const { return path_; }
    std::string string() const { return path_.string(); }

private:
    std::filesystem::path path_;
};

uint32_t hardware_threads_or_one();

bool should_unwrap_compound_tar(const bit7z::BitArchiveReader& outer_reader,
                                const std::string& archive_path,
                                std::string_view fmt_lower);

void unwrap_tar_to_path(bit7z::BitArchiveReader& outer_reader,
                        const std::filesystem::path& dest_path,
                        const ProgressSink* progress_sink = nullptr,
                        std::atomic<bool>* cancel_flag = nullptr,
                        uint64_t fallback_outer_size = 0);

void unwrap_tar_to_temp(bit7z::BitArchiveReader& outer_reader,
                        ScopedTempFile& temp_tar,
                        const ProgressSink* progress_sink = nullptr,
                        std::atomic<bool>* cancel_flag = nullptr,
                        uint64_t fallback_outer_size = 0);

void with_resolved_reader(
    const bit7z::Bit7zLibrary& lib,
    bit7z::BitArchiveReader& outer_reader,
    const std::string& archive_path,
    std::string_view fmt_lower,
    const std::string& tar_cache_path,
    const ProgressSink* progress_sink,
    std::atomic<bool>* cancel_flag,
    const std::function<void(bit7z::BitArchiveReader&, std::optional<uint64_t>, bool)>& fn);

bool add_paths_to_writer(bit7z::BitArchiveWriter& writer,
                         const CompressParams& params,
                         std::string& missing_path,
                         std::atomic<bool>* cancel_flag = nullptr,
                         const std::string& target_prefix = {});

bool compress_compound_tar(const bit7z::Bit7zLibrary& lib,
                           CompoundTarType compound,
                           const CompressParams& params,
                           const ProgressSink* progress_sink,
                           std::atomic<bool>* cancel_flag,
                           std::string& missing_path);

} // namespace bento7z
