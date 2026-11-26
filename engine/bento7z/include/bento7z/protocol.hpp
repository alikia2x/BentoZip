#pragma once

#include <nlohmann/json.hpp>
#include <string>
#include <vector>
#include <optional>
#include <ostream>
#include <cstdint>

namespace bento7z {

using json = nlohmann::json;

struct ListParams {
    std::string archive;
    std::string password;       // empty = no password
    std::string format;         // empty or "auto" = auto-detect
    std::string tar_cache_path; // optional persistent .tar cache path for compound .tar.*
    std::string encoding;       // empty or "auto" = auto-detect
};

struct CompressParams {
    std::string archive;
    std::vector<std::string> paths;
    std::string format = "7z";
    std::string level = "normal";
    std::string password; // empty = no password
    bool preserve_paths = true;
    std::vector<std::string> exclude;
    uint64_t volume_size_bytes = 0;
    std::string encryption_method; // "", "aes256", "zipcrypto"
    bool encrypt_headers = true;
    bool follow_symlinks = false;
};

struct ExtractParams {
    std::string archive;
    std::string output;
    std::string password;       // empty = no password
    std::string format;         // empty or "auto" = auto-detect
    std::string tar_cache_path; // optional persistent .tar cache path for compound .tar.*
    std::vector<std::string> entries;
    std::string encoding;       // empty or "auto" = auto-detect
};

struct AddParams {
    std::string archive;
    std::string password; // empty = no password
    std::string format;   // empty or "auto" = auto-detect
    std::vector<std::string> paths;
    std::string target_prefix; // empty = archive root
};

struct DeleteParams {
    std::string archive;
    std::string password; // empty = no password
    std::string format;   // empty or "auto" = auto-detect
    std::vector<std::string> entries;
};

struct RenameParams {
    std::string archive;
    std::string password; // empty = no password
    std::string format;   // empty or "auto" = auto-detect
    std::string old_path;
    std::string new_path;
};

struct TestParams {
    std::string archive;
    std::string password;       // empty = no password
    std::string format;         // empty or "auto" = auto-detect
    std::string tar_cache_path; // optional persistent .tar cache path for compound .tar.*
};

struct MoveParams {
    std::string archive;
    std::string password; // empty = no password
    std::string format;   // empty or "auto" = auto-detect
    std::vector<std::string> entries;
    std::string target_dir; // empty = archive root
};

struct UpdatePasswordParams {
    std::string archive;
    std::string old_password;
    std::string new_password;
    std::string format;            // empty or "auto" = auto-detect
    std::string encryption_method; // "", "aes256", "zipcrypto"
    bool encrypt_headers = true;
};

struct Request {
    std::string id;
    std::string command;
    json params_json;

    // Parse convenience
    std::optional<ListParams> as_list() const;
    std::optional<CompressParams> as_compress() const;
    std::optional<ExtractParams> as_extract() const;
    std::optional<AddParams> as_add() const;
    std::optional<DeleteParams> as_delete() const;
    std::optional<RenameParams> as_rename() const;
    std::optional<TestParams> as_test() const;
    std::optional<MoveParams> as_move() const;
    std::optional<UpdatePasswordParams> as_update_password() const;
};

struct ArchiveItem {
    uint32_t index;
    std::string name;
    std::string path;
    std::string extension;
    bool is_dir;
    uint64_t size;
    uint64_t packed_size;
    uint32_t crc;
    bool encrypted;
    std::optional<int64_t> modified_at;
};

struct ProgressData {
    uint64_t processed_bytes = 0;
    uint64_t total_bytes = 0;
    std::string current_file;
    uint32_t files_delta = 0;
    uint8_t stage = 0;
};

struct Response {
    std::string id;
    std::string type;  // "result", "progress", "file", "error"
    json data;

