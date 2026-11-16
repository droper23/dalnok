// SPDX-License-Identifier: GPL-3.0-or-later
#include "json.hpp"

#include <charconv>
#include <cmath>
#include <cstdlib>
#include <locale.h>
#if defined(__APPLE__)
#include <xlocale.h>
#endif

namespace dalnok::json {

const Value *Value::get(std::string_view key) const {
    if (type != Type::Object) return nullptr;
    for (const auto &[k, v] : object)
        if (k == key) return &v;
    return nullptr;
}

Value &Value::set(std::string key, Value v) {
    type = Type::Object;
    for (auto &[k, existing] : object)
        if (k == key) return existing = std::move(v);
    object.emplace_back(std::move(key), std::move(v));
    return object.back().second;
}

double Value::getNumber(std::string_view key, double fallback) const {
    const Value *v = get(key);
    return v && v->isNumber() ? v->number : fallback;
}
std::string Value::getString(std::string_view key, std::string fallback) const {
    const Value *v = get(key);
    return v && v->isString() ? v->string : fallback;
}
bool Value::getBool(std::string_view key, bool fallback) const {
    const Value *v = get(key);
    return v && v->isBool() ? v->boolean : fallback;
}

// ---- Parser -------------------------------------------------------------

namespace {

constexpr int kMaxDepth = 256;

double parseDouble(const std::string &s) {
    // Locale-independent: always '.' as the decimal separator.
    static locale_t c = newlocale(LC_ALL_MASK, "C", nullptr);
    return strtod_l(s.c_str(), nullptr, c);
}

class Parser {
public:
    Parser(std::string_view t, std::string &err) : t_(t), err_(err) {}

    bool parseDocument(Value &out) {
        ws();
        if (!value(out, 0)) return false;
        ws();
        if (i_ != t_.size()) return fail("trailing characters");
        return true;
    }

private:
    bool fail(const char *msg) {
        err_ = std::string(msg) + " at offset " + std::to_string(i_);
        return false;
    }
    void ws() {
        while (i_ < t_.size() && (t_[i_] == ' ' || t_[i_] == '\t' || t_[i_] == '\n' || t_[i_] == '\r')) ++i_;
    }
    bool literal(std::string_view word) {
        if (t_.substr(i_, word.size()) != word) return fail("invalid literal");
        i_ += word.size();
        return true;
    }

    bool value(Value &out, int depth) {
        if (depth > kMaxDepth) return fail("nesting too deep");
        if (i_ >= t_.size()) return fail("unexpected end");
        switch (t_[i_]) {
        case '{': return objectValue(out, depth);
        case '[': return arrayValue(out, depth);
        case '"': out = Value(); out.type = Value::Type::String; return stringValue(out.string);
        case 't': out = Value(true); return literal("true");
        case 'f': out = Value(false); return literal("false");
        case 'n': out = Value(); return literal("null");
        default: return numberValue(out);
        }
    }

    bool objectValue(Value &out, int depth) {
        out = Value::makeObject();
        ++i_;
        ws();
        if (i_ < t_.size() && t_[i_] == '}') { ++i_; return true; }
        for (;;) {
            ws();
            if (i_ >= t_.size() || t_[i_] != '"') return fail("expected key");
            std::string key;
            if (!stringValue(key)) return false;
            ws();
            if (i_ >= t_.size() || t_[i_] != ':') return fail("expected ':'");
            ++i_;
            ws();
            Value v;
            if (!value(v, depth + 1)) return false;
            out.set(std::move(key), std::move(v));
            ws();
            if (i_ < t_.size() && t_[i_] == ',') { ++i_; continue; }
            if (i_ < t_.size() && t_[i_] == '}') { ++i_; return true; }
            return fail("expected ',' or '}'");
        }
    }

    bool arrayValue(Value &out, int depth) {
        out = Value::makeArray();
        ++i_;
        ws();
        if (i_ < t_.size() && t_[i_] == ']') { ++i_; return true; }
        for (;;) {
            ws();
            Value v;
            if (!value(v, depth + 1)) return false;
            out.push(std::move(v));
            ws();
            if (i_ < t_.size() && t_[i_] == ',') { ++i_; continue; }
            if (i_ < t_.size() && t_[i_] == ']') { ++i_; return true; }
            return fail("expected ',' or ']'");
        }
    }

    static void appendUtf8(std::string &s, uint32_t cp) {
        if (cp < 0x80) s += static_cast<char>(cp);
        else if (cp < 0x800) { s += static_cast<char>(0xC0 | (cp >> 6)); s += static_cast<char>(0x80 | (cp & 0x3F)); }
        else if (cp < 0x10000) {
            s += static_cast<char>(0xE0 | (cp >> 12));
            s += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            s += static_cast<char>(0x80 | (cp & 0x3F));
        } else {
            s += static_cast<char>(0xF0 | (cp >> 18));
            s += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
            s += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            s += static_cast<char>(0x80 | (cp & 0x3F));
        }
    }

    bool hex4(uint32_t &out) {
        if (i_ + 4 > t_.size()) return fail("bad \\u escape");
        out = 0;
        for (int k = 0; k < 4; ++k) {
            const char c = t_[i_++];
            out <<= 4;
            if (c >= '0' && c <= '9') out |= static_cast<uint32_t>(c - '0');
            else if (c >= 'a' && c <= 'f') out |= static_cast<uint32_t>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') out |= static_cast<uint32_t>(c - 'A' + 10);
            else return fail("bad \\u escape");
        }
        return true;
    }

