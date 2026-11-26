#pragma once

#include "bento7z/protocol.hpp"

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace bento7z {

enum class BinaryMsgType : uint8_t {
    // Requests
    List = 1,
    Extract = 2,
    Compress = 3,
    Add = 4,
    Delete = 5,
    Cancel = 6,
    Ping = 7,
    Rename = 8,
    Test = 9,

    // Responses
    Progress = 101,
    ListMeta = 102,
    ListChunk = 103,
    Result = 104,
    Error = 105,
    Pong = 106
};

inline constexpr size_t kBinaryFrameHeaderSize = 13;
inline constexpr uint32_t kMaxBinaryPayloadSize = 64u * 1024u * 1024u;

struct BinaryFrameHeader {
    uint32_t payload_len = 0;
    uint8_t msg_type = 0;
    uint64_t req_id = 0;
};

struct BinaryListRecord {
    uint8_t flags = 0; // bit0=is_dir, bit1=is_encrypted, bit2=has_modified_at, bit3=has_crc
    uint64_t size = 0;
    uint64_t packed_size = 0;
    int64_t modified_at = 0;
    uint32_t crc = 0;
    std::string path;
    std::string name;
};

BinaryFrameHeader decode_frame_header(const uint8_t* bytes);
void encode_frame_header(uint8_t* out, uint32_t payload_len, uint8_t msg_type, uint64_t req_id);

class BinaryReader {
public:
    BinaryReader(const uint8_t* data, size_t size) : data_(data), size_(size) {}

    bool read_u8(uint8_t& out);
    bool read_u32(uint32_t& out);
    bool read_u64(uint64_t& out);
    bool read_i64(int64_t& out);
    bool read_string(std::string& out);
    bool read_string_array(std::vector<std::string>& out);

    size_t remaining() const noexcept { return size_ - pos_; }

private:
    const uint8_t* data_;
    size_t size_;
    size_t pos_ = 0;
};

class BinaryFrameBuilder {
public:
    explicit BinaryFrameBuilder(size_t reserve_payload = 64);

    void write_u8(uint8_t v);
    void write_u32(uint32_t v);
    void write_u64(uint64_t v);
    void write_i64(int64_t v);
    void write_string(std::string_view s);
    void write_string_array(const std::vector<std::string>& arr);

    std::vector<uint8_t> finalize(BinaryMsgType msg_type, uint64_t req_id);

private:
    std::vector<uint8_t> buf_;
};

bool decode_list_request(const std::vector<uint8_t>& payload, ListParams& out);
bool decode_extract_request(const std::vector<uint8_t>& payload, ExtractParams& out);
bool decode_compress_request(const std::vector<uint8_t>& payload, CompressParams& out);
bool decode_add_request(const std::vector<uint8_t>& payload, AddParams& out);
bool decode_delete_request(const std::vector<uint8_t>& payload, DeleteParams& out);
bool decode_rename_request(const std::vector<uint8_t>& payload, RenameParams& out);
bool decode_test_request(const std::vector<uint8_t>& payload, TestParams& out);

std::vector<uint8_t> encode_progress_frame(uint64_t req_id,
                                           uint8_t stage,
                                           uint64_t processed_bytes,
                                           uint64_t total_bytes,
                                           uint32_t files_delta,
                                           std::string_view current_file);

std::vector<uint8_t> encode_list_meta_frame(uint64_t req_id,
                                            uint64_t items_count,
                                            uint64_t total_size,
                                            uint64_t packed_size,
                                            bool used_tar_cache);

std::vector<uint8_t> encode_list_chunk_frame(uint64_t req_id,
                                             const std::vector<BinaryListRecord>& records);

std::vector<uint8_t> encode_result_frame(uint64_t req_id,
                                         bool archive_deleted,
                                         uint64_t output_size);

std::vector<uint8_t> encode_error_frame(uint64_t req_id,
                                        std::string_view code,
                                        std::string_view message);

std::vector<uint8_t> encode_pong_frame(uint64_t req_id);

} // namespace bento7z
