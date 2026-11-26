#include "binary_server.hpp"
#include "binary_protocol.hpp"
#include "bento7z/commands.hpp"
#include "bento7z/progress.hpp"
#include "compound_tar.hpp"
#include "format_utils.hpp"
#include "zip_encoding.hpp"

#include <bit7z/bit7zlibrary.hpp>
#include <bit7z/bitarchivereader.hpp>
#include <bit7z/bitexception.hpp>
#include <bit7z/bitformat.hpp>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <iostream>
#include <list>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace bento7z {

namespace fs = std::filesystem;

namespace {

constexpr size_t kWorkerThreadCount = 4;
constexpr size_t kListChunkSize = 1024;
constexpr size_t kReaderPoolCapacity = 3;

bool read_exact(int fd, uint8_t* dst, size_t len) {
    size_t offset = 0;
    while (offset < len) {
        const ssize_t n = ::read(fd, dst + offset, len - offset);
        if (n == 0) {
            return false; // EOF
        }
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        offset += static_cast<size_t>(n);
    }
    return true;
}

bool write_all(int fd, const uint8_t* src, size_t len) {
    size_t offset = 0;
    while (offset < len) {
        const ssize_t n = ::write(fd, src + offset, len - offset);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) {
            return false;
        }
        offset += static_cast<size_t>(n);
    }
    return true;
}

struct ReaderCacheKey {
    std::string archive_path;
    uint64_t file_size = 0;
    int64_t mtime_sec = 0;
    int64_t mtime_nsec = 0;
    uint64_t inode = 0;
    std::string format;

    bool operator==(const ReaderCacheKey& other) const {
        return file_size == other.file_size &&
               mtime_sec == other.mtime_sec &&
               mtime_nsec == other.mtime_nsec &&
               inode == other.inode &&
               archive_path == other.archive_path &&
               format == other.format;
    }
};

std::optional<ReaderCacheKey> make_reader_cache_key(const std::string& archive_path,
                                                    const std::string& fmt_lower) {
    struct stat st{};
    if (::stat(archive_path.c_str(), &st) != 0) {
        return std::nullopt;
    }
    ReaderCacheKey key;
    key.archive_path = archive_path;
    key.file_size = static_cast<uint64_t>(st.st_size);
#ifdef __APPLE__
    key.mtime_sec = static_cast<int64_t>(st.st_mtimespec.tv_sec);
    key.mtime_nsec = static_cast<int64_t>(st.st_mtimespec.tv_nsec);
#else
    key.mtime_sec = static_cast<int64_t>(st.st_mtim.tv_sec);
    key.mtime_nsec = static_cast<int64_t>(st.st_mtim.tv_nsec);
#endif
    key.inode = static_cast<uint64_t>(st.st_ino);
    key.format = fmt_lower;
    return key;
}

class ReaderPool {
public:
    struct CheckedOut {
        std::unique_ptr<bit7z::BitArchiveReader> reader;
        uint64_t version = 0;
    };

    CheckedOut checkout(const ReaderCacheKey& key) {
        std::lock_guard<std::mutex> lock(mutex_);
        CheckedOut res;
        res.version = version_;
        for (auto it = lru_.begin(); it != lru_.end(); ++it) {
            if (it->key == key) {
                res.reader = std::move(it->reader);
                lru_.erase(it);
                return res;
            }
        }
        return res;
    }

    uint64_t current_version() {
        std::lock_guard<std::mutex> lock(mutex_);
        return version_;
    }

    void checkin(const ReaderCacheKey& key,
                 uint64_t expected_version,
                 std::unique_ptr<bit7z::BitArchiveReader> reader) {
        if (!reader) return;
        reader->setTotalCallback({});
        reader->setProgressCallback({});
        reader->setFileCallback({});

        std::lock_guard<std::mutex> lock(mutex_);
        if (version_ != expected_version) {
            return; // Invalidated while checked out
        }
        lru_.push_front(Entry{key, std::move(reader)});
        while (lru_.size() > kReaderPoolCapacity) {
            lru_.pop_back();
        }
    }

