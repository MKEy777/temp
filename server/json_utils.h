#pragma once
#include <string>
#include <vector>
#include <sstream>

namespace JsonUtils {

    // 从一个简单的JSON字符串中提取指定键的值
    static std::string get_string_value(const std::string& json_str, const std::string& key) {
        // --- 修复：在 key_pattern 中移除了冒号后面的空格 ---
        std::string key_pattern = "\"" + key + "\":\"";
        size_t key_pos = json_str.find(key_pattern);
        if (key_pos == std::string::npos) return "";

        size_t value_start_pos = key_pos + key_pattern.length();
        size_t value_end_pos = json_str.find("\"", value_start_pos);
        if (value_end_pos == std::string::npos) return "";

        return json_str.substr(value_start_pos, value_end_pos - value_start_pos);
    }

    // --- JSON 消息生成器 ---
    // (这些函数本身没问题，但为了保持一致性，我们让它们也生成紧凑型JSON)

    static std::string create_chat_message(const std::string& username, const std::string& text) {
        std::stringstream ss;
        // 生成紧凑型JSON
        ss << "{\"type\":\"chat_message\",\"username\":\"" << username << "\",\"text\":\"" << text << "\"}";
        return ss.str();
    }

    static std::string create_system_notification(const std::string& message) {
        std::stringstream ss;
        ss << "{\"type\":\"system_notification\",\"message\":\"" << message << "\"}";
        return ss.str();
    }

    static std::string create_user_list_update(const std::vector<std::string>& users) {
        std::stringstream ss;
        ss << "{\"type\":\"user_list_update\",\"users\":[";
        for (size_t i = 0; i < users.size(); ++i) {
            ss << "\"" << users[i] << "\"";
            if (i < users.size() - 1) ss << ",";
        }
        ss << "]}";
        return ss.str();
    }
}