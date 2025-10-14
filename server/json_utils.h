#pragma once
#include <string>
#include <vector>
#include <sstream>

namespace JsonUtils {

    // ��һ���򵥵�JSON�ַ�������ȡָ������ֵ
    static std::string get_string_value(const std::string& json_str, const std::string& key) {
        // --- �޸����� key_pattern ���Ƴ���ð�ź���Ŀո� ---
        std::string key_pattern = "\"" + key + "\":\"";
        size_t key_pos = json_str.find(key_pattern);
        if (key_pos == std::string::npos) return "";

        size_t value_start_pos = key_pos + key_pattern.length();
        size_t value_end_pos = json_str.find("\"", value_start_pos);
        if (value_end_pos == std::string::npos) return "";

        return json_str.substr(value_start_pos, value_end_pos - value_start_pos);
    }

    // --- JSON ��Ϣ������ ---
    // (��Щ��������û���⣬��Ϊ�˱���һ���ԣ�����������Ҳ���ɽ�����JSON)

    static std::string create_chat_message(const std::string& username, const std::string& text) {
        std::stringstream ss;
        // ���ɽ�����JSON
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