    void invalidate(const std::string& archive_path) {
        const std::string norm = fs::path(archive_path).lexically_normal().string();
        std::lock_guard<std::mutex> lock(mutex_);
        ++version_;
        for (auto it = lru_.begin(); it != lru_.end();) {
            const std::string entry_norm =
                fs::path(it->key.archive_path).lexically_normal().string();
            if (it->key.archive_path == archive_path || entry_norm == norm) {
                it = lru_.erase(it);
            } else {
                ++it;
            }
        }
    }

    void clear() {
        std::lock_guard<std::mutex> lock(mutex_);
        lru_.clear();
    }

private:
    struct Entry {
        ReaderCacheKey key;
        std::unique_ptr<bit7z::BitArchiveReader> reader;
    };

    std::mutex mutex_;
    std::list<Entry> lru_;
    uint64_t version_ = 0;
};

struct WorkItem {
    BinaryFrameHeader header;
    std::vector<uint8_t> payload;
    std::shared_ptr<std::atomic<bool>> cancel_flag;
};

class BinaryServerSession {
public:
    BinaryServerSession(bit7z::Bit7zLibrary& lib, int client_fd)
        : lib_(lib), client_fd_(client_fd) {}

    ~BinaryServerSession() {
        shutdown_workers();
        reader_pool_.clear();
    }

    void run() {
        start_workers();

        uint8_t hdr_buf[kBinaryFrameHeaderSize];
        while (read_exact(client_fd_, hdr_buf, kBinaryFrameHeaderSize)) {
            const BinaryFrameHeader hdr = decode_frame_header(hdr_buf);
            if (hdr.payload_len > kMaxBinaryPayloadSize) {
                send_frame(encode_error_frame(
                    hdr.req_id, "INVALID_PARAMS", "Frame payload exceeds maximum allowed size"));
                break;
            }

            std::vector<uint8_t> payload(hdr.payload_len);
            if (hdr.payload_len > 0 && !read_exact(client_fd_, payload.data(), hdr.payload_len)) {
                break;
            }

            const auto msg_type = static_cast<BinaryMsgType>(hdr.msg_type);
            if (msg_type == BinaryMsgType::Ping) {
                send_frame(encode_pong_frame(hdr.req_id));
                continue;
            }
            if (msg_type == BinaryMsgType::Cancel) {
                cancel_request(hdr.req_id);
                continue;
            }

            auto flag = std::make_shared<std::atomic<bool>>(false);
            {
                std::lock_guard<std::mutex> lock(cancel_mutex_);
                cancel_flags_[hdr.req_id] = flag;
            }

            enqueue_work(WorkItem{hdr, std::move(payload), std::move(flag)});
        }

        // Client disconnected (EOF) or read error: cancel all in-flight operations and join workers.
        cancel_all();
        shutdown_workers();
        reader_pool_.clear();
    }

private:
    void start_workers() {
        workers_.reserve(kWorkerThreadCount);
        for (size_t i = 0; i < kWorkerThreadCount; ++i) {
            workers_.emplace_back([this]() { worker_loop(); });
        }
    }

    void shutdown_workers() {
        {
            std::lock_guard<std::mutex> lock(queue_mutex_);
            stopping_ = true;
        }
        queue_cv_.notify_all();
        for (auto& t : workers_) {
            if (t.joinable()) {
                t.join();
            }
        }
        workers_.clear();
    }

    void enqueue_work(WorkItem item) {
        {
            std::lock_guard<std::mutex> lock(queue_mutex_);
            queue_.push_back(std::move(item));
        }
        queue_cv_.notify_one();
    }

    void cancel_request(uint64_t req_id) {
        std::lock_guard<std::mutex> lock(cancel_mutex_);
        auto it = cancel_flags_.find(req_id);
        if (it != cancel_flags_.end() && it->second) {
            it->second->store(true, std::memory_order_relaxed);
        }
    }

    void cancel_all() {
        std::lock_guard<std::mutex> lock(cancel_mutex_);
        for (auto& kv : cancel_flags_) {
            if (kv.second) {
                kv.second->store(true, std::memory_order_relaxed);
            }
        }
    }

