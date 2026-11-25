#pragma once

#include "bento7z/progress.hpp"
#include "bento7z/protocol.hpp"

#include <atomic>
#include <cstdint>
#include <optional>
#include <string>

#include <bit7z/bit7zlibrary.hpp>

namespace bit7z {
class BitArchiveItemOffset;
class BitArchiveReader;
class BitException;
class BitInOutFormat;
}

namespace bento7z {

struct OperationOutcome {
    bool ok = false;
    bool archive_deleted = false;
    uint64_t output_size = 0;
    std::string error_code;
    std::string error_msg;
};

std::string classify_bit7z_error(const bit7z::BitException& ex, bool password_provided);

std::optional<int64_t> extract_item_mtime(const bit7z::BitArchiveItemOffset& item);

const bit7z::BitInOutFormat* resolve_inplace_format(
    const bit7z::Bit7zLibrary& lib,
    const std::string& archive,
    const std::string& format,
    const std::string& password,
    std::string& error_code,
    std::string& error_msg);

bool extract_from_reader(bit7z::BitArchiveReader& reader,
                         const ExtractParams& params,
                         const ProgressSink* progress_sink,
                         std::atomic<bool>* cancel_flag,
                         std::string& error_msg,
                         std::string& error_code,
                         uint8_t progress_stage = ProgressStage::Normal);

OperationOutcome run_compress(const bit7z::Bit7zLibrary& lib,
                              const CompressParams& params,
                              const ProgressSink* progress_sink,
                              std::atomic<bool>* cancel_flag);

OperationOutcome run_add(const bit7z::Bit7zLibrary& lib,
                         const AddParams& params,
                         const ProgressSink* progress_sink,
                         std::atomic<bool>* cancel_flag);

OperationOutcome run_delete(const bit7z::Bit7zLibrary& lib,
                            const DeleteParams& params,
                            const ProgressSink* progress_sink,
                            std::atomic<bool>* cancel_flag);

/// Handler for JSONL archive operations. All callbacks write JSONL to stdout.
class CommandHandler {
public:
    explicit CommandHandler(const std::string& lib_path);

    /// Execute a command. Response is written to stdout.
    void execute(const Request& req);

private:
    void handle_list(const Request& req);
    void handle_compress(const Request& req);
    void handle_extract(const Request& req);
    void handle_add(const Request& req);
    void handle_delete(const Request& req);

    bit7z::Bit7zLibrary lib_;
};

} // namespace bento7z
