#pragma once

#include <string>
#include <string_view>

namespace bit7z {
class BitArchiveReader;
}

namespace bento7z {

/// Detects non-UTF-8 ZIP filenames decoded as Latin-1 mojibake by 7-Zip and resolves them
/// to their original encoding (UTF-8 without bit-11 flag, GB18030/GBK, Shift-JIS, Big5, or EUC-KR).
class ZipEncodingResolver {
public:
    ZipEncodingResolver() = default;

    /// Inspects entries in `reader`. When `reader` is a ZIP containing Latin-1 mojibake paths,
    /// detects the best-matching charset across all entries.
    explicit ZipEncodingResolver(const bit7z::BitArchiveReader& reader);

    bool has_remapping() const noexcept { return !charset_.empty(); }
    const std::string& charset() const noexcept { return charset_; }

    /// Converts a raw archive path or name from 7-Zip's UTF-8 output to its repaired UTF-8 string.
    std::string decode(std::string_view utf8_str) const;

private:
    std::string charset_;
};

/// Returns true when `utf8_str` contains non-ASCII characters and every non-ASCII code point is U+0080..U+00FF.
bool looks_like_latin1_mojibake(std::string_view utf8_str);

} // namespace bento7z