    void unregister_cancel_flag(uint64_t req_id, const std::shared_ptr<std::atomic<bool>>& flag) {
        std::lock_guard<std::mutex> lock(cancel_mutex_);
        auto it = cancel_flags_.find(req_id);
        if (it != cancel_flags_.end() && it->second == flag) {
            cancel_flags_.erase(it);
        }
    }

    bool send_frame(const std::vector<uint8_t>& frame) {
        if (write_broken_.load(std::memory_order_relaxed)) {
            return false;
        }
        std::lock_guard<std::mutex> lock(write_mutex_);
        if (write_broken_.load(std::memory_order_relaxed)) {
            return false;
        }
        if (!write_all(client_fd_, frame.data(), frame.size())) {
            write_broken_.store(true, std::memory_order_relaxed);
            return false;
        }
        return true;
    }

    ProgressSink make_progress_sink(uint64_t req_id) {
        return [this, req_id](uint8_t stage,
                              uint64_t processed,
                              uint64_t total,
                              uint32_t files_delta,
                              const std::string& current_file) {
            send_frame(encode_progress_frame(
                req_id, stage, processed, total, files_delta, current_file));
        };
    }

    void worker_loop() {
        while (true) {
            WorkItem item;
            {
                std::unique_lock<std::mutex> lock(queue_mutex_);
                queue_cv_.wait(lock, [this]() { return stopping_ || !queue_.empty(); });
                if (stopping_ && queue_.empty()) {
                    return;
                }
                item = std::move(queue_.front());
                queue_.pop_front();
            }

            process_item(item);
            unregister_cancel_flag(item.header.req_id, item.cancel_flag);
        }
    }

    void process_item(const WorkItem& item) {
        const uint64_t req_id = item.header.req_id;
        std::atomic<bool>* cancel_flag = item.cancel_flag.get();

        if (is_cancelled(cancel_flag)) {
            send_frame(encode_error_frame(req_id, "CANCELLED", "Operation cancelled"));
            return;
        }

        const auto msg_type = static_cast<BinaryMsgType>(item.header.msg_type);
        try {
            switch (msg_type) {
                case BinaryMsgType::List:
                    handle_list(req_id, item.payload, cancel_flag);
                    break;
                case BinaryMsgType::Extract:
                    handle_extract(req_id, item.payload, cancel_flag);
                    break;
                case BinaryMsgType::Compress:
                    handle_compress(req_id, item.payload, cancel_flag);
                    break;
                case BinaryMsgType::Add:
                    handle_add(req_id, item.payload, cancel_flag);
                    break;
                case BinaryMsgType::Delete:
                    handle_delete(req_id, item.payload, cancel_flag);
                    break;
                case BinaryMsgType::Rename:
                    handle_rename(req_id, item.payload, cancel_flag);
                    break;
                case BinaryMsgType::Test:
                    handle_test(req_id, item.payload, cancel_flag);
                    break;
                default:
                    send_frame(encode_error_frame(req_id, "UNKNOWN_COMMAND", "Unknown binary message type"));
                    break;
            }
        } catch (const OperationCancelled&) {
            send_frame(encode_error_frame(req_id, "CANCELLED", "Operation cancelled"));
        } catch (const bit7z::BitException& ex) {
            if (is_cancelled(cancel_flag)) {
                send_frame(encode_error_frame(req_id, "CANCELLED", "Operation cancelled"));
            } else {
                send_frame(encode_error_frame(req_id, "BIT7Z_ERROR", ex.what()));
            }
        } catch (const std::exception& ex) {
            if (is_cancelled(cancel_flag)) {
                send_frame(encode_error_frame(req_id, "CANCELLED", "Operation cancelled"));
            } else {
                send_frame(encode_error_frame(req_id, "INTERNAL_ERROR", ex.what()));
            }
        }
    }

