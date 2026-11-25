#pragma once

#include "bento7z/protocol.hpp"
#include <bit7z/bitabstractarchivehandler.hpp>
#include <bit7z/bittypes.hpp>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>

namespace bento7z {

struct ProgressStage {
    static constexpr uint8_t Normal = 0;
    static constexpr uint8_t UnpackingOuter = 1;
    static constexpr uint8_t ReadingEntries = 2;
    static constexpr uint8_t CompressingOuter = 3;
    static constexpr uint8_t PackingTar = 4;
    static constexpr uint8_t ExtractingInner = 5;
};

using ProgressSink = std::function<void(uint8_t stage,
                                        uint64_t processed,
                                        uint64_t total,
                                        uint32_t files_delta,
                                        const std::string& current_file)>;

class OperationCancelled : public std::runtime_error {
public:
    OperationCancelled() : std::runtime_error("Operation cancelled") {}
};

inline bool is_cancelled(const std::atomic<bool>* cancel_flag) noexcept {
    return cancel_flag != nullptr && cancel_flag->load(std::memory_order_relaxed);
}

inline ProgressSink make_jsonl_progress_sink(const std::string& req_id) {
    return [req_id](uint8_t stage,
                    uint64_t processed,
                    uint64_t total,
                    uint32_t files_delta,
                    const std::string& current_file) {
        ProgressData pd;
        pd.processed_bytes = processed;
        pd.total_bytes = total;
        pd.current_file = current_file;
        pd.files_delta = files_delta;
        pd.stage = stage;
        make_progress(req_id, pd).write(std::cout);
    };
}

class ScopedHandlerCallbacks {
public:
    explicit ScopedHandlerCallbacks(bit7z::BitAbstractArchiveHandler& handler)
        : handler_(handler) {}

    ~ScopedHandlerCallbacks() {
        handler_.setTotalCallback({});
        handler_.setProgressCallback({});
        handler_.setFileCallback({});
    }

    ScopedHandlerCallbacks(const ScopedHandlerCallbacks&) = delete;
    ScopedHandlerCallbacks& operator=(const ScopedHandlerCallbacks&) = delete;

private:
    bit7z::BitAbstractArchiveHandler& handler_;
};

class ProgressAdapter {
public:
    explicit ProgressAdapter(ProgressSink sink,
                             uint8_t stage = ProgressStage::Normal,
                             std::atomic<bool>* cancel_flag = nullptr,
                             uint64_t fallback_total = 0,
                             std::string initial_file = {})
        : sink_(std::move(sink)),
          stage_(stage),
          cancel_flag_(cancel_flag),
          fallback_total_(fallback_total),
          total_bytes_(fallback_total),
          current_file_(std::move(initial_file)) {}

    explicit ProgressAdapter(const std::string& req_id,
                             uint8_t stage = ProgressStage::Normal,
                             std::atomic<bool>* cancel_flag = nullptr,
                             uint64_t fallback_total = 0,
                             std::string initial_file = {})
        : sink_(make_jsonl_progress_sink(req_id)),
          stage_(stage),
          cancel_flag_(cancel_flag),
          fallback_total_(fallback_total),
          total_bytes_(fallback_total),
          current_file_(std::move(initial_file)) {}

    void attach(bit7z::BitAbstractArchiveHandler& handler) {
        handler.setTotalCallback(total_callback());
        handler.setProgressCallback(progress_callback());
        handler.setFileCallback(file_callback());
    }

    void emit_initial() {
        if (is_cancelled(cancel_flag_) || !sink_) {
            return;
        }
        uint64_t total = 0;
        std::string file;
        const uint8_t st = stage_;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            total = (total_bytes_ > 0) ? total_bytes_ : fallback_total_;
            file = current_file_;
            last_pct_ = (total > 0) ? 0 : -1;
            last_write_ = clock::now();
        }
        sink_(st, 0, total, 0, file);
    }

