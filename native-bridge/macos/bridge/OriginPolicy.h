#pragma once

#include <algorithm>
#include <cctype>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace BridgeOriginPolicy {

struct ParsedOrigin {
    std::string normalized;
    std::string host;
};

inline std::optional<ParsedOrigin> Parse(std::string_view value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string_view::npos) return std::nullopt;
    const auto last = value.find_last_not_of(" \t\r\n");
    value = value.substr(first, last - first + 1);

    const auto schemeEnd = value.find("://");
    if (schemeEnd == std::string_view::npos) return std::nullopt;
    std::string scheme(value.substr(0, schemeEnd));
    std::transform(scheme.begin(), scheme.end(), scheme.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    if (scheme != "http" && scheme != "https") return std::nullopt;

    std::string_view authority = value.substr(schemeEnd + 3);
    const auto suffix = authority.find_first_of("/?#");
    if (suffix != std::string_view::npos) {
        if (authority[suffix] != '/' || suffix + 1 != authority.size()) return std::nullopt;
        authority = authority.substr(0, suffix);
    }
    if (authority.empty() || authority.find('@') != std::string_view::npos) return std::nullopt;

    std::string host;
    std::string_view portText;
    if (authority.front() == '[') {
        const auto closing = authority.find(']');
        if (closing == std::string_view::npos) return std::nullopt;
        host = std::string(authority.substr(1, closing - 1));
        const auto remainder = authority.substr(closing + 1);
        if (!remainder.empty()) {
            if (remainder.front() != ':') return std::nullopt;
            portText = remainder.substr(1);
        }
    } else {
        const auto colon = authority.rfind(':');
        if (colon != std::string_view::npos) {
            if (authority.find(':') != colon) return std::nullopt;
            host = std::string(authority.substr(0, colon));
            portText = authority.substr(colon + 1);
        } else {
            host = std::string(authority);
        }
    }
    if (host.empty()) return std::nullopt;
    std::transform(host.begin(), host.end(), host.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });

    std::optional<unsigned int> port;
    if (!portText.empty()) {
        unsigned int parsed = 0;
        for (const unsigned char character : portText) {
            if (!std::isdigit(character)) return std::nullopt;
            const auto digit = static_cast<unsigned int>(character - '0');
            if (parsed > (65535 - digit) / 10) return std::nullopt;
            parsed = parsed * 10 + digit;
        }
        if (parsed == 0) return std::nullopt;
        port = parsed;
    } else if (authority.back() == ':') {
        return std::nullopt;
    }

    const bool defaultPort = port.has_value() &&
        ((*port == 80 && scheme == "http") || (*port == 443 && scheme == "https"));
    std::string normalized = scheme + "://";
    normalized += host.find(':') == std::string::npos ? host : "[" + host + "]";
    if (port.has_value() && !defaultPort) normalized += ":" + std::to_string(*port);
    return ParsedOrigin{std::move(normalized), std::move(host)};
}

inline bool IsAllowed(std::string_view origin, const std::vector<std::string>& allowedOrigins) {
    if (origin.empty()) return true;
    const auto parsed = Parse(origin);
    if (!parsed.has_value()) return false;
    if (parsed->host == "localhost" || parsed->host == "127.0.0.1" || parsed->host == "::1") {
        return true;
    }
    return std::find(allowedOrigins.begin(), allowedOrigins.end(), parsed->normalized) !=
           allowedOrigins.end();
}

}  // namespace BridgeOriginPolicy