    void handle_list(uint64_t req_id,
                     const std::vector<uint8_t>& payload,
                     std::atomic<bool>* cancel_flag) {
        ListParams params;
        if (!decode_list_request(payload, params) || params.archive.empty()) {
            send_frame(encode_error_frame(req_id, "INVALID_PARAMS", "Invalid LIST request payload"));
            return;
        }

        const std::string fmt_lower = to_lower_ascii(params.format);
        const bit7z::BitInFormat* outer_fmt = resolve_outer_in_format(fmt_lower);
        if (!outer_fmt) {
            send_frame(encode_error_frame(
                req_id, "INVALID_PARAMS", "Unsupported archive format: " + params.format));
            return;
        }

        const bool password_provided = !params.password.empty();
        const ProgressSink sink = make_progress_sink(req_id);

        std::string split_err_code;
        std::string split_err_msg;
        if (!validate_split_archive_volumes(params.archive, split_err_code, split_err_msg)) {
            send_frame(encode_error_frame(req_id, split_err_code, split_err_msg));
            return;
        }

        std::optional<ReaderCacheKey> cache_key;
        uint64_t pool_version = 0;
        std::unique_ptr<bit7z::BitArchiveReader> outer_reader;

        if (!password_provided) {
            cache_key = make_reader_cache_key(params.archive, fmt_lower);
            if (cache_key) {
                auto checked = reader_pool_.checkout(*cache_key);
                outer_reader = std::move(checked.reader);
                pool_version = checked.version;
            }
        }

        try {
            if (!outer_reader) {
                outer_reader = std::make_unique<bit7z::BitArchiveReader>(
                    lib_, params.archive, *outer_fmt, params.password);
            }

            bool any_encrypted = false;
            with_resolved_reader(
                lib_, *outer_reader, params.archive, fmt_lower, params.tar_cache_path,
                &sink, cancel_flag,
                [&](bit7z::BitArchiveReader& reader,
                    std::optional<uint64_t> outer_pack_size,
                    bool used_tar_cache) {
                    const uint64_t items_count = reader.itemsCount();
                    const uint64_t total_size = reader.size();
                    const uint64_t packed_size = outer_pack_size.value_or(reader.packSize());

                    send_frame(encode_list_meta_frame(
                        req_id, items_count, total_size, packed_size, used_tar_cache));

                    const ZipEncodingResolver zip_encoding(reader, params.encoding);
                    const bool emit_reading_progress =
                        items_count > 0 && (outer_pack_size.has_value() || items_count >= kListChunkSize);
                    auto last_read_progress = std::chrono::steady_clock::now();
                    if (emit_reading_progress) {
                        sink(ProgressStage::ReadingEntries, 0, items_count, 0, "");
                    }

                    std::vector<BinaryListRecord> chunk;
                    chunk.reserve(kListChunkSize);
                    uint64_t sent_count = 0;

                    for (const auto& item : reader) {
                        BinaryListRecord rec;
                        uint8_t flags = 0;
                        if (item.isDir()) flags |= 0x01u;
                        if (item.isEncrypted()) {
                            flags |= 0x02u;
                            any_encrypted = true;
                        }
                        const auto mtime = extract_item_mtime(item);
                        if (mtime.has_value()) {
                            flags |= 0x04u;
                            rec.modified_at = *mtime;
                        } else {
                            rec.modified_at = 0;
                        }
                        const uint32_t crc = item.crc();
                        if (!item.isDir() || crc != 0) {
                            flags |= 0x08u;
                            rec.crc = crc;
                        }
                        rec.flags = flags;
                        rec.size = item.size();
                        rec.packed_size = item.packSize();
                        if (zip_encoding.has_remapping()) {
                            rec.path = zip_encoding.decode(item.path());
                            std::string trimmed = rec.path;
                            while (!trimmed.empty() && (trimmed.back() == '/' || trimmed.back() == '\\')) {
                                trimmed.pop_back();
                            }
                            const size_t slash = trimmed.find_last_of("/\\");
                            if (slash != std::string::npos && slash + 1 < trimmed.size()) {
                                rec.name = trimmed.substr(slash + 1);
                            } else if (!trimmed.empty()) {
                                rec.name = trimmed;
                            } else {
                                rec.name = zip_encoding.decode(item.name());
                            }
                        } else {
                            rec.path = item.path();
                            rec.name = item.name();
                        }
                        chunk.push_back(std::move(rec));

                        if (chunk.size() >= kListChunkSize) {
                            if (is_cancelled(cancel_flag)) {
                                throw OperationCancelled();
                            }
                            sent_count += chunk.size();
                            send_frame(encode_list_chunk_frame(req_id, chunk));
                            chunk.clear();
                            if (emit_reading_progress) {
                                const auto now = std::chrono::steady_clock::now();
                                if (now - last_read_progress >= std::chrono::milliseconds(50)) {
                                    last_read_progress = now;
                                    sink(ProgressStage::ReadingEntries, sent_count, items_count, 0, "");
                                }
                            }
                        }
                    }

                    if (is_cancelled(cancel_flag)) {
                        throw OperationCancelled();
                    }
                    if (!chunk.empty()) {
                        sent_count += chunk.size();
                        send_frame(encode_list_chunk_frame(req_id, chunk));
                    }
                    if (emit_reading_progress) {
                        sink(ProgressStage::ReadingEntries, items_count, items_count, 0, "");
                    }
                });

            if (cache_key && !any_encrypted && !is_cancelled(cancel_flag)) {
                reader_pool_.checkin(*cache_key, pool_version, std::move(outer_reader));
            }
            send_frame(encode_result_frame(req_id, false, 0));
        } catch (const OperationCancelled&) {
            send_frame(encode_error_frame(req_id, "CANCELLED", "Operation cancelled"));
        } catch (const bit7z::BitException& ex) {
            if (is_cancelled(cancel_flag)) {
                send_frame(encode_error_frame(req_id, "CANCELLED", "Operation cancelled"));
            } else {
                const std::string code = classify_bit7z_error(ex, password_provided);
                if (code == "BIT7Z_ERROR") {
                    const std::string missing_vol = find_missing_next_volume(params.archive);
                    if (!missing_vol.empty()) {
                        send_frame(encode_error_frame(
                            req_id, "MISSING_VOLUME", "Missing archive volume: " + missing_vol));
                        return;
                    }
                }
                send_frame(encode_error_frame(req_id, code, ex.what()));
            }
        }
    }

