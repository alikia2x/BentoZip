#include "bento7z/protocol.hpp"
#include <stdexcept>
#include <iostream>

namespace bento7z {

void Response::write(std::ostream& os) const {
    json j;
    j["id"] = id;
    j["type"] = type;
    j["data"] = data;
    os << j.dump() << '\n' << std::flush;
}

Response make_result(const std::string& id, json data) {
    Response resp;
    resp.id = id;
    resp.type = "result";
    resp.data = std::move(data);
    return resp;
}

Response make_progress(const std::string& id, const ProgressData& pd) {
    Response resp;
    resp.id = id;
    resp.type = "progress";
    resp.data = pd;
    return resp;
}

Response make_file(const std::string& id, const std::string& path) {
    Response resp;
    resp.id = id;
    resp.type = "file";
    resp.data["path"] = path;
    return resp;
}

Response make_error(const std::string& id, const std::string& message, const std::string& code) {
    Response resp;
    resp.id = id;
    resp.type = "error";
    resp.data["message"] = message;
    if (!code.empty()) {
        resp.data["code"] = code;
    }
    return resp;
}

std::optional<Request> parse_request(const std::string& line) {
    if (line.empty()) return std::nullopt;
    std::string req_id;
    try {
        json j = json::parse(line);
        if (j.is_object() && j.contains("id") && j["id"].is_string()) {
            req_id = j["id"].get<std::string>();
        }
        Request req;
        req.id = j.at("id").get<std::string>();
        req.command = j.at("command").get<std::string>();
        if (j.contains("params")) {
            req.params_json = j["params"];
        }
        return req;
    } catch (const json::exception& e) {
        make_error(req_id, "Failed to parse request: " + std::string(e.what()), "INVALID_PARAMS")
            .write(std::cout);
        return std::nullopt;
    }
}

std::optional<ListParams> Request::as_list() const {
    try {
        return params_json.get<ListParams>();
    } catch (...) {
        return std::nullopt;
    }
}

std::optional<CompressParams> Request::as_compress() const {
    try {
        return params_json.get<CompressParams>();
    } catch (...) {
        return std::nullopt;
    }
}

std::optional<ExtractParams> Request::as_extract() const {
    try {
        return params_json.get<ExtractParams>();
    } catch (...) {
        return std::nullopt;
    }
}

std::optional<AddParams> Request::as_add() const {
    try {
        return params_json.get<AddParams>();
    } catch (...) {
        return std::nullopt;
    }
}

std::optional<DeleteParams> Request::as_delete() const {
    try {
        return params_json.get<DeleteParams>();
    } catch (...) {
        return std::nullopt;
    }
}

} // namespace bento7z
