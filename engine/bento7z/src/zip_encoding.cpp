#include "zip_encoding.hpp"

#include <bit7z/bitarchivereader.hpp>
#include <bit7z/bitformat.hpp>

#include <iconv.h>

#include <cerrno>
#include <cstdint>
#include <limits>
#include <optional>
#include <vector>

namespace bento7z {

namespace {

std::optional<std::string> extract_latin1_raw_bytes(std::string_view utf8_str, bool& saw_non_ascii) {
    saw_non_ascii = false;
    std::string raw;
    raw.reserve(utf8_str.size());

    size_t i = 0;
    while (i < utf8_str.size()) {
        const uint8_t b0 = static_cast<uint8_t>(utf8_str[i]);
        if (b0 < 0x80u) {
            raw.push_back(static_cast<char>(b0));
            ++i;
        } else if ((b0 & 0xE0u) == 0xC0u && i + 1 < utf8_str.size()) {
            const uint8_t b1 = static_cast<uint8_t>(utf8_str[i + 1]);
            if ((b1 & 0xC0u) != 0x80u) {
                return std::nullopt;
            }
            const uint32_t cp = (static_cast<uint32_t>(b0 & 0x1Fu) << 6) |
                                 static_cast<uint32_t>(b1 & 0x3Fu);
            if (cp > 0xFFu) {
                return std::nullopt;
            }
            saw_non_ascii = true;
            raw.push_back(static_cast<char>(cp));
            i += 2;
        } else {
            return std::nullopt;
        }
    }
    return raw;
}

std::optional<std::string> iconv_convert(const char* from_charset, std::string_view input) {
    iconv_t cd = ::iconv_open("UTF-8", from_charset);
    if (cd == reinterpret_cast<iconv_t>(-1)) {
        return std::nullopt;
    }

    std::string input_copy(input);
    std::string output;
    output.resize(std::max<size_t>(input.size() * 4 + 16, 64));

    char* in_ptr = input_copy.data();
    size_t in_left = input_copy.size();
    size_t out_offset = 0;

    while (in_left > 0) {
        if (out_offset + 16 >= output.size()) {
            output.resize(output.size() * 2);
        }
        char* out_ptr = output.data() + out_offset;
        size_t out_left = output.size() - out_offset;
        const size_t rc = ::iconv(cd, &in_ptr, &in_left, &out_ptr, &out_left);
        out_offset = output.size() - out_left;
        if (rc == static_cast<size_t>(-1)) {
            if (errno == E2BIG) {
                continue;
            }
            ::iconv_close(cd);
            return std::nullopt;
        }
    }

    // Flush shift state
    while (true) {
        if (out_offset + 16 >= output.size()) {
            output.resize(output.size() * 2);
        }
        char* out_ptr = output.data() + out_offset;
        size_t out_left = output.size() - out_offset;
        const size_t rc = ::iconv(cd, nullptr, nullptr, &out_ptr, &out_left);
        out_offset = output.size() - out_left;
        if (rc == static_cast<size_t>(-1)) {
            if (errno == E2BIG) {
                continue;
            }
            ::iconv_close(cd);
            return std::nullopt;
        }
        break;
    }

    ::iconv_close(cd);
    output.resize(out_offset);
    return output;
}

int64_t score_utf8_text(std::string_view utf8_str, std::string_view candidate) {
    const bool is_utf8 = (candidate == "UTF-8");
    const bool is_sjis = (candidate == "SHIFT_JIS");
    const bool is_euckr = (candidate == "EUC-KR");

    int64_t cjk_common = 0;
    int64_t kana_count = 0;
    int64_t hangul_count = 0;
    int64_t cjk_punct_fullwidth = 0;
    int64_t halfwidth_kana = 0;
    int64_t jamo_count = 0;
    int64_t odd_symbol_count = 0;
    int64_t bad_char_count = 0;
    bool has_multibyte = false;

    size_t i = 0;
    while (i < utf8_str.size()) {
        const uint8_t b0 = static_cast<uint8_t>(utf8_str[i]);
        uint32_t cp = 0;
        if (b0 < 0x80u) {
            cp = b0;
            ++i;
        } else if ((b0 & 0xE0u) == 0xC0u && i + 1 < utf8_str.size()) {
            cp = (static_cast<uint32_t>(b0 & 0x1Fu) << 6) |
                 static_cast<uint32_t>(utf8_str[i + 1] & 0x3Fu);
            has_multibyte = true;
            i += 2;
        } else if ((b0 & 0xF0u) == 0xE0u && i + 2 < utf8_str.size()) {
            cp = (static_cast<uint32_t>(b0 & 0x0Fu) << 12) |
                 (static_cast<uint32_t>(utf8_str[i + 1] & 0x3Fu) << 6) |
                 static_cast<uint32_t>(utf8_str[i + 2] & 0x3Fu);
            has_multibyte = true;
            i += 3;
        } else if ((b0 & 0xF8u) == 0xF0u && i + 3 < utf8_str.size()) {
            cp = (static_cast<uint32_t>(b0 & 0x07u) << 18) |
                 (static_cast<uint32_t>(utf8_str[i + 1] & 0x3Fu) << 12) |
                 (static_cast<uint32_t>(utf8_str[i + 2] & 0x3Fu) << 6) |
                 static_cast<uint32_t>(utf8_str[i + 3] & 0x3Fu);
            has_multibyte = true;
            i += 4;
        } else {
            return std::numeric_limits<int64_t>::min();
        }

        if (cp < 0x80u) {
            continue;
        }
        if (cp >= 0x4E00u && cp <= 0x9FFFu) {
            ++cjk_common;
        } else if ((cp >= 0x3040u && cp <= 0x30FFu) || (cp >= 0x31F0u && cp <= 0x31FFu)) {
            ++kana_count;
        } else if (cp >= 0xAC00u && cp <= 0xD7AFu) {
            ++hangul_count;
        } else if ((cp >= 0x3000u && cp <= 0x303Fu) || (cp >= 0xFF00u && cp <= 0xFF5Eu) ||
                   (cp >= 0xFFE0u && cp <= 0xFFEFu)) {
            ++cjk_punct_fullwidth;
        } else if (cp >= 0xFF61u && cp <= 0xFF9Fu) {
            ++halfwidth_kana;
        } else if ((cp >= 0x1100u && cp <= 0x11FFu) || (cp >= 0x3130u && cp <= 0x318Fu)) {
            ++jamo_count;
        } else if (cp == 0xFFFDu || (cp >= 0xE000u && cp <= 0xF8FFu) || (cp >= 0x0080u && cp <= 0x009Fu)) {
            ++bad_char_count;
        } else if ((cp >= 0x0370u && cp <= 0x04FFu) || (cp >= 0x00A0u && cp <= 0x024Fu)) {
            ++odd_symbol_count;
        }
    }

    int64_t score = 0;
    if (is_euckr) {
        score += hangul_count * 12;
        if (hangul_count > 0 && cjk_common > 0) {
            // Genuine Korean filenames rarely mix Hangul with random Hanja.
            score -= cjk_common * 25;
        } else {
            score += cjk_common * 4;
        }
    } else if (is_sjis) {
        score += cjk_common * 10 + kana_count * 12 + hangul_count * 10;
    } else if (is_utf8) {
        score += cjk_common * 10 + kana_count * 12 + hangul_count * 12;
    } else {
        // GB18030 / BIG5: Hiragana/Katakana in GB2312/Big5 byte space is typically Big5/SJIS collision noise.
        score += cjk_common * 10;
        score -= kana_count * 25;
        score += hangul_count * 10;
    }

    score += cjk_punct_fullwidth * 4;
    score -= halfwidth_kana * 25;
    score -= jamo_count * 25;
    score -= odd_symbol_count * 25;
    score -= bad_char_count * 30;

    if (is_utf8 && has_multibyte && bad_char_count == 0) {
        score += 1000;
    }
    return score;
}

} // namespace

bool looks_like_latin1_mojibake(std::string_view utf8_str) {
    bool saw_non_ascii = false;
    return extract_latin1_raw_bytes(utf8_str, saw_non_ascii).has_value() && saw_non_ascii;
}

ZipEncodingResolver::ZipEncodingResolver(const bit7z::BitArchiveReader& reader) {
    if (reader.detectedFormat() != bit7z::BitFormat::Zip) {
        return;
    }

    std::vector<std::string> raw_samples;
    for (const auto& item : reader) {
        const std::string p = item.path();
        bool saw_non_ascii = false;
        auto raw = extract_latin1_raw_bytes(p, saw_non_ascii);
        if (saw_non_ascii && raw.has_value()) {
            raw_samples.push_back(std::move(*raw));
            if (raw_samples.size() >= 64) {
                break;
            }
        }
    }

    if (raw_samples.empty()) {
        return;
    }

    static constexpr const char* kCandidates[] = {
        "UTF-8",
        "GB18030",
        "SHIFT_JIS",
        "BIG5",
        "EUC-KR"
    };

    std::string best_charset;
    int64_t best_score = 0;

    for (const char* candidate : kCandidates) {
        bool all_valid = true;
        int64_t total_score = 0;

        for (const auto& sample : raw_samples) {
            auto decoded = iconv_convert(candidate, sample);
            if (!decoded.has_value()) {
                all_valid = false;
                break;
            }
            const int64_t s = score_utf8_text(*decoded, candidate);
            if (s == std::numeric_limits<int64_t>::min()) {
                all_valid = false;
                break;
            }
            total_score += s;
        }

        if (all_valid && total_score > best_score) {
            best_score = total_score;
            best_charset = candidate;
        }
    }

    charset_ = std::move(best_charset);
}

std::string ZipEncodingResolver::decode(std::string_view utf8_str) const {
    if (charset_.empty()) {
        return std::string(utf8_str);
    }
    bool saw_non_ascii = false;
    auto raw = extract_latin1_raw_bytes(utf8_str, saw_non_ascii);
    if (!saw_non_ascii || !raw.has_value()) {
        return std::string(utf8_str);
    }
    auto converted = iconv_convert(charset_.c_str(), *raw);
    return converted.value_or(std::string(utf8_str));
}

} // namespace bento7z