    void handle_extract(uint64_t req_id,
                        const std::vector<uint8_t>& payload,
                        std::atomic<bool>* cancel_flag) {
        ExtractParams params;
        if (!decode_extract_request(payload, params) ||
            params.archive.empty() || params.output.empty()) {
            send_frame(encode_error_frame(
                req_id, "INVALID_PARAMS", "Invalid EXTRACT request payload"));
            return;
        }

        const std::string fmt_lower = to_lower_ascii(params.format);
        const bit7z::BitInFormat* outer_fmt = resolve_outer_in_format(fmt_lower);
        if (!outer_fmt) {
            send_frame(encode_error_frame(
                req_id, "INVALID_PARAMS", "Unsupported archive format: " + params.format));
            return;
        }

        const bool password_provided = !params.password.empty();
        const ProgressSink sink = make_progress_sink(req_id);

        std::string split_err_code;
        std::string split_err_msg;
        if (!validate_split_archive_volumes(params.archive, split_err_code, split_err_msg)) {
            send_frame(encode_error_frame(req_id, split_err_code, split_err_msg));
            return;
        }

        std::optional<ReaderCacheKey> cache_key;
        uint64_t pool_version = 0;
        std::unique_ptr<bit7z::BitArchiveReader> outer_reader;

        if (!password_provided) {
            cache_key = make_reader_cache_key(params.archive, fmt_lower);
            if (cache_key) {
                auto checked = reader_pool_.checkout(*cache_key);
                outer_reader = std::move(checked.reader);
                pool_version = checked.version;
            }
        }

        try {
            if (!outer_reader) {
                outer_reader = std::make_unique<bit7z::BitArchiveReader>(
                    lib_, params.archive, *outer_fmt, params.password);
            }

            std::string error_msg;
            std::string error_code = "PATH_NOT_FOUND";
            bool ok = false;
            with_resolved_reader(
                lib_, *outer_reader, params.archive, fmt_lower, params.tar_cache_path,
                &sink, cancel_flag,
                [&](bit7z::BitArchiveReader& reader, std::optional<uint64_t> outer_pack_size, bool used_tar_cache) {
                    const uint8_t stage = (outer_pack_size.has_value() && !used_tar_cache)
                        ? ProgressStage::ExtractingInner
                        : ProgressStage::Normal;
                    ok = extract_from_reader(
                        reader, params, &sink, cancel_flag, error_msg, error_code, stage);
                });

            if (!ok) {
                send_frame(encode_error_frame(req_id, error_code, error_msg));
                return;
            }

            if (cache_key && !is_cancelled(cancel_flag)) {
                reader_pool_.checkin(*cache_key, pool_version, std::move(outer_reader));
            }
            send_frame(encode_result_frame(req_id, false, 0));
        } catch (const OperationCancelled&) {
            send_frame(encode_error_frame(req_id, "CANCELLED", "Operation cancelled"));
        } catch (const bit7z::BitException& ex) {
            if (is_cancelled(cancel_flag)) {
                send_frame(encode_error_frame(req_id, "CANCELLED", "Operation cancelled"));
            } else {
                const std::string code = classify_bit7z_error(ex, password_provided);
                if (code == "BIT7Z_ERROR") {
                    const std::string missing_vol = find_missing_next_volume(params.archive);
                    if (!missing_vol.empty()) {
                        send_frame(encode_error_frame(
                            req_id, "MISSING_VOLUME", "Missing archive volume: " + missing_vol));
                        return;
                    }
                }
                send_frame(encode_error_frame(req_id, code, ex.what()));
            }
        }
    }

