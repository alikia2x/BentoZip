#include "binary_protocol.hpp"

#include <cstring>
#include <utility>

namespace bento7z {

namespace {

uint32_t load_u32_le(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) |
           (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

uint64_t load_u64_le(const uint8_t* p) {
    return static_cast<uint64_t>(p[0]) |
           (static_cast<uint64_t>(p[1]) << 8) |
           (static_cast<uint64_t>(p[2]) << 16) |
           (static_cast<uint64_t>(p[3]) << 24) |
           (static_cast<uint64_t>(p[4]) << 32) |
           (static_cast<uint64_t>(p[5]) << 40) |
           (static_cast<uint64_t>(p[6]) << 48) |
           (static_cast<uint64_t>(p[7]) << 56);
}

void store_u32_le(uint8_t* p, uint32_t v) {
    p[0] = static_cast<uint8_t>(v & 0xFFu);
    p[1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
    p[2] = static_cast<uint8_t>((v >> 16) & 0xFFu);
    p[3] = static_cast<uint8_t>((v >> 24) & 0xFFu);
}

void store_u64_le(uint8_t* p, uint64_t v) {
    p[0] = static_cast<uint8_t>(v & 0xFFu);
    p[1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
    p[2] = static_cast<uint8_t>((v >> 16) & 0xFFu);
    p[3] = static_cast<uint8_t>((v >> 24) & 0xFFu);
    p[4] = static_cast<uint8_t>((v >> 32) & 0xFFu);
    p[5] = static_cast<uint8_t>((v >> 40) & 0xFFu);
    p[6] = static_cast<uint8_t>((v >> 48) & 0xFFu);
    p[7] = static_cast<uint8_t>((v >> 56) & 0xFFu);
}

} // namespace

BinaryFrameHeader decode_frame_header(const uint8_t* bytes) {
    BinaryFrameHeader h;
    h.payload_len = load_u32_le(bytes);
    h.msg_type = bytes[4];
    h.req_id = load_u64_le(bytes + 5);
    return h;
}

void encode_frame_header(uint8_t* out, uint32_t payload_len, uint8_t msg_type, uint64_t req_id) {
    store_u32_le(out, payload_len);
    out[4] = msg_type;
    store_u64_le(out + 5, req_id);
}

bool BinaryReader::read_u8(uint8_t& out) {
    if (remaining() < 1) return false;
    out = data_[pos_++];
    return true;
}

bool BinaryReader::read_u32(uint32_t& out) {
    if (remaining() < 4) return false;
    out = load_u32_le(data_ + pos_);
    pos_ += 4;
    return true;
}

bool BinaryReader::read_u64(uint64_t& out) {
    if (remaining() < 8) return false;
    out = load_u64_le(data_ + pos_);
    pos_ += 8;
    return true;
}

bool BinaryReader::read_i64(int64_t& out) {
    uint64_t raw = 0;
    if (!read_u64(raw)) return false;
    out = static_cast<int64_t>(raw);
    return true;
}

bool BinaryReader::read_string(std::string& out) {
    uint32_t len = 0;
    if (!read_u32(len)) return false;
    if (remaining() < len) return false;
    out.assign(reinterpret_cast<const char*>(data_ + pos_), len);
    pos_ += len;
    return true;
}

bool BinaryReader::read_string_array(std::vector<std::string>& out) {
    uint32_t count = 0;
    if (!read_u32(count)) return false;
    // Each string requires at least 4 bytes for its length prefix.
    if (static_cast<size_t>(count) > remaining() / 4) return false;
    out.clear();
    out.reserve(count);
    for (uint32_t i = 0; i < count; ++i) {
        std::string s;
        if (!read_string(s)) return false;
        out.push_back(std::move(s));
    }
    return true;
}

BinaryFrameBuilder::BinaryFrameBuilder(size_t reserve_payload) {
    buf_.reserve(kBinaryFrameHeaderSize + reserve_payload);
    buf_.resize(kBinaryFrameHeaderSize, 0);
}

void BinaryFrameBuilder::write_u8(uint8_t v) {
    buf_.push_back(v);
}

void BinaryFrameBuilder::write_u32(uint32_t v) {
    const size_t offset = buf_.size();
    buf_.resize(offset + 4);
    store_u32_le(buf_.data() + offset, v);
}

void BinaryFrameBuilder::write_u64(uint64_t v) {
    const size_t offset = buf_.size();
    buf_.resize(offset + 8);
    store_u64_le(buf_.data() + offset, v);
}

void BinaryFrameBuilder::write_i64(int64_t v) {
    write_u64(static_cast<uint64_t>(v));
}

void BinaryFrameBuilder::write_string(std::string_view s) {
    write_u32(static_cast<uint32_t>(s.size()));
    if (!s.empty()) {
        const size_t offset = buf_.size();
        buf_.resize(offset + s.size());
        std::memcpy(buf_.data() + offset, s.data(), s.size());
    }
}

void BinaryFrameBuilder::write_string_array(const std::vector<std::string>& arr) {
    write_u32(static_cast<uint32_t>(arr.size()));
    for (const auto& s : arr) {
        write_string(s);
    }
}

std::vector<uint8_t> BinaryFrameBuilder::finalize(BinaryMsgType msg_type, uint64_t req_id) {
    const uint32_t payload_len = static_cast<uint32_t>(buf_.size() - kBinaryFrameHeaderSize);
    encode_frame_header(buf_.data(), payload_len, static_cast<uint8_t>(msg_type), req_id);
    return std::move(buf_);
}

bool decode_list_request(const std::vector<uint8_t>& payload, ListParams& out) {
    BinaryReader r(payload.data(), payload.size());
    if (!r.read_string(out.archive) ||
        !r.read_string(out.password) ||
        !r.read_string(out.format) ||
        !r.read_string(out.tar_cache_path)) {
        return false;
    }
    if (r.remaining() > 0) {
        if (!r.read_string(out.encoding)) {
            return false;
        }
    }
    return true;
}

bool decode_extract_request(const std::vector<uint8_t>& payload, ExtractParams& out) {
    BinaryReader r(payload.data(), payload.size());
    if (!r.read_string(out.archive) ||
        !r.read_string(out.output) ||
        !r.read_string(out.password) ||
        !r.read_string(out.format) ||
        !r.read_string(out.tar_cache_path) ||
        !r.read_string_array(out.entries)) {
        return false;
    }
    if (r.remaining() > 0) {
        if (!r.read_string(out.encoding)) {
            return false;
        }
    }
    return true;
}

bool decode_compress_request(const std::vector<uint8_t>& payload, CompressParams& out) {
    BinaryReader r(payload.data(), payload.size());
    uint8_t preserve = 1;
    if (!r.read_string(out.archive) ||
        !r.read_string(out.format) ||
        !r.read_string(out.level) ||
        !r.read_string(out.password) ||
        !r.read_u8(preserve) ||
        !r.read_string_array(out.paths) ||
        !r.read_string_array(out.exclude)) {
        return false;
    }
    out.preserve_paths = (preserve != 0);
    if (r.remaining() > 0) {
        if (!r.read_u64(out.volume_size_bytes) ||
            !r.read_string(out.encryption_method)) {
            return false;
        }
        if (r.remaining() > 0) {
            uint8_t flags = 0;
            if (!r.read_u8(flags)) {
                return false;
            }
            out.encrypt_headers = ((flags & 0x01u) != 0u);
            out.follow_symlinks = ((flags & 0x02u) != 0u);
        }
    }
    return true;
}

bool decode_add_request(const std::vector<uint8_t>& payload, AddParams& out) {
    BinaryReader r(payload.data(), payload.size());
    if (!r.read_string(out.archive) ||
        !r.read_string(out.password) ||
        !r.read_string(out.format) ||
        !r.read_string_array(out.paths)) {
        return false;
    }
    if (r.remaining() > 0) {
        if (!r.read_string(out.target_prefix)) {
            return false;
        }
    }
    return true;
}

bool decode_delete_request(const std::vector<uint8_t>& payload, DeleteParams& out) {
    BinaryReader r(payload.data(), payload.size());
    return r.read_string(out.archive) &&
           r.read_string(out.password) &&
           r.read_string(out.format) &&
           r.read_string_array(out.entries);
}

bool decode_rename_request(const std::vector<uint8_t>& payload, RenameParams& out) {
    BinaryReader r(payload.data(), payload.size());
    return r.read_string(out.archive) &&
           r.read_string(out.password) &&
           r.read_string(out.format) &&
           r.read_string(out.old_path) &&
           r.read_string(out.new_path);
}

bool decode_test_request(const std::vector<uint8_t>& payload, TestParams& out) {
    BinaryReader r(payload.data(), payload.size());
    return r.read_string(out.archive) &&
           r.read_string(out.password) &&
           r.read_string(out.format) &&
           r.read_string(out.tar_cache_path);
}

bool decode_move_request(const std::vector<uint8_t>& payload, MoveParams& out) {
    BinaryReader r(payload.data(), payload.size());
    return r.read_string(out.archive) &&
           r.read_string(out.password) &&
           r.read_string(out.format) &&
           r.read_string_array(out.entries) &&
           r.read_string(out.target_dir);
}

bool decode_update_password_request(const std::vector<uint8_t>& payload, UpdatePasswordParams& out) {
    BinaryReader r(payload.data(), payload.size());
    uint8_t encrypt_headers = 1;
    if (!r.read_string(out.archive) ||
        !r.read_string(out.old_password) ||
        !r.read_string(out.new_password) ||
        !r.read_string(out.format) ||
        !r.read_string(out.encryption_method) ||
        !r.read_u8(encrypt_headers)) {
        return false;
    }
    out.encrypt_headers = (encrypt_headers != 0);
    return true;
}

std::vector<uint8_t> encode_progress_frame(uint64_t req_id,
                                           uint8_t stage,
                                           uint64_t processed_bytes,
                                           uint64_t total_bytes,
                                           uint32_t files_delta,
                                           std::string_view current_file) {
    BinaryFrameBuilder b(1 + 8 + 8 + 4 + 4 + current_file.size());
    b.write_u8(stage);
    b.write_u64(processed_bytes);
    b.write_u64(total_bytes);
    b.write_u32(files_delta);
    b.write_string(current_file);
    return b.finalize(BinaryMsgType::Progress, req_id);
}

std::vector<uint8_t> encode_list_meta_frame(uint64_t req_id,
                                            uint64_t items_count,
                                            uint64_t total_size,
                                            uint64_t packed_size,
                                            bool used_tar_cache,
                                            std::string_view comment) {
    BinaryFrameBuilder b(8 + 8 + 8 + 1 + 4 + comment.size());
    b.write_u64(items_count);
    b.write_u64(total_size);
    b.write_u64(packed_size);
    b.write_u8(used_tar_cache ? 1 : 0);
    b.write_string(comment);
    return b.finalize(BinaryMsgType::ListMeta, req_id);
}

std::vector<uint8_t> encode_list_chunk_frame(uint64_t req_id,
                                             const std::vector<BinaryListRecord>& records) {
    size_t est_size = 4;
    for (const auto& rec : records) {
        est_size += 1 + 8 + 8 + 8 + ((rec.flags & 0x08u) ? 4 : 0) +
                    4 + rec.path.size() + 4 + rec.name.size();
    }
    BinaryFrameBuilder b(est_size);
    b.write_u32(static_cast<uint32_t>(records.size()));
    for (const auto& rec : records) {
        b.write_u8(rec.flags);
        b.write_u64(rec.size);
        b.write_u64(rec.packed_size);
        b.write_i64(rec.modified_at);
        if ((rec.flags & 0x08u) != 0u) {
            b.write_u32(rec.crc);
        }
        b.write_string(rec.path);
        b.write_string(rec.name);
    }
    return b.finalize(BinaryMsgType::ListChunk, req_id);
}

std::vector<uint8_t> encode_result_frame(uint64_t req_id,
                                         bool archive_deleted,
                                         uint64_t output_size) {
    BinaryFrameBuilder b(1 + 8);
    b.write_u8(archive_deleted ? 1 : 0);
    b.write_u64(output_size);
    return b.finalize(BinaryMsgType::Result, req_id);
}

std::vector<uint8_t> encode_error_frame(uint64_t req_id,
                                        std::string_view code,
                                        std::string_view message) {
    BinaryFrameBuilder b(4 + code.size() + 4 + message.size());
    b.write_string(code);
    b.write_string(message);
    return b.finalize(BinaryMsgType::Error, req_id);
}

std::vector<uint8_t> encode_pong_frame(uint64_t req_id) {
    BinaryFrameBuilder b(0);
    return b.finalize(BinaryMsgType::Pong, req_id);
}

} // namespace bento7z