    void write(std::ostream& os) const;
};

Response make_result(const std::string& id, json data);
Response make_progress(const std::string& id, const ProgressData& pd);
Response make_file(const std::string& id, const std::string& path);
Response make_error(const std::string& id, const std::string& message, const std::string& code = "");

std::optional<Request> parse_request(const std::string& line);

inline void to_json(json& j, const ListParams& p) {
    j = json{{"archive", p.archive}};
    if (!p.password.empty()) j["password"] = p.password;
    if (!p.format.empty()) j["format"] = p.format;
    if (!p.tar_cache_path.empty()) j["tar_cache_path"] = p.tar_cache_path;
    if (!p.encoding.empty()) j["encoding"] = p.encoding;
}
inline void from_json(const json& j, ListParams& p) {
    j.at("archive").get_to(p.archive);
    if (j.contains("password") && !j["password"].is_null()) {
        j.at("password").get_to(p.password);
    }
    if (j.contains("format") && !j["format"].is_null()) {
        j.at("format").get_to(p.format);
    }
    if (j.contains("tar_cache_path") && !j["tar_cache_path"].is_null()) {
        j.at("tar_cache_path").get_to(p.tar_cache_path);
    }
    if (j.contains("encoding") && !j["encoding"].is_null()) {
        j.at("encoding").get_to(p.encoding);
    }
}

inline void to_json(json& j, const CompressParams& p) {
    j = json{
        {"archive", p.archive},
        {"paths", p.paths},
        {"format", p.format},
        {"level", p.level},
        {"preserve_paths", p.preserve_paths},
        {"encrypt_headers", p.encrypt_headers},
        {"follow_symlinks", p.follow_symlinks}
    };
    if (!p.password.empty()) j["password"] = p.password;
    if (!p.exclude.empty()) j["exclude"] = p.exclude;
    if (p.volume_size_bytes > 0) j["volume_size_bytes"] = p.volume_size_bytes;
    if (!p.encryption_method.empty()) j["encryption_method"] = p.encryption_method;
}
inline void from_json(const json& j, CompressParams& p) {
    j.at("archive").get_to(p.archive);
    j.at("paths").get_to(p.paths);
    if (j.contains("format") && !j["format"].is_null()) j.at("format").get_to(p.format);
    if (j.contains("level") && !j["level"].is_null()) j.at("level").get_to(p.level);
    if (j.contains("password") && !j["password"].is_null()) {
        j.at("password").get_to(p.password);
    }
    if (j.contains("preserve_paths") && !j["preserve_paths"].is_null()) {
        j.at("preserve_paths").get_to(p.preserve_paths);
    }
    if (j.contains("exclude") && !j["exclude"].is_null()) {
        j.at("exclude").get_to(p.exclude);
    }
    if (j.contains("volume_size_bytes") && !j["volume_size_bytes"].is_null()) {
        j.at("volume_size_bytes").get_to(p.volume_size_bytes);
    }
    if (j.contains("encryption_method") && !j["encryption_method"].is_null()) {
        j.at("encryption_method").get_to(p.encryption_method);
    }
    if (j.contains("encrypt_headers") && !j["encrypt_headers"].is_null()) {
        j.at("encrypt_headers").get_to(p.encrypt_headers);
    }
    if (j.contains("follow_symlinks") && !j["follow_symlinks"].is_null()) {
        j.at("follow_symlinks").get_to(p.follow_symlinks);
    }
}

inline void to_json(json& j, const ExtractParams& p) {
    j = json{{"archive", p.archive}, {"output", p.output}};
    if (!p.password.empty()) j["password"] = p.password;
    if (!p.format.empty()) j["format"] = p.format;
    if (!p.tar_cache_path.empty()) j["tar_cache_path"] = p.tar_cache_path;
    if (!p.entries.empty()) j["entries"] = p.entries;
    if (!p.encoding.empty()) j["encoding"] = p.encoding;
}
inline void from_json(const json& j, ExtractParams& p) {
    j.at("archive").get_to(p.archive);
    j.at("output").get_to(p.output);
    if (j.contains("password") && !j["password"].is_null()) {
        j.at("password").get_to(p.password);
    }
    if (j.contains("format") && !j["format"].is_null()) {
        j.at("format").get_to(p.format);
    }
    if (j.contains("tar_cache_path") && !j["tar_cache_path"].is_null()) {
        j.at("tar_cache_path").get_to(p.tar_cache_path);
    }
    if (j.contains("entries") && !j["entries"].is_null()) {
        j.at("entries").get_to(p.entries);
    }
    if (j.contains("encoding") && !j["encoding"].is_null()) {
        j.at("encoding").get_to(p.encoding);
    }
}

inline void to_json(json& j, const AddParams& p) {
    j = json{{"archive", p.archive}, {"paths", p.paths}};
    if (!p.password.empty()) j["password"] = p.password;
    if (!p.format.empty()) j["format"] = p.format;
    if (!p.target_prefix.empty()) j["target_prefix"] = p.target_prefix;
}
inline void from_json(const json& j, AddParams& p) {
    j.at("archive").get_to(p.archive);
    j.at("paths").get_to(p.paths);
    if (j.contains("password") && !j["password"].is_null()) {
        j.at("password").get_to(p.password);
    }
    if (j.contains("format") && !j["format"].is_null()) {
        j.at("format").get_to(p.format);
    }
    if (j.contains("target_prefix") && !j["target_prefix"].is_null()) {
        j.at("target_prefix").get_to(p.target_prefix);
    }
}

inline void to_json(json& j, const DeleteParams& p) {
    j = json{{"archive", p.archive}, {"entries", p.entries}};
    if (!p.password.empty()) j["password"] = p.password;
    if (!p.format.empty()) j["format"] = p.format;
}
inline void from_json(const json& j, DeleteParams& p) {
    j.at("archive").get_to(p.archive);
    j.at("entries").get_to(p.entries);
    if (j.contains("password") && !j["password"].is_null()) {
        j.at("password").get_to(p.password);
    }
    if (j.contains("format") && !j["format"].is_null()) {
        j.at("format").get_to(p.format);
    }
}

inline void to_json(json& j, const RenameParams& p) {
    j = json{{"archive", p.archive}, {"old_path", p.old_path}, {"new_path", p.new_path}};
    if (!p.password.empty()) j["password"] = p.password;
    if (!p.format.empty()) j["format"] = p.format;
}
inline void from_json(const json& j, RenameParams& p) {
    j.at("archive").get_to(p.archive);
    j.at("old_path").get_to(p.old_path);
    j.at("new_path").get_to(p.new_path);
    if (j.contains("password") && !j["password"].is_null()) {
        j.at("password").get_to(p.password);
    }
    if (j.contains("format") && !j["format"].is_null()) {
        j.at("format").get_to(p.format);
    }
}

inline void to_json(json& j, const TestParams& p) {
    j = json{{"archive", p.archive}};
    if (!p.password.empty()) j["password"] = p.password;
    if (!p.format.empty()) j["format"] = p.format;
    if (!p.tar_cache_path.empty()) j["tar_cache_path"] = p.tar_cache_path;
}
inline void from_json(const json& j, TestParams& p) {
    j.at("archive").get_to(p.archive);
    if (j.contains("password") && !j["password"].is_null()) {
        j.at("password").get_to(p.password);
    }
    if (j.contains("format") && !j["format"].is_null()) {
        j.at("format").get_to(p.format);
    }
    if (j.contains("tar_cache_path") && !j["tar_cache_path"].is_null()) {
        j.at("tar_cache_path").get_to(p.tar_cache_path);
    }
}

inline void to_json(json& j, const MoveParams& p) {
    j = json{{"archive", p.archive}, {"entries", p.entries}};
    if (!p.password.empty()) j["password"] = p.password;
    if (!p.format.empty()) j["format"] = p.format;
    if (!p.target_dir.empty()) j["target_dir"] = p.target_dir;
}
inline void from_json(const json& j, MoveParams& p) {
    j.at("archive").get_to(p.archive);
    j.at("entries").get_to(p.entries);
    if (j.contains("password") && !j["password"].is_null()) {
        j.at("password").get_to(p.password);
    }
    if (j.contains("format") && !j["format"].is_null()) {
        j.at("format").get_to(p.format);
    }
    if (j.contains("target_dir") && !j["target_dir"].is_null()) {
        j.at("target_dir").get_to(p.target_dir);
    }
}

inline void to_json(json& j, const UpdatePasswordParams& p) {
    j = json{
        {"archive", p.archive},
        {"old_password", p.old_password},
        {"new_password", p.new_password},
        {"encrypt_headers", p.encrypt_headers}
    };
    if (!p.format.empty()) j["format"] = p.format;
    if (!p.encryption_method.empty()) j["encryption_method"] = p.encryption_method;
}
inline void from_json(const json& j, UpdatePasswordParams& p) {
    j.at("archive").get_to(p.archive);
    if (j.contains("old_password") && !j["old_password"].is_null()) {
        j.at("old_password").get_to(p.old_password);
    }
    if (j.contains("new_password") && !j["new_password"].is_null()) {
        j.at("new_password").get_to(p.new_password);
    }
    if (j.contains("format") && !j["format"].is_null()) {
        j.at("format").get_to(p.format);
    }
    if (j.contains("encryption_method") && !j["encryption_method"].is_null()) {
        j.at("encryption_method").get_to(p.encryption_method);
    }
    if (j.contains("encrypt_headers") && !j["encrypt_headers"].is_null()) {
        j.at("encrypt_headers").get_to(p.encrypt_headers);
    }
}

inline void to_json(json& j, const ArchiveItem& item) {
    j = json{
        {"index", item.index},
        {"name", item.name},
        {"path", item.path},
        {"extension", item.extension},
        {"is_dir", item.is_dir},
        {"size", item.size},
        {"packed_size", item.packed_size},
        {"crc", item.crc},
        {"encrypted", item.encrypted}
    };
    if (item.modified_at.has_value()) {
        j["modified_at"] = *item.modified_at;
    }
}
inline void from_json(const json& j, ArchiveItem& item) {
    j.at("index").get_to(item.index);
    j.at("name").get_to(item.name);
    j.at("path").get_to(item.path);
    j.at("extension").get_to(item.extension);
    j.at("is_dir").get_to(item.is_dir);
    j.at("size").get_to(item.size);
    j.at("packed_size").get_to(item.packed_size);
    j.at("crc").get_to(item.crc);
    j.at("encrypted").get_to(item.encrypted);
    if (j.contains("modified_at") && !j["modified_at"].is_null()) {
        item.modified_at = j.at("modified_at").get<int64_t>();
    } else {
        item.modified_at.reset();
    }
}

inline void to_json(json& j, const ProgressData& pd) {
    j = json{
        {"processed_bytes", pd.processed_bytes},
        {"total_bytes", pd.total_bytes},
        {"current_file", pd.current_file},
        {"files_delta", pd.files_delta}
    };
    if (pd.stage != 0) {
        j["stage"] = pd.stage;
    }
}
inline void from_json(const json& j, ProgressData& pd) {
    j.at("processed_bytes").get_to(pd.processed_bytes);
    j.at("total_bytes").get_to(pd.total_bytes);
    j.at("current_file").get_to(pd.current_file);
    if (j.contains("files_delta") && !j["files_delta"].is_null()) {
        j.at("files_delta").get_to(pd.files_delta);
    } else {
        pd.files_delta = 0;
    }
    if (j.contains("stage") && !j["stage"].is_null()) {
        j.at("stage").get_to(pd.stage);
    } else {
        pd.stage = 0;
    }
}

} // namespace bento7z