    void handle_compress(uint64_t req_id,
                         const std::vector<uint8_t>& payload,
                         std::atomic<bool>* cancel_flag) {
        CompressParams params;
        if (!decode_compress_request(payload, params)) {
            send_frame(encode_error_frame(
                req_id, "INVALID_PARAMS", "Invalid COMPRESS request payload"));
            return;
        }

        reader_pool_.invalidate(params.archive);
        const ProgressSink sink = make_progress_sink(req_id);
        const OperationOutcome out = run_compress(lib_, params, &sink, cancel_flag);
        reader_pool_.invalidate(params.archive);

        if (!out.ok) {
            send_frame(encode_error_frame(req_id, out.error_code, out.error_msg));
            return;
        }
        send_frame(encode_result_frame(req_id, out.archive_deleted, out.output_size));
    }

    void handle_add(uint64_t req_id,
                    const std::vector<uint8_t>& payload,
                    std::atomic<bool>* cancel_flag) {
        AddParams params;
        if (!decode_add_request(payload, params)) {
            send_frame(encode_error_frame(
                req_id, "INVALID_PARAMS", "Invalid ADD request payload"));
            return;
        }

        reader_pool_.invalidate(params.archive);
        const ProgressSink sink = make_progress_sink(req_id);
        const OperationOutcome out = run_add(lib_, params, &sink, cancel_flag);
        reader_pool_.invalidate(params.archive);

        if (!out.ok) {
            send_frame(encode_error_frame(req_id, out.error_code, out.error_msg));
            return;
        }
        send_frame(encode_result_frame(req_id, out.archive_deleted, out.output_size));
    }

    void handle_delete(uint64_t req_id,
                       const std::vector<uint8_t>& payload,
                       std::atomic<bool>* cancel_flag) {
        DeleteParams params;
        if (!decode_delete_request(payload, params)) {
            send_frame(encode_error_frame(
                req_id, "INVALID_PARAMS", "Invalid DELETE request payload"));
            return;
        }

        reader_pool_.invalidate(params.archive);
        const ProgressSink sink = make_progress_sink(req_id);
        const OperationOutcome out = run_delete(lib_, params, &sink, cancel_flag);
        reader_pool_.invalidate(params.archive);

        if (!out.ok) {
            send_frame(encode_error_frame(req_id, out.error_code, out.error_msg));
            return;
        }
        send_frame(encode_result_frame(req_id, out.archive_deleted, out.output_size));
    }

