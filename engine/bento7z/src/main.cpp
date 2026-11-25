#include "bento7z/commands.hpp"
#include "binary_server.hpp"

#include <iostream>
#include <fstream>
#include <string>
#include <string_view>
#include <cstdlib>
#include <filesystem>

namespace fs = std::filesystem;

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

static fs::path executable_dir() {
#ifdef __APPLE__
    char buf[PATH_MAX];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) == 0) {
        return fs::canonical(fs::path(buf)).parent_path();
    }
#elif defined(__linux__)
    return fs::canonical(fs::path("/proc/self/exe")).parent_path();
#elif defined(_WIN32)
    wchar_t buf[MAX_PATH];
    if (GetModuleFileNameW(nullptr, buf, MAX_PATH) > 0) {
        return fs::canonical(buf).parent_path();
    }
#endif
    return fs::current_path();
}

static std::string find_7z_library() {
    const char* env = std::getenv("BENTO7Z_LIBRARY");
    if (env && env[0] != '\0') return env;

    // 1) Bundled 7z.so next to the executable (built from 7-Zip source)
    fs::path bundled = executable_dir() / "7z.so";
    if (fs::exists(fs::path(bundled))) return bundled.string();
#ifdef _WIN32
    fs::path bundled_dll = executable_dir() / "7z.dll";
    if (fs::exists(fs::path(bundled_dll))) return bundled_dll.string();
#endif

    static const char* fallbacks[] = {
#ifdef __APPLE__
        "/opt/homebrew/lib/p7zip/7z.so",
        "/usr/local/lib/p7zip/7z.so",
#elif defined(__linux__)
        "/usr/lib/7z.so",
        "/usr/lib/p7zip/7z.so",
#elif defined(_WIN32)
        "7z.dll",
        "7za.dll",
#endif
        nullptr
    };
    for (int i = 0; fallbacks[i] != nullptr; ++i) {
        if (fs::exists(fs::path(fallbacks[i]))) return fallbacks[i];
    }

#ifdef _WIN32
    return "7z.dll";
#else
    return "7z.so";
#endif
}

int main(int argc, char* argv[]) {
    std::string lib_path = find_7z_library();
    const char* debug_env = std::getenv("BENTO7Z_DEBUG");
    if (debug_env && debug_env[0] != '\0' && std::string(debug_env) != "0") {
        std::cerr << "bento7z: using 7z library: " << lib_path << '\n';
    }

    if (argc == 3 && std::string_view(argv[1]) == "--server") {
        return bento7z::run_binary_server(lib_path, argv[2]);
    }

    std::ios::sync_with_stdio(false);
    std::cin.tie(nullptr);

    try {
        bento7z::CommandHandler handler(lib_path);

        std::string line;
        while (std::getline(std::cin, line)) {
            if (!line.empty() && line.back() == '\r') {
                line.pop_back();
            }
            if (line.empty()) continue;

            auto req = bento7z::parse_request(line);
            if (!req) {
                continue;
            }

            handler.execute(*req);
        }
    } catch (const std::exception& ex) {
        std::cerr << "bento7z: fatal initialization error: " << ex.what() << '\n';
        return 1;
    }

    return 0;
}
