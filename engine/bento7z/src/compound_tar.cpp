#include "compound_tar.hpp"

#include "bento7z/progress.hpp"
#include "path_safety.hpp"

#include <bit7z/bitarchivereader.hpp>
#include <bit7z/bitarchivewriter.hpp>
#include <bit7z/bitformat.hpp>

#include <atomic>
#include <chrono>
#include <fstream>
#include <optional>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

namespace bento7z {

namespace fs = std::filesystem;

namespace {

uint64_t current_pid() {
#ifdef _WIN32
    return static_cast<uint64_t>(_getpid());
#else
    return static_cast<uint64_t>(::getpid());
#endif
}

} // namespace

ScopedTempFile::ScopedTempFile(const std::string& extension) {
    static std::atomic<uint64_t> counter{0};
    std::error_code ec;
    fs::path dir = fs::temp_directory_path(ec);
    if (ec || dir.empty()) {
        dir = fs::current_path();
    }
    const auto pid = current_pid();
    const auto seq = counter.fetch_add(1, std::memory_order_relaxed);
    const auto ticks = static_cast<uint64_t>(
        std::chrono::steady_clock::now().time_since_epoch().count());
    path_ = dir / ("bento7z_" + std::to_string(pid) + "_" +
                   std::to_string(seq) + "_" + std::to_string(ticks) + extension);
}

ScopedTempFile::~ScopedTempFile() {
    if (!path_.empty()) {
        std::error_code ec;
        fs::remove(path_, ec);
    }
}

ScopedTempDir::ScopedTempDir() {
    static std::atomic<uint64_t> counter{0};
    std::error_code ec;
    fs::path dir = fs::temp_directory_path(ec);
    if (ec || dir.empty()) {
        dir = fs::current_path();
    }
    const auto pid = current_pid();
    const auto seq = counter.fetch_add(1, std::memory_order_relaxed);
    const auto ticks = static_cast<uint64_t>(
        std::chrono::steady_clock::now().time_since_epoch().count());
    path_ = dir / ("bento7z_dir_" + std::to_string(pid) + "_" +
                   std::to_string(seq) + "_" + std::to_string(ticks));
    fs::create_directories(path_, ec);
}

ScopedTempDir::~ScopedTempDir() {
    if (!path_.empty()) {
        std::error_code ec;
        fs::remove_all(path_, ec);
    }
}

uint32_t hardware_threads_or_one() {
    const uint32_t count = std::thread::hardware_concurrency();
    return count > 0 ? count : 1;
}

bool should_unwrap_compound_tar(const bit7z::BitArchiveReader& outer_reader,
                                const std::string& archive_path,
                                std::string_view fmt_lower) {
    if (compound_from_format_name(fmt_lower) != CompoundTarType::None) {
        return true;
    }

    const bool raw_override = is_raw_single_stream_format(fmt_lower);
    if (!fmt_lower.empty() && fmt_lower != "auto" && !raw_override) {
        return false;
    }

    // Explicit raw format override ("gz"/"gzip", "bz2"/"bzip2", "xz") on a compound tar extension
    // (.tar.gz, .tar.bz2, .tar.xz, etc.) means the caller intentionally wants raw single-layer output.
    const bool has_compound_ext = (compound_from_path(archive_path) != CompoundTarType::None);
    if (raw_override && has_compound_ext) {
        return false;
    }

    const auto& detected = outer_reader.detectedFormat();
    const bool is_single_stream_wrapper =
        (detected == bit7z::BitFormat::GZip ||
         detected == bit7z::BitFormat::BZip2 ||
         detected == bit7z::BitFormat::Xz ||
         detected == bit7z::BitFormat::Zstd);
    if (!is_single_stream_wrapper) {
        return false;
    }

    if (outer_reader.itemsCount() != 1 || outer_reader.isItemFolder(0)) {
        return false;
    }

    if (has_compound_ext) {
        return true;
    }

    return is_inner_stream_tar(outer_reader);
}

void unwrap_tar_to_path(bit7z::BitArchiveReader& outer_reader,
                        const fs::path& dest_path,
                        const ProgressSink* progress_sink,
                        std::atomic<bool>* cancel_flag,
                        uint64_t fallback_outer_size) {
    if (outer_reader.itemsCount() == 0 || outer_reader.isItemFolder(0)) {
        throw std::runtime_error("Compound archive does not contain an inner tar stream");
    }
    if (is_cancelled(cancel_flag)) {
        throw OperationCancelled();
    }

    std::ofstream ofs(dest_path, std::ios::binary | std::ios::trunc);
    if (!ofs) {
        throw std::runtime_error("Failed to create temporary file for compound archive");
    }

    const uint64_t expected_total =
        (outer_reader.packSize() > 0) ? outer_reader.packSize() : fallback_outer_size;
    const std::string inner_name = outer_reader.itemAt(0).name();

    ScopedHandlerCallbacks cb_guard(outer_reader);
    std::optional<ProgressAdapter> progress;
    if (progress_sink != nullptr || cancel_flag != nullptr) {
        ProgressSink sink = (progress_sink != nullptr) ? *progress_sink : ProgressSink{};
        progress.emplace(
            std::move(sink),
            ProgressStage::UnpackingOuter,
            cancel_flag,
            expected_total,
            inner_name);
        outer_reader.setTotalCallback(progress->total_callback());
        outer_reader.setProgressCallback(progress->progress_callback());
        progress->emit_initial();
    }

    outer_reader.extractTo(ofs, 0);

    if (is_cancelled(cancel_flag)) {
        throw OperationCancelled();
    }
    if (progress) {
        progress->complete();
    }

    ofs.flush();
    ofs.close();
    if (!ofs) {
        throw std::runtime_error("Failed to write inner tar stream to temporary file");
    }
}

void unwrap_tar_to_temp(bit7z::BitArchiveReader& outer_reader,
                        ScopedTempFile& temp_tar,
                        const ProgressSink* progress_sink,
                        std::atomic<bool>* cancel_flag,
                        uint64_t fallback_outer_size) {
    unwrap_tar_to_path(outer_reader, temp_tar.path(), progress_sink, cancel_flag, fallback_outer_size);
}

void with_resolved_reader(
    const bit7z::Bit7zLibrary& lib,
    bit7z::BitArchiveReader& outer_reader,
    const std::string& archive_path,
    std::string_view fmt_lower,
    const std::string& tar_cache_path,
    const ProgressSink* progress_sink,
    std::atomic<bool>* cancel_flag,
    const std::function<void(bit7z::BitArchiveReader&, std::optional<uint64_t>, bool)>& fn) {
    if (should_unwrap_compound_tar(outer_reader, archive_path, fmt_lower)) {
        uint64_t outer_pack_size = outer_reader.packSize();
        if (outer_pack_size == 0) {
            std::error_code sz_ec;
            const auto disk_sz = fs::file_size(fs::path(archive_path), sz_ec);
            if (!sz_ec) {
                outer_pack_size = static_cast<uint64_t>(disk_sz);
            }
        }

        if (!tar_cache_path.empty()) {
            std::error_code ec;
            const fs::path cache_p(tar_cache_path);
            const bool exists = fs::exists(cache_p, ec) && !ec;
            const bool is_reg = exists && fs::is_regular_file(cache_p, ec) && !ec;
            const uint64_t fsize = is_reg ? fs::file_size(cache_p, ec) : 0;
            if (is_reg && !ec && fsize > 0) {
                bit7z::BitArchiveReader inner_reader(lib, tar_cache_path, bit7z::BitFormat::Tar);
                fn(inner_reader, outer_pack_size, /*used_tar_cache=*/true);
                return;
            }

            if (cache_p.has_parent_path()) {
                fs::create_directories(cache_p.parent_path(), ec);
            }

            static std::atomic<uint64_t> part_counter{0};
            const auto seq = part_counter.fetch_add(1, std::memory_order_relaxed);
            const fs::path part_path(
                tar_cache_path + ".part." + std::to_string(current_pid()) + "." + std::to_string(seq));

            auto cleanup_part = [&part_path]() {
                std::error_code rem_ec;
                fs::remove(part_path, rem_ec);
            };

            try {
                unwrap_tar_to_path(outer_reader, part_path, progress_sink, cancel_flag, outer_pack_size);
                if (is_cancelled(cancel_flag)) {
                    cleanup_part();
                    throw OperationCancelled();
                }
                fs::rename(part_path, cache_p);
            } catch (...) {
                cleanup_part();
                throw;
            }

            bit7z::BitArchiveReader inner_reader(lib, tar_cache_path, bit7z::BitFormat::Tar);
            fn(inner_reader, outer_pack_size, /*used_tar_cache=*/false);
            return;
        }

        ScopedTempFile temp_tar(".tar");
        unwrap_tar_to_temp(outer_reader, temp_tar, progress_sink, cancel_flag, outer_pack_size);

        bit7z::BitArchiveReader inner_reader(lib, temp_tar.string(), bit7z::BitFormat::Tar);
        fn(inner_reader, outer_pack_size, /*used_tar_cache=*/false);
        return;
    }

    fn(outer_reader, std::nullopt, /*used_tar_cache=*/false);
}

bool add_paths_to_writer(bit7z::BitArchiveWriter& writer,
                         const CompressParams& params,
                         std::string& missing_path,
                         std::atomic<bool>* cancel_flag,
                         const std::string& target_prefix) {
    for (const auto& p : params.paths) {
        if (is_cancelled(cancel_flag)) {
            throw OperationCancelled();
        }
        std::error_code ec;
        if (!fs::exists(p, ec)) {
            missing_path = ec ? (p + " (" + ec.message() + ")") : p;
            return false;
        }
    }

    const CompiledExcludes compiled_excludes = compile_excludes(params.exclude);
    const bool fast_path = params.preserve_paths && compiled_excludes.empty() && target_prefix.empty();

    for (const auto& p : params.paths) {
        if (is_cancelled(cancel_flag)) {
            throw OperationCancelled();
        }
        fs::path src_path(p);
        std::error_code ec;
        const bool is_dir = fs::is_directory(src_path, ec);

        fs::path norm_src = src_path;
        if (norm_src.filename().empty() && norm_src.has_parent_path()) {
            norm_src = norm_src.parent_path();
        }
        const std::string clean_name = norm_src.filename().string();

        if (!compiled_excludes.empty() && !clean_name.empty() &&
            is_excluded(norm_src, fs::path(clean_name), compiled_excludes)) {
            continue;
        }

        if (fast_path) {
            if (is_dir) {
                writer.addDirectory(p);
            } else {
                writer.addFile(p);
            }
            continue;
        }

        if (!is_dir) {
            if (!target_prefix.empty()) {
                const std::string archive_name = clean_name.empty()
                    ? p
                    : (target_prefix + "/" + clean_name);
                writer.addFile(p, archive_name);
            } else if (!params.preserve_paths && !clean_name.empty()) {
                writer.addFile(p, clean_name);
            } else {
                writer.addFile(p);
            }
            continue;
        }

        if (params.preserve_paths && fs::is_empty(norm_src, ec) && !clean_name.empty()) {
            const std::string archive_dir = target_prefix.empty()
                ? clean_name
                : (target_prefix + "/" + clean_name);
            writer.addItems(std::vector<std::pair<std::string, std::string>>{
                {norm_src.string(), archive_dir}
            });
            continue;
        }

        fs::recursive_directory_iterator it(
            norm_src,
            fs::directory_options::skip_permission_denied,
            ec);
        if (ec) {
            missing_path = p + " (" + ec.message() + ")";
            return false;
        }

        uint32_t walk_counter = 0;
        for (fs::recursive_directory_iterator end; it != end; ++it) {
            if ((++walk_counter & 0xFFu) == 0 && is_cancelled(cancel_flag)) {
                throw OperationCancelled();
            }

            const auto& entry = *it;
            const fs::path rel = entry.path().lexically_relative(norm_src);
            const std::string rel_generic = rel.generic_string();
            if (rel_generic.empty() || rel_generic == "." || starts_with(rel_generic, "..")) {
                continue;
            }

            std::error_code entry_ec;
            const bool entry_is_dir = entry.is_directory(entry_ec);

            if (entry.is_symlink(entry_ec)) {
                std::error_code sym_ec;
                const fs::path sym_target = fs::read_symlink(entry.path(), sym_ec);
                if (sym_ec || sym_target.is_absolute()) {
                    if (entry_is_dir) {
                        it.disable_recursion_pending();
                    }
                    continue;
                }
                const fs::path resolved = (entry.path().parent_path() / sym_target).lexically_normal();
                const fs::path rel_to_root = resolved.lexically_relative(norm_src);
                if (rel_to_root.empty() || starts_with(rel_to_root.generic_string(), "..")) {
                    if (entry_is_dir) {
                        it.disable_recursion_pending();
                    }
                    continue;
                }
            }

            const fs::path base_rel = clean_name.empty() ? rel : (fs::path(clean_name) / rel);
            const fs::path archive_rel = target_prefix.empty()
                ? base_rel
                : (fs::path(target_prefix) / base_rel);

            if (!compiled_excludes.empty() &&
                is_excluded(entry.path(), base_rel, compiled_excludes)) {
                if (entry_is_dir) {
                    it.disable_recursion_pending();
                }
                continue;
            }

            if (entry_is_dir) {
                if (params.preserve_paths && fs::is_empty(entry.path(), entry_ec)) {
                    writer.addItems(std::vector<std::pair<std::string, std::string>>{
                        {entry.path().string(), archive_rel.generic_string()}
                    });
                }
            } else {
                if (params.preserve_paths) {
                    writer.addFile(entry.path().string(), archive_rel.generic_string());
                } else {
                    const std::string flat_name = target_prefix.empty()
                        ? entry.path().filename().string()
                        : (target_prefix + "/" + entry.path().filename().string());
                    writer.addFile(entry.path().string(), flat_name);
                }
            }
        }
    }

    return true;
}

bool compress_compound_tar(const bit7z::Bit7zLibrary& lib,
                           CompoundTarType compound,
                           const CompressParams& params,
                           const ProgressSink* progress_sink,
                           std::atomic<bool>* cancel_flag,
                           std::string& missing_path) {
    ScopedTempFile temp_tar(".tar");
    const ProgressSink sink = (progress_sink != nullptr) ? *progress_sink : ProgressSink{};

    {
        ProgressAdapter tar_progress(sink, ProgressStage::PackingTar, cancel_flag);
        bit7z::BitArchiveWriter tar_writer(lib, bit7z::BitFormat::Tar);
        tar_writer.setThreadsCount(hardware_threads_or_one());
        tar_writer.setRetainDirectories(false);
        tar_progress.attach(tar_writer);

        if (!add_paths_to_writer(tar_writer, params, missing_path, cancel_flag)) {
            return false;
        }

        tar_writer.compressTo(temp_tar.string());
        if (is_cancelled(cancel_flag)) {
            throw OperationCancelled();
        }
        tar_progress.complete();
    }

    if (is_cancelled(cancel_flag)) {
        throw OperationCancelled();
    }

    {
        std::error_code sz_ec;
        const uint64_t temp_tar_size = static_cast<uint64_t>(fs::file_size(temp_tar.path(), sz_ec));
        const uint64_t fallback_total = sz_ec ? 0 : temp_tar_size;
        const std::string inner_tar_name = derive_inner_tar_name(params.archive);

        ProgressAdapter outer_progress(
            sink,
            ProgressStage::CompressingOuter,
            cancel_flag,
            fallback_total,
            inner_tar_name);

        const auto& outer_fmt = compound_outer_inout_format(compound);
        bit7z::BitArchiveWriter outer_writer(lib, outer_fmt);
        outer_writer.setThreadsCount(hardware_threads_or_one());
        outer_writer.setCompressionLevel(resolve_level(params.level));
        outer_writer.setTotalCallback(outer_progress.total_callback());
        outer_writer.setProgressCallback(outer_progress.progress_callback());

        outer_progress.emit_initial();
        outer_writer.addFile(temp_tar.string(), inner_tar_name);
        outer_writer.compressTo(params.archive);
        if (is_cancelled(cancel_flag)) {
            throw OperationCancelled();
        }
        outer_progress.complete();
    }

    return true;
}

} // namespace bento7z
