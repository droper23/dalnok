// Minimal JSON value, parser and writer (no dependencies). Used for project
// files and the command API. Strict RFC 8259 parsing with a depth limit.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace dalnok::json {

struct Value {
    enum class Type { Null, Bool, Number, String, Array, Object };

    Type type = Type::Null;
    bool boolean = false;
    double number = 0;
    std::string string;
    std::vector<Value> array;
    std::vector<std::pair<std::string, Value>> object; // insertion-ordered

    Value() = default;
    Value(bool b) : type(Type::Bool), boolean(b) {}
    Value(double n) : type(Type::Number), number(n) {}
    Value(int n) : type(Type::Number), number(n) {}
    Value(int64_t n) : type(Type::Number), number(static_cast<double>(n)) {}
    Value(const char *s) : type(Type::String), string(s) {}
    Value(std::string s) : type(Type::String), string(std::move(s)) {}

    static Value makeObject() { Value v; v.type = Type::Object; return v; }
    static Value makeArray() { Value v; v.type = Type::Array; return v; }

    bool isObject() const { return type == Type::Object; }
    bool isArray() const { return type == Type::Array; }
    bool isNumber() const { return type == Type::Number; }
    bool isString() const { return type == Type::String; }
    bool isBool() const { return type == Type::Bool; }

    const Value *get(std::string_view key) const;
    Value *get(std::string_view key) { return const_cast<Value *>(static_cast<const Value &>(*this).get(key)); }
    Value &set(std::string key, Value v);
    void push(Value v) { array.push_back(std::move(v)); }

    // Typed accessors with fallbacks (for optional fields).
    double getNumber(std::string_view key, double fallback) const;
    std::string getString(std::string_view key, std::string fallback) const;
    bool getBool(std::string_view key, bool fallback) const;
};

bool parse(std::string_view text, Value &out, std::string &err);
std::string serialize(const Value &v, bool pretty = false);

} // namespace dalnok::json