    bool stringValue(std::string &s) {
        ++i_; // opening quote
        while (i_ < t_.size()) {
            const char c = t_[i_++];
            if (c == '"') return true;
            if (static_cast<unsigned char>(c) < 0x20) return fail("control character in string");
            if (c != '\\') { s += c; continue; }
            if (i_ >= t_.size()) break;
            switch (t_[i_++]) {
            case '"': s += '"'; break;
            case '\\': s += '\\'; break;
            case '/': s += '/'; break;
            case 'b': s += '\b'; break;
            case 'f': s += '\f'; break;
            case 'n': s += '\n'; break;
            case 'r': s += '\r'; break;
            case 't': s += '\t'; break;
            case 'u': {
                uint32_t cp;
                if (!hex4(cp)) return false;
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    uint32_t lo;
                    if (t_.substr(i_, 2) != "\\u") return fail("unpaired surrogate");
                    i_ += 2;
                    if (!hex4(lo)) return false;
                    if (lo < 0xDC00 || lo > 0xDFFF) return fail("unpaired surrogate");
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    return fail("unpaired surrogate");
                }
                appendUtf8(s, cp);
                break;
            }
            default: return fail("bad escape");
            }
        }
        return fail("unterminated string");
    }

    bool numberValue(Value &out) {
        const size_t start = i_;
        auto digits = [&] {
            const size_t b = i_;
            while (i_ < t_.size() && t_[i_] >= '0' && t_[i_] <= '9') ++i_;
            return i_ > b;
        };
        if (i_ < t_.size() && t_[i_] == '-') ++i_;
        if (i_ < t_.size() && t_[i_] == '0') ++i_;
        else if (!digits()) return fail("invalid number");
        if (i_ < t_.size() && t_[i_] == '.') { ++i_; if (!digits()) return fail("invalid number"); }
        if (i_ < t_.size() && (t_[i_] == 'e' || t_[i_] == 'E')) {
            ++i_;
            if (i_ < t_.size() && (t_[i_] == '+' || t_[i_] == '-')) ++i_;
            if (!digits()) return fail("invalid number");
        }
        out = Value(parseDouble(std::string(t_.substr(start, i_ - start))));
        if (!std::isfinite(out.number)) return fail("number out of range");
        return true;
    }

    std::string_view t_;
    std::string &err_;
    size_t i_ = 0;
};

// ---- Writer -------------------------------------------------------------

void writeString(std::string &o, const std::string &s) {
    o += '"';
    for (const char ch : s) {
        const auto c = static_cast<unsigned char>(ch);
        switch (c) {
        case '"': o += "\\\""; break;
        case '\\': o += "\\\\"; break;
        case '\n': o += "\\n"; break;
        case '\r': o += "\\r"; break;
        case '\t': o += "\\t"; break;
        default:
            if (c < 0x20) {
                static const char *hex = "0123456789abcdef";
                o += "\\u00";
                o += hex[c >> 4];
                o += hex[c & 0xF];
            } else {
                o += ch;
            }
        }
    }
    o += '"';
}

void writeNumber(std::string &o, double n) {
    if (!std::isfinite(n)) { o += "null"; return; }
    char buf[32];
    if (n == std::floor(n) && std::fabs(n) < 9.0e15) {
        auto r = std::to_chars(buf, buf + sizeof buf, static_cast<int64_t>(n));
        o.append(buf, r.ptr);
    } else {
        auto r = std::to_chars(buf, buf + sizeof buf, n); // shortest round-trip, locale-independent
        o.append(buf, r.ptr);
    }
}

void write(std::string &o, const Value &v, bool pretty, int indent) {
    auto newline = [&](int level) {
        if (!pretty) return;
        o += '\n';
        o.append(static_cast<size_t>(level) * 2, ' ');
    };
    switch (v.type) {
    case Value::Type::Null: o += "null"; break;
    case Value::Type::Bool: o += v.boolean ? "true" : "false"; break;
    case Value::Type::Number: writeNumber(o, v.number); break;
    case Value::Type::String: writeString(o, v.string); break;
    case Value::Type::Array:
        o += '[';
        for (size_t k = 0; k < v.array.size(); ++k) {
            if (k) o += ',';
            newline(indent + 1);
            write(o, v.array[k], pretty, indent + 1);
        }
        if (!v.array.empty()) newline(indent);
        o += ']';
        break;
    case Value::Type::Object:
        o += '{';
        for (size_t k = 0; k < v.object.size(); ++k) {
            if (k) o += ',';
            newline(indent + 1);
            writeString(o, v.object[k].first);
            o += pretty ? ": " : ":";
            write(o, v.object[k].second, pretty, indent + 1);
        }
        if (!v.object.empty()) newline(indent);
        o += '}';
        break;
    }
}

} // namespace

bool parse(std::string_view text, Value &out, std::string &err) {
    Parser p(text, err);
    Value v;
    if (!p.parseDocument(v)) return false;
    out = std::move(v);
    return true;
}

std::string serialize(const Value &v, bool pretty) {
    std::string o;
    write(o, v, pretty, 0);
    if (pretty) o += '\n';
    return o;
}

} // namespace dalnok::json