    bit7z::TotalCallback total_callback() {
        return [this](uint64_t total) {
            if (is_cancelled(cancel_flag_)) {
                return;
            }
            uint64_t reported_processed = 0;
            uint64_t effective_total = 0;
            uint32_t delta = 0;
            std::string file;
            uint8_t st = stage_;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (total > 0) {
                    total_bytes_ = total;
                }
                effective_total = (total_bytes_ > 0) ? total_bytes_ : fallback_total_;
                reported_processed = (effective_total > 0 && processed_bytes_ > effective_total)
                    ? effective_total
                    : processed_bytes_;
                if (effective_total > 0) {
                    last_pct_ = static_cast<int>((reported_processed * 100) / effective_total);
                }
                last_write_ = clock::now();
                delta = files_delta_;
                files_delta_ = 0;
                file = current_file_;
            }
            if (sink_) {
                sink_(st, reported_processed, effective_total, delta, file);
            }
        };
    }

    bit7z::ProgressCallback progress_callback() {
        return [this](uint64_t processed) -> bool {
            if (is_cancelled(cancel_flag_)) {
                return false;
            }

            bool should_emit = false;
            uint64_t reported_processed = processed;
            uint64_t total = 0;
            uint32_t delta = 0;
            std::string file;
            uint8_t st = stage_;

            {
                std::lock_guard<std::mutex> lock(mutex_);
                total = (total_bytes_ > 0) ? total_bytes_ : fallback_total_;
                if (total > 0 && processed > total) {
                    reported_processed = total;
                }
                processed_bytes_ = reported_processed;

                const auto now = clock::now();
                const bool completed = (total > 0 && reported_processed >= total);
                const int pct = (total > 0)
                    ? static_cast<int>((reported_processed * 100) / total)
                    : -1;
                const bool pct_jumped = (pct >= 0 && pct > last_pct_);
                const bool interval_elapsed = (now - last_write_) >= min_interval_;

                if (completed || pct_jumped || interval_elapsed) {
                    if (pct >= 0) {
                        last_pct_ = pct;
                    }
                    last_write_ = now;
                    delta = files_delta_;
                    files_delta_ = 0;
                    file = current_file_;
                    should_emit = true;
                }
            }

            if (should_emit && sink_) {
                sink_(st, reported_processed, total, delta, file);
            }
            return !is_cancelled(cancel_flag_);
        };
    }

    bit7z::FileCallback file_callback() {
        return [this](const bit7z::tstring& path) {
            if (is_cancelled(cancel_flag_)) {
                return;
            }

            bool should_emit = false;
            uint64_t processed = 0;
            uint64_t total = 0;
            uint32_t delta = 0;
            std::string file;
            uint8_t st = stage_;

            {
                std::lock_guard<std::mutex> lock(mutex_);
                current_file_ = path;
                ++files_delta_;

                const auto now = clock::now();
                if ((now - last_write_) >= min_interval_) {
                    last_write_ = now;
                    processed = processed_bytes_;
                    total = (total_bytes_ > 0) ? total_bytes_ : fallback_total_;
                    delta = files_delta_;
                    files_delta_ = 0;
                    file = current_file_;
                    should_emit = true;
                }
            }

            if (should_emit && sink_) {
                sink_(st, processed, total, delta, file);
            }
        };
    }

    void flush() {
        if (is_cancelled(cancel_flag_) || !sink_) {
            return;
        }

        bool should_emit = false;
        uint64_t processed = 0;
        uint64_t total = 0;
        uint32_t delta = 0;
        std::string file;
        uint8_t st = stage_;

        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (files_delta_ > 0) {
                processed = processed_bytes_;
                total = (total_bytes_ > 0) ? total_bytes_ : fallback_total_;
                delta = files_delta_;
                files_delta_ = 0;
                file = current_file_;
                last_write_ = clock::now();
                should_emit = true;
            }
        }

        if (should_emit) {
            sink_(st, processed, total, delta, file);
        }
    }

    void complete() {
        if (is_cancelled(cancel_flag_) || !sink_) {
            return;
        }

        uint64_t processed = 0;
        uint64_t total = 0;
        uint32_t delta = 0;
        std::string file;
        const uint8_t st = stage_;

        {
            std::lock_guard<std::mutex> lock(mutex_);
            total = (total_bytes_ > 0) ? total_bytes_ : fallback_total_;
            processed = (total > 0) ? total : processed_bytes_;
            processed_bytes_ = processed;
            if (total > 0) {
                last_pct_ = 100;
            }
            delta = files_delta_;
            files_delta_ = 0;
            file = current_file_;
            last_write_ = clock::now();
        }

        sink_(st, processed, total, delta, file);
    }

private:
    using clock = std::chrono::steady_clock;
    static constexpr auto min_interval_ = std::chrono::milliseconds(50);

    ProgressSink sink_;
    uint8_t stage_ = ProgressStage::Normal;
    std::atomic<bool>* cancel_flag_ = nullptr;
    uint64_t fallback_total_ = 0;

    std::mutex mutex_;
    uint64_t processed_bytes_ = 0;
    uint64_t total_bytes_ = 0;
    uint32_t files_delta_ = 0;
    std::string current_file_;
    int last_pct_ = -1;
    clock::time_point last_write_ = clock::now() - min_interval_;
};

} // namespace bento7z