    void handle_rename(uint64_t req_id,
                       const std::vector<uint8_t>& payload,
                       std::atomic<bool>* cancel_flag) {
        RenameParams params;
        if (!decode_rename_request(payload, params)) {
            send_frame(encode_error_frame(
                req_id, "INVALID_PARAMS", "Invalid RENAME request payload"));
            return;
        }

        reader_pool_.invalidate(params.archive);
        const ProgressSink sink = make_progress_sink(req_id);
        const OperationOutcome out = run_rename(lib_, params, &sink, cancel_flag);
        reader_pool_.invalidate(params.archive);

        if (!out.ok) {
            send_frame(encode_error_frame(req_id, out.error_code, out.error_msg));
            return;
        }
        send_frame(encode_result_frame(req_id, out.archive_deleted, out.output_size));
    }

    void handle_test(uint64_t req_id,
                     const std::vector<uint8_t>& payload,
                     std::atomic<bool>* cancel_flag) {
        TestParams params;
        if (!decode_test_request(payload, params)) {
            send_frame(encode_error_frame(
                req_id, "INVALID_PARAMS", "Invalid TEST request payload"));
            return;
        }

        const ProgressSink sink = make_progress_sink(req_id);
        const OperationOutcome out = run_test(lib_, params, &sink, cancel_flag);

        if (!out.ok) {
            send_frame(encode_error_frame(req_id, out.error_code, out.error_msg));
            return;
        }
        send_frame(encode_result_frame(req_id, out.archive_deleted, out.output_size));
    }

    bit7z::Bit7zLibrary& lib_;
    int client_fd_;

    ReaderPool reader_pool_;

    std::mutex write_mutex_;
    std::atomic<bool> write_broken_{false};

    std::mutex cancel_mutex_;
    std::unordered_map<uint64_t, std::shared_ptr<std::atomic<bool>>> cancel_flags_;

    std::mutex queue_mutex_;
    std::condition_variable queue_cv_;
    std::deque<WorkItem> queue_;
    bool stopping_ = false;
    std::vector<std::thread> workers_;
};

struct ScopedSocketGuard {
    int fd = -1;
    std::string unlink_path;

    ~ScopedSocketGuard() {
        if (fd >= 0) {
            ::close(fd);
        }
        if (!unlink_path.empty()) {
            ::unlink(unlink_path.c_str());
        }
    }
};

} // namespace

int run_binary_server(const std::string& lib_path, const std::string& socket_path) {
    std::signal(SIGPIPE, SIG_IGN);

    if (socket_path.empty()) {
        std::cerr << "bento7z: empty socket path\n";
        return 1;
    }

    sockaddr_un addr{};
    if (socket_path.size() >= sizeof(addr.sun_path)) {
        std::cerr << "bento7z: socket path too long: " << socket_path << '\n';
        return 1;
    }

    try {
        bit7z::Bit7zLibrary lib(lib_path);

        const fs::path sock_fs(socket_path);
        if (sock_fs.has_parent_path()) {
            std::error_code ec;
            fs::create_directories(sock_fs.parent_path(), ec);
        }

        ::unlink(socket_path.c_str());

        const int server_fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
        if (server_fd < 0) {
            std::cerr << "bento7z: socket() failed: " << std::strerror(errno) << '\n';
            return 1;
        }

        ScopedSocketGuard server_guard{server_fd, socket_path};

        addr.sun_family = AF_UNIX;
        std::memcpy(addr.sun_path, socket_path.c_str(), socket_path.size() + 1);

        if (::bind(server_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
            std::cerr << "bento7z: bind() failed: " << std::strerror(errno) << '\n';
            return 1;
        }

        if (::listen(server_fd, 4) < 0) {
            std::cerr << "bento7z: listen() failed: " << std::strerror(errno) << '\n';
            return 1;
        }

        int client_fd = -1;
        while (true) {
            client_fd = ::accept(server_fd, nullptr, nullptr);
            if (client_fd >= 0) {
                break;
            }
            if (errno == EINTR) {
                continue;
            }
            std::cerr << "bento7z: accept() failed: " << std::strerror(errno) << '\n';
            return 1;
        }

        ScopedSocketGuard client_guard{client_fd, {}};

        BinaryServerSession session(lib, client_fd);
        session.run();
        return 0;
    } catch (const std::exception& ex) {
        std::cerr << "bento7z: binary server error: " << ex.what() << '\n';
        return 1;
    }
}

} // namespace bento7z